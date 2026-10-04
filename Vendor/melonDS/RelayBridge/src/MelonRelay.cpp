// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MelonRelay.cpp — the C bridge over melonDS's NDS (see MelonRelay.h).
//
// melonDS has no run loop of its own: a frontend calls RunFrame. The bridge
// runs the machine on its own thread at the DS's 59.8261 Hz, copies both
// screens out after every frame, drains the SPU into a bounded ring for
// Relay's audio output, and hands input in before each frame. Battery saves
// arrive through Platform::WriteNDSSave and are kept as Relay's live
// `<rom>.sav`; states are melonDS's own savestates behind a Relay header.
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <fstream>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>
#include <sys/stat.h>
#include "types.h"
#include "Platform.h"
#include "Args.h"
#include "NDS.h"
#include "NDSCart.h"
#include "GPU.h"
#include "SPU.h"
#include "Savestate.h"
#include "MelonRelay.h"
#include "MelonRelayInternal.h"

using namespace melonDS;

namespace {

constexpr uint32_t kAudioSampleRate = 48000;
constexpr size_t kAudioRingFrames = kAudioSampleRate * 2;
constexpr double kFrameSeconds = 1.0 / 59.8261;
constexpr int kScreenWidth = 256;
constexpr int kScreenHeight = 192;
constexpr char kStateMagic[4] = {'R', 'D', 'S', '1'};
/// Comfortably above a measured DS state (19 MB); the buffer grows if a
/// machine ever needs more.
constexpr size_t kStateScratchBytes = 24 * 1024 * 1024;
constexpr uint32_t kStateVersion = 1;

std::string gLocalFolder;
std::atomic<bool> gLogging{false};

bool readWholeFile(const std::string& path, std::vector<uint8_t>& out)
{
    std::ifstream in(path, std::ios::binary);
    if (!in) return false;
    out.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
    return true;
}

bool writeWholeFile(const std::string& path, const uint8_t* bytes, size_t length)
{
    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    if (!out) return false;
    out.write((const char*)bytes, length);
    return (bool)out;
}

void createFolder(const std::string& path)
{
    mkdir(path.c_str(), 0755);
}

} // namespace

struct MelonRelayEmulator {
    std::string saveFolder;
    std::string romName;
    std::string batteryPath;
    std::unique_ptr<NDS> nds;
    bool loaded = false;

    // The machine: touched only under `machine`, by the run thread or by a
    // caller that stopped it at a frame boundary.
    // Allows the state wrapper to capture machine bytes and achievement hit
    // counts in one transaction while the existing serializer takes its lock.
    std::recursive_mutex machine;
    MelonRelayObserver observer = nullptr;
    void* observerContext = nullptr;
    std::thread runThread;
    std::atomic<bool> stopRequested{false};
    std::atomic<bool> paused{true};
    std::atomic<uint32_t> speedPercent{100};
    std::atomic<uint32_t> singleFrames{0};
    std::mutex pauseMutex;
    std::condition_variable pauseCV;

    // Video
    std::mutex frameMutex;
    std::vector<uint8_t> screens[2] = {std::vector<uint8_t>(kScreenWidth * kScreenHeight * 4),
                                       std::vector<uint8_t>(kScreenWidth * kScreenHeight * 4)};
    bool hasFrame = false;
    std::atomic<uint32_t> frameNumber{0};
    bool frameLocked = false;
    std::mutex fpsMutex;
    std::chrono::steady_clock::time_point fpsSince = std::chrono::steady_clock::now();
    uint32_t fpsFrames = 0;
    double fpsLast = 0;

    // Audio
    std::mutex audioMutex;
    std::vector<int16_t> ring = std::vector<int16_t>(kAudioRingFrames * 2);
    size_t ringRead = 0;
    size_t ringCount = 0;
    std::vector<int16_t> audioScratch = std::vector<int16_t>(8192 * 2);

    // Save states: one reusable buffer. A DS state is about 19 MB and Relay's
    // rewind asks for one several times a second, so allocating it per capture
    // moved hundreds of MB a second through the allocator. melonDS writes into
    // a caller-owned buffer happily; it only refuses to grow one, which the
    // caller handles by retrying with an owned buffer and keeping the size.
    std::vector<uint8_t> stateScratch;

    // Input
    std::atomic<uint32_t> pressed{0};
    std::atomic<int> touchX{-1};
    std::atomic<int> touchY{-1};

    // Battery
    std::atomic<bool> batteryWritten{false};

    void pushAudio(const int16_t* samples, size_t frames)
    {
        std::lock_guard<std::mutex> lock(audioMutex);
        for (size_t i = 0; i < frames && ringCount < kAudioRingFrames; i++) {
            size_t slot = ((ringRead + ringCount) % kAudioRingFrames) * 2;
            ring[slot] = samples[i * 2];
            ring[slot + 1] = samples[i * 2 + 1];
            ringCount++;
        }
    }

    size_t readAudio(int16_t* out, size_t frames)
    {
        std::lock_guard<std::mutex> lock(audioMutex);
        size_t available = std::min(frames, ringCount);
        for (size_t i = 0; i < available; i++) {
            size_t slot = ((ringRead + i) % kAudioRingFrames) * 2;
            out[i * 2] = ring[slot];
            out[i * 2 + 1] = ring[slot + 1];
        }
        ringRead = (ringRead + available) % kAudioRingFrames;
        ringCount -= available;
        if (available < frames) memset(out + available * 2, 0, (frames - available) * 2 * sizeof(int16_t));
        return available;
    }

    void flushAudio()
    {
        std::lock_guard<std::mutex> lock(audioMutex);
        ringRead = 0;
        ringCount = 0;
    }

    /// One emulated frame, with input applied first and video/audio copied out after.
    void runFrameLocked()
    {
        nds->SetKeyMask(~pressed.load() & 0xFFF);
        int tx = touchX.load(), ty = touchY.load();
        if (tx >= 0 && ty >= 0) nds->TouchScreen((u16)tx, (u16)ty);
        else nds->ReleaseScreen();
        nds->RunFrame();
        if (observer) observer(observerContext, 0);
        copyScreens();
        int got = nds->SPU.ReadOutput(audioScratch.data(), (int)(audioScratch.size() / 2));
        if (got > 0) pushAudio(audioScratch.data(), (size_t)got);
    }

    void copyScreens()
    {
        void* top = nullptr;
        void* bottom = nullptr;
        if (!nds->GPU.GetFramebuffers(&top, &bottom) || !top || !bottom) return;
        std::lock_guard<std::mutex> lock(frameMutex);
        const void* sources[2] = {top, bottom};
        for (int s = 0; s < 2; s++) {
            const uint32_t* src = (const uint32_t*)sources[s];
            uint8_t* dst = screens[s].data();
            for (int i = 0; i < kScreenWidth * kScreenHeight; i++) {
                uint32_t px = src[i];
                // SoftRenderer::ExpandColor already published BGRA8. Only
                // reorder its bytes for Relay's RGBX8 frame contract.
                dst[i * 4 + 0] = (uint8_t)((px >> 16) & 0xFF);
                dst[i * 4 + 1] = (uint8_t)((px >> 8) & 0xFF);
                dst[i * 4 + 2] = (uint8_t)(px & 0xFF);
                dst[i * 4 + 3] = 0xFF;
            }
        }
        hasFrame = true;
        frameNumber++;
    }

    void runLoop()
    {
        auto next = std::chrono::steady_clock::now();
        while (!stopRequested.load()) {
            if (paused.load() && singleFrames.load() == 0) {
                std::unique_lock<std::mutex> lock(pauseMutex);
                pauseCV.wait_for(lock, std::chrono::milliseconds(5));
                next = std::chrono::steady_clock::now();
                continue;
            }
            {
                std::lock_guard<std::recursive_mutex> lock(machine);
                if (nds) runFrameLocked();
            }
            if (singleFrames.load() > 0) {
                singleFrames--;
                continue;
            }
            uint32_t percent = speedPercent.load();
            if (percent == 0) continue;
            next += std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                std::chrono::duration<double>(kFrameSeconds * 100.0 / percent));
            auto now = std::chrono::steady_clock::now();
            if (next < now - std::chrono::milliseconds(100)) next = now;
            else std::this_thread::sleep_until(next);
        }
    }

    void onBatteryWrite(const uint8_t* bytes, uint32_t length)
    {
        if (batteryPath.empty() || !bytes || length == 0) return;
        writeWholeFile(batteryPath, bytes, length);
        batteryWritten = true;
    }
};

// MARK: Platform hooks

std::string melonRelayLocalFolder() { return gLocalFolder; }
bool melonRelayLoggingEnabled() { return gLogging.load(); }
void melonRelayOnBatteryWrite(void* userdata, const uint8_t* bytes, uint32_t length)
{
    if (auto* bridge = (MelonRelayEmulator*)userdata) bridge->onBatteryWrite(bytes, length);
}
void melonRelayOnSignalStop(void* userdata, int)
{
    if (auto* bridge = (MelonRelayEmulator*)userdata) bridge->paused = true;
}

extern "C" {

MelonRelayEmulator* melon_relay_create(const char* localFolder, const char* saveFolder)
{
    if (!localFolder || !saveFolder) return nullptr;
    gLocalFolder = localFolder;
    createFolder(gLocalFolder);
    createFolder(saveFolder);
    auto* bridge = new MelonRelayEmulator();
    bridge->saveFolder = saveFolder;
    return bridge;
}

void melon_relay_destroy(MelonRelayEmulator* bridge)
{
    if (!bridge) return;
    melon_relay_stop(bridge);
    delete bridge;
}

int melon_relay_load_rom(MelonRelayEmulator* bridge, const char* romPath)
{
    if (!bridge || !romPath || bridge->loaded) return 0;
    std::string path = romPath;
    std::vector<uint8_t> rom;
    if (!readWholeFile(path, rom) || rom.size() < 0x200) return 0;

    size_t slash = path.find_last_of('/');
    std::string file = slash == std::string::npos ? path : path.substr(slash + 1);
    size_t dot = file.find_last_of('.');
    bridge->romName = dot == std::string::npos ? file : file.substr(0, dot);
    bridge->batteryPath = bridge->saveFolder + "/" + bridge->romName + ".sav";

    NDSArgs args;
    args.JIT = std::nullopt;                 // interpreter only: no JIT ships in Relay
    args.OutputSampleRate = kAudioSampleRate;
    auto nds = std::make_unique<NDS>(std::move(args), bridge);

    NDSCart::NDSCartArgs cartArgs;
    std::vector<uint8_t> battery;
    if (readWholeFile(bridge->batteryPath, battery) && !battery.empty()) {
        cartArgs.SRAM = std::make_unique<u8[]>(battery.size());
        memcpy(cartArgs.SRAM.get(), battery.data(), battery.size());
        cartArgs.SRAMLength = (u32)battery.size();
    }
    auto romCopy = std::make_unique<u8[]>(rom.size());
    memcpy(romCopy.get(), rom.data(), rom.size());
    auto cart = NDSCart::ParseROM(std::move(romCopy), (u32)rom.size(), bridge, std::move(cartArgs));
    if (!cart) return 0;

    nds->SetNDSCart(std::move(cart));
    nds->Reset();
    if (nds->NeedsDirectBoot()) nds->SetupDirectBoot(bridge->romName);
    nds->Start();

    bridge->nds = std::move(nds);
    bridge->loaded = true;
    bridge->paused = true;
    bridge->stopRequested = false;
    bridge->runThread = std::thread([bridge] { bridge->runLoop(); });
    return 1;
}

void melon_relay_stop(MelonRelayEmulator* bridge)
{
    if (!bridge || !bridge->loaded) return;
    bridge->stopRequested = true;
    bridge->pauseCV.notify_all();
    if (bridge->runThread.joinable()) bridge->runThread.join();
    {
        std::lock_guard<std::recursive_mutex> lock(bridge->machine);
        if (bridge->nds) {
            // Persist whatever the cartridge holds, as a power-off would.
            if (auto* cart = bridge->nds->GetNDSCart()) {
                if (cart->GetSaveMemory() && cart->GetSaveMemoryLength() > 0)
                    bridge->onBatteryWrite(cart->GetSaveMemory(), cart->GetSaveMemoryLength());
            }
            bridge->nds->Stop(Platform::StopReason::External);
            bridge->nds.reset();
        }
    }
    bridge->loaded = false;
    bridge->flushAudio();
}

void melon_relay_set_paused(MelonRelayEmulator* bridge, int paused)
{
    if (!bridge) return;
    bridge->paused = paused != 0;
    bridge->pauseCV.notify_all();
}

int melon_relay_is_paused(MelonRelayEmulator* bridge)
{
    return (bridge && bridge->paused.load()) ? 1 : 0;
}

void melon_relay_set_speed_percent(MelonRelayEmulator* bridge, uint32_t percent)
{
    if (bridge) bridge->speedPercent = percent;
}

double melon_relay_fps(MelonRelayEmulator* bridge)
{
    if (!bridge || !bridge->loaded) return 0;
    std::lock_guard<std::mutex> lock(bridge->fpsMutex);
    auto now = std::chrono::steady_clock::now();
    double seconds = std::chrono::duration<double>(now - bridge->fpsSince).count();
    uint32_t frames = bridge->frameNumber.load();
    if (seconds >= 0.25) {
        bridge->fpsLast = (frames - bridge->fpsFrames) / seconds;
        bridge->fpsFrames = frames;
        bridge->fpsSince = now;
    }
    return bridge->fpsLast;
}

uint32_t melon_relay_frame_count(MelonRelayEmulator* bridge)
{
    return bridge ? bridge->frameNumber.load() : 0;
}

int melon_relay_lock_frame(MelonRelayEmulator* bridge, int screen, const uint8_t** pixels, MelonRelayFrameInfo* info)
{
    if (!bridge || !pixels || !info || screen < 0 || screen > 1) return 0;
    bridge->frameMutex.lock();
    if (!bridge->hasFrame) {
        bridge->frameMutex.unlock();
        return 0;
    }
    bridge->frameLocked = true;
    *pixels = bridge->screens[screen].data();
    info->width = kScreenWidth;
    info->height = kScreenHeight;
    info->frameNumber = bridge->frameNumber.load();
    return 1;
}

void melon_relay_unlock_frame(MelonRelayEmulator* bridge)
{
    if (bridge && bridge->frameLocked) {
        bridge->frameLocked = false;
        bridge->frameMutex.unlock();
    }
}

uint32_t melon_relay_audio_sample_rate(MelonRelayEmulator*) { return kAudioSampleRate; }

size_t melon_relay_read_audio(MelonRelayEmulator* bridge, int16_t* out, size_t frames)
{
    return (bridge && out) ? bridge->readAudio(out, frames) : 0;
}

size_t melon_relay_audio_buffered_frames(MelonRelayEmulator* bridge)
{
    if (!bridge) return 0;
    std::lock_guard<std::mutex> lock(bridge->audioMutex);
    return bridge->ringCount;
}

void melon_relay_flush_audio(MelonRelayEmulator* bridge)
{
    if (bridge) bridge->flushAudio();
}

void melon_relay_set_button(MelonRelayEmulator* bridge, MelonRelayButton button, int pressed)
{
    if (!bridge || button < 0 || button > 11) return;
    uint32_t mask = 1u << button;
    if (pressed) bridge->pressed.fetch_or(mask);
    else bridge->pressed.fetch_and(~mask);
}

void melon_relay_touch(MelonRelayEmulator* bridge, uint16_t x, uint16_t y)
{
    if (!bridge) return;
    bridge->touchX = std::min<int>(x, kScreenWidth - 1);
    bridge->touchY = std::min<int>(y, kScreenHeight - 1);
}

void melon_relay_release_touch(MelonRelayEmulator* bridge)
{
    if (!bridge) return;
    bridge->touchX = -1;
    bridge->touchY = -1;
}

uint8_t* melon_relay_copy_battery(MelonRelayEmulator* bridge, size_t* size)
{
    if (!bridge || !size || !bridge->loaded) return nullptr;
    std::lock_guard<std::recursive_mutex> lock(bridge->machine);
    auto* cart = bridge->nds ? bridge->nds->GetNDSCart() : nullptr;
    if (!cart) return nullptr;
    const u8* memory = cart->GetSaveMemory();
    u32 length = cart->GetSaveMemoryLength();
    if (!memory || length == 0) return nullptr;
    uint8_t* copy = (uint8_t*)malloc(length);
    if (!copy) return nullptr;
    memcpy(copy, memory, length);
    *size = length;
    bridge->onBatteryWrite(memory, length);
    return copy;
}

uint8_t* melon_relay_serialize_state(MelonRelayEmulator* bridge, size_t* size)
{
    if (!bridge || !size || !bridge->loaded) return nullptr;
    std::lock_guard<std::recursive_mutex> lock(bridge->machine);
    if (!bridge->nds) return nullptr;

    if (bridge->stateScratch.size() < kStateScratchBytes) bridge->stateScratch.resize(kStateScratchBytes);
    const void* buffer = nullptr;
    size_t length = 0;
    {
        Savestate state(bridge->stateScratch.data(), (u32)bridge->stateScratch.size(), true);
        if (!state.Error && bridge->nds->DoSavestate(&state) && !state.Error) {
            buffer = state.Buffer();
            length = state.Length();
        }
    }
    // The scratch buffer was too small (a bigger machine, a bigger cart): take
    // one owned buffer, then keep its size so the next capture fits again.
    std::unique_ptr<Savestate> owned;
    if (length == 0) {
        owned = std::make_unique<Savestate>(Savestate::DEFAULT_SIZE);
        if (owned->Error) return nullptr;
        if (!bridge->nds->DoSavestate(owned.get()) || owned->Error) return nullptr;
        buffer = owned->Buffer();
        length = owned->Length();
        if (length > bridge->stateScratch.size()) bridge->stateScratch.resize(length + length / 4);
    }

    uint8_t* copy = (uint8_t*)malloc(12 + length);
    if (!copy) return nullptr;
    memcpy(copy, kStateMagic, 4);
    uint32_t version = kStateVersion, screen = (uint32_t)bridge->frameNumber.load();
    memcpy(copy + 4, &version, 4);
    memcpy(copy + 8, &screen, 4);
    memcpy(copy + 12, buffer, length);
    *size = 12 + length;
    return copy;
}

int melon_relay_deserialize_state(MelonRelayEmulator* bridge, const uint8_t* bytes, size_t size)
{
    if (!bridge || !bytes || !bridge->loaded || size < 12) return 0;
    if (memcmp(bytes, kStateMagic, 4) != 0) return 0;
    uint32_t version;
    memcpy(&version, bytes + 4, 4);
    if (version != kStateVersion) return 0;
    std::lock_guard<std::recursive_mutex> lock(bridge->machine);
    if (!bridge->nds) return 0;
    std::vector<uint8_t> payload(bytes + 12, bytes + size);
    Savestate state(payload.data(), (u32)payload.size(), false);
    if (state.Error) return 0;
    if (!bridge->nds->DoSavestate(&state) || state.Error) return 0;
    bridge->flushAudio();
    return 1;
}

void melon_relay_run_single_frame(MelonRelayEmulator* bridge)
{
    if (!bridge || !bridge->loaded || !bridge->paused.load()) return;
    uint32_t before = bridge->frameNumber.load();
    bridge->singleFrames = 1;
    bridge->pauseCV.notify_all();
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
    while (std::chrono::steady_clock::now() < deadline) {
        if (bridge->frameNumber.load() != before && bridge->singleFrames.load() == 0) return;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

void melon_relay_free(void* pointer) { free(pointer); }

void melon_relay_set_logging(int enabled) { gLogging = enabled != 0; }

} // extern "C"

void melon_relay_set_observer(MelonRelayEmulator* bridge, MelonRelayObserver observer, void* context)
{
    if (!bridge) return;
    std::lock_guard<std::recursive_mutex> lock(bridge->machine);
    bridge->observer = observer;
    bridge->observerContext = context;
}

void melon_relay_with_machine(MelonRelayEmulator* bridge, void (*operation)(void*), void* context)
{
    if (!bridge || !operation) return;
    std::lock_guard<std::recursive_mutex> lock(bridge->machine);
    if (bridge->nds) operation(context);
}

size_t melon_relay_read_memory(MelonRelayEmulator* bridge, uint32_t region, uint32_t offset, uint8_t* out, size_t size)
{
    if (!bridge || !bridge->nds || !out || !size) return 0;
    const uint8_t* memory = nullptr;
    size_t length = 0;
    if (region == 1) { memory = bridge->nds->MainRAM; length = 0x400000; }
    else if (region == 2) { memory = bridge->nds->ARM9.DTCM; length = 0x4000; }
    if (!memory || offset >= length) return 0;
    length = std::min(size, length - offset);
    memcpy(out, memory + offset, length);
    return length;
}
