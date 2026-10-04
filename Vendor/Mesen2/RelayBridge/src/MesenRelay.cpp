// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// MesenRelay.cpp — the C bridge over Mesen 2's Emulator (see MesenRelay.h).
//
// Mesen's frontends talk to the core through IRenderingDevice, IAudioDevice
// and IInputProvider; this file implements the three for Relay: the rendering
// device keeps a copy of the last decoded frame, the audio device is a bounded
// ring the Swift audio engine drains, and the input provider sets the button
// bits Relay pressed. Battery saves are exchanged through Relay's live file
// (`<rom>.sav`) whatever extension Mesen prefers for the console.
#include "pch.h"
#include <atomic>
#include <cerrno>
#include <cstring>
#include <fstream>
#include <mutex>
#include <sstream>
#include <thread>
#include <chrono>
#include "Shared/Emulator.h"
#include "Shared/NotificationManager.h"
#include "Shared/Interfaces/INotificationListener.h"
#include "Shared/MemoryType.h"
#include "NES/NesConsole.h"
#include "Shared/EmuSettings.h"
#include "Shared/SettingTypes.h"
#include "Shared/EmulatorLock.h"
#include "Shared/BatteryManager.h"
#include "Shared/BaseControlManager.h"
#include "Shared/BaseControlDevice.h"
#include "Shared/MessageManager.h"
#include "Shared/RenderedFrame.h"
#include "Shared/SaveStateManager.h"
#include "Shared/Video/VideoRenderer.h"
#include "Shared/Audio/SoundMixer.h"
#include "Shared/Interfaces/IConsole.h"
#include "WS/WsConsole.h"
#include "Shared/Interfaces/IRenderingDevice.h"
#include "Shared/Interfaces/IAudioDevice.h"
#include "Shared/Interfaces/IInputProvider.h"
#include "Utilities/FolderUtilities.h"
#include "Utilities/VirtualFile.h"
#include "MesenRelay.h"

namespace {

constexpr uint32_t kAudioSampleRate = 48000;
/// Two seconds of stereo audio; more than that means nobody is listening.
constexpr size_t kAudioRingFrames = kAudioSampleRate * 2;
constexpr char kStateMagic[4] = {'R', 'M', 'S', '1'};
bool gLogToStdout = false;

/// The extension Mesen gives the console's main battery file.
const char* primaryBatteryExtension(ConsoleType type)
{
	switch(type) {
		case ConsoleType::Snes: return ".srm";
		case ConsoleType::Gameboy: return ".srm";
		default: return ".sav";
	}
}

bool readFile(const string& path, vector<uint8_t>& out)
{
	ifstream in(path, ios::binary);
	if(!in) {
		return false;
	}
	out.assign(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
	return true;
}

bool writeFile(const string& path, const vector<uint8_t>& bytes)
{
	ofstream out(path, ios::binary | ios::trunc);
	if(!out) {
		return false;
	}
	out.write((const char*)bytes.data(), bytes.size());
	return (bool)out;
}

} // namespace

/// Serves the console's main battery file from Relay's live `<rom>.sav`;
/// every other extension (`.rtc`, `.chr.sav`, …) comes from Mesen's own file.
class RelayBatteryProvider : public IBatteryProvider
{
public:
	string saveFolder;
	string romName;
	string primaryExtension = ".sav";

	vector<uint8_t> LoadBattery(string extension) override
	{
		vector<uint8_t> bytes;
		string name = extension == primaryExtension ? romName + ".sav" : romName + extension;
		readFile(FolderUtilities::CombinePath(saveFolder, name), bytes);
		return bytes;
	}
};

struct MesenRelayEmulator : public IRenderingDevice, public IAudioDevice, public IInputProvider, public INotificationListener
{
	unique_ptr<Emulator> emu;
	shared_ptr<RelayBatteryProvider> battery = std::make_shared<RelayBatteryProvider>();
	string saveFolder;
	string saveStateFolder;
	string screenshotFolder;
	string firmwareFolder;
	string romName;
	ConsoleType consoleType = ConsoleType::Nes;
	bool loaded = false;
	MesenRelayObserver observer = nullptr;
	void* observerContext = nullptr;
	shared_ptr<INotificationListener> notificationLifetime;
	void ProcessNotification(ConsoleNotificationType type, void*) override
	{
		// PpuFrameDone is emitted by each core on its machine thread, even
		// when video decoding is skipped. The renderer callback is unsuitable.
		if(!observer || emu->IsRunAheadFrame()) return;
		if(type == ConsoleNotificationType::PpuFrameDone) observer(observerContext, 0);
		else if(type == ConsoleNotificationType::GameReset) observer(observerContext, 1);
	}

	// Video
	std::mutex frameMutex;
	vector<uint8_t> frame;
	MesenRelayFrameInfo frameInfo = {0, 0, 0};
	std::atomic<uint32_t> framesDelivered{0};
	bool frameLocked = false;
	// Measured delivery rate (frames the renderer received per second), so a
	// fast-forward or a struggling host shows in the number, unlike the
	// console's nominal rate.
	std::mutex fpsMutex;
	std::chrono::steady_clock::time_point fpsSince = std::chrono::steady_clock::now();
	uint32_t fpsFrames = 0;
	double fpsLast = 0;

	// Audio
	std::mutex audioMutex;
	vector<int16_t> ring = vector<int16_t>(kAudioRingFrames * 2);
	size_t ringRead = 0;
	size_t ringCount = 0; // stereo frames
	std::atomic<uint32_t> sampleRate{kAudioSampleRate};

	// Input: one bit per button index, two ports.
	std::atomic<uint32_t> buttons[2] = {{0}, {0}};

	// MARK: IRenderingDevice

	void UpdateFrame(RenderedFrame& f) override
	{
		if(!f.FrameBuffer || f.Width == 0 || f.Height == 0) {
			return;
		}
		std::lock_guard<std::mutex> lock(frameMutex);
		size_t pixels = (size_t)f.Width * f.Height;
		frame.resize(pixels * 4);
		const uint32_t* src = (const uint32_t*)f.FrameBuffer;
		uint8_t* dst = frame.data();
		for(size_t i = 0; i < pixels; i++) {
			uint32_t argb = src[i];
			dst[i * 4 + 0] = (argb >> 16) & 0xFF;
			dst[i * 4 + 1] = (argb >> 8) & 0xFF;
			dst[i * 4 + 2] = argb & 0xFF;
			dst[i * 4 + 3] = 0xFF;
		}
		frameInfo.width = f.Width;
		frameInfo.height = f.Height;
		frameInfo.frameNumber = f.FrameNumber;
		framesDelivered++;
	}
	void ClearFrame() override {}
	void Render(RenderSurfaceInfo&, RenderSurfaceInfo&) override {}
	void Reset() override {}
	void SetExclusiveFullscreenMode(bool, void*) override {}

	// MARK: IAudioDevice

	void PlayBuffer(int16_t* samples, uint32_t count, uint32_t rate, bool isStereo) override
	{
		sampleRate = rate;
		std::lock_guard<std::mutex> lock(audioMutex);
		for(uint32_t i = 0; i < count; i++) {
			if(ringCount >= kAudioRingFrames) {
				break; // nobody is draining; keep the newest two seconds bounded
			}
			size_t slot = ((ringRead + ringCount) % kAudioRingFrames) * 2;
			ring[slot] = isStereo ? samples[i * 2] : samples[i];
			ring[slot + 1] = isStereo ? samples[i * 2 + 1] : samples[i];
			ringCount++;
		}
	}
	void Stop() override { flushAudio(); }
	void Pause() override {}
	void ProcessEndOfFrame() override {}
	string GetAvailableDevices() override { return ""; }
	void SetAudioDevice(string) override {}
	AudioStatistics GetStatistics() override
	{
		AudioStatistics stats;
		std::lock_guard<std::mutex> lock(audioMutex);
		stats.AverageLatency = sampleRate > 0 ? ringCount * 1000.0 / sampleRate : 0;
		stats.BufferSize = (uint32_t)kAudioRingFrames;
		return stats;
	}

	size_t readAudio(int16_t* out, size_t frames)
	{
		std::lock_guard<std::mutex> lock(audioMutex);
		size_t available = std::min(frames, ringCount);
		for(size_t i = 0; i < available; i++) {
			size_t slot = ((ringRead + i) % kAudioRingFrames) * 2;
			out[i * 2] = ring[slot];
			out[i * 2 + 1] = ring[slot + 1];
		}
		ringRead = (ringRead + available) % kAudioRingFrames;
		ringCount -= available;
		if(available < frames) {
			memset(out + available * 2, 0, (frames - available) * 2 * sizeof(int16_t));
		}
		return available;
	}

	void flushAudio()
	{
		std::lock_guard<std::mutex> lock(audioMutex);
		ringRead = 0;
		ringCount = 0;
	}

	// MARK: IInputProvider

	bool SetInput(BaseControlDevice* device) override
	{
		uint8_t port = device->GetPort();
		if(port >= 2) {
			return false;
		}
		uint32_t mask = buttons[port].load();
		for(uint8_t bit = 0; bit < 32; bit++) {
			if(mask & (1u << bit)) {
				device->SetBit(bit);
			}
		}
		return true;
	}

	// MARK: Battery

	string primaryBatteryPath() { return FolderUtilities::CombinePath(saveFolder, romName + primaryBatteryExtension(consoleType)); }
	string relayBatteryPath() { return FolderUtilities::CombinePath(saveFolder, romName + ".sav"); }

	/// Mesen wrote its own file; keep Relay's live `<rom>.sav` identical to it.
	void mirrorBatteryToRelayFile(vector<uint8_t>* copy)
	{
		vector<uint8_t> bytes;
		if(!readFile(primaryBatteryPath(), bytes)) {
			return;
		}
		if(primaryBatteryPath() != relayBatteryPath()) {
			writeFile(relayBatteryPath(), bytes);
		}
		if(copy) {
			*copy = std::move(bytes);
		}
	}

	void configureSettings()
	{
		EmuSettings* settings = emu->GetSettings();

		AudioConfig audio = settings->GetAudioConfig();
		audio.SampleRate = kAudioSampleRate;
		audio.DisableDynamicSampleRate = true;
		audio.EnableAudio = true;
		settings->SetAudioConfig(audio);

		// SetPreferences re-applies the folder overrides (and clears the firmware
		// one), so the folders are stated here and then restored below.
		PreferencesConfig prefs = settings->GetPreferences();
		prefs.DisableGameSelectionScreen = true; // no "recent games" files in Relay's folders
		prefs.DisableOsd = true;
		prefs.SaveFolderOverride = saveFolder.c_str();
		prefs.SaveStateFolderOverride = saveStateFolder.c_str();
		prefs.ScreenshotFolderOverride = screenshotFolder.c_str();
		settings->SetPreferences(prefs);
		FolderUtilities::SetFolderOverrides(saveFolder, saveStateFolder, screenshotFolder, firmwareFolder);
		MessageManager::SetOptions(false, gLogToStdout);

		NesConfig nes = settings->GetNesConfig();
		// The core reads NES colours from the user palette and Mesen's desktop
		// UI is what normally fills it; without it every pixel is black. This is
		// upstream's default 2C02 palette (UI/Config/NesConfig.cs), emphasis
		// colours generated by the core.
		static const uint32_t kDefaultNesPalette[64] = {
			0xFF666666, 0xFF002A88, 0xFF1412A7, 0xFF3B00A4, 0xFF5C007E, 0xFF6E0040, 0xFF6C0600, 0xFF561D00, 0xFF333500, 0xFF0B4800, 0xFF005200, 0xFF004F08, 0xFF00404D, 0xFF000000, 0xFF000000, 0xFF000000,
			0xFFADADAD, 0xFF155FD9, 0xFF4240FF, 0xFF7527FE, 0xFFA01ACC, 0xFFB71E7B, 0xFFB53120, 0xFF994E00, 0xFF6B6D00, 0xFF388700, 0xFF0C9300, 0xFF008F32, 0xFF007C8D, 0xFF000000, 0xFF000000, 0xFF000000,
			0xFFFFFEFF, 0xFF64B0FF, 0xFF9290FF, 0xFFC676FF, 0xFFF36AFF, 0xFFFE6ECC, 0xFFFE8170, 0xFFEA9E22, 0xFFBCBE00, 0xFF88D800, 0xFF5CE430, 0xFF45E082, 0xFF48CDDE, 0xFF4F4F4F, 0xFF000000, 0xFF000000,
			0xFFFFFEFF, 0xFFC0DFFF, 0xFFD3D2FF, 0xFFE8C8FF, 0xFFFBC2FF, 0xFFFEC4EA, 0xFFFECCC5, 0xFFF7D8A5, 0xFFE4E594, 0xFFCFEF96, 0xFFBDF4AB, 0xFFB3F3CC, 0xFFB5EBF2, 0xFFB8B8B8, 0xFF000000, 0xFF000000 };
		memcpy(nes.UserPalette, kDefaultNesPalette, sizeof(kDefaultNesPalette));
		nes.IsFullColorPalette = false;
		nes.Port1.Type = ControllerType::NesController;
		nes.Port2.Type = ControllerType::NesController;
		nes.RamPowerOnState = RamState::AllZeros;
		settings->SetNesConfig(nes);

		// Sega: overscan as Mesen's UI defaults (UI/Config/SmsConfig.cs), which
		// yields the 256×192 Master System picture and the 160×144 Game Gear one.
		SmsConfig sms = settings->GetSmsConfig();
		sms.Port1.Type = ControllerType::SmsController;
		sms.Port2.Type = ControllerType::SmsController;
		sms.RamPowerOnState = RamState::AllZeros;
		sms.NtscOverscan.Top = 24; sms.NtscOverscan.Bottom = 24;
		sms.PalOverscan.Top = 24; sms.PalOverscan.Bottom = 24;
		sms.GameGearOverscan.Top = 48; sms.GameGearOverscan.Bottom = 48;
		sms.GameGearOverscan.Left = 48; sms.GameGearOverscan.Right = 48;
		// Mesen blends consecutive Game Gear frames to imitate its LCD; Relay wants
		// the frame the machine drew, so a restored state shows the same picture.
		sms.GgBlendFrames = false;
		settings->SetSmsConfig(sms);

		// PC Engine: like the NES, colours come from a palette the desktop UI
		// supplies (UI/Config/PcEngineConfig.cs); the overscan is its default.
		static const uint32_t kDefaultPcePalette[512] = {
			0xFF000000, 0xFF000016, 0xFF040235, 0xFF01004B, 0xFF07046A, 0xFF050180, 0xFF0B069F, 0xFF0903B5,
			0xFF1A0003, 0xFF200521, 0xFF1E0237, 0xFF240756, 0xFF22046C, 0xFF28098B, 0xFF2506A1, 0xFF2B0BC0,
			0xFF3D080D, 0xFF3B0524, 0xFF400A42, 0xFF3E0759, 0xFF440C77, 0xFF42098D, 0xFF480EAC, 0xFF450BC2,
			0xFF570910, 0xFF550526, 0xFF5B0A45, 0xFF59075B, 0xFF5E0C7A, 0xFF5C0990, 0xFF620EAF, 0xFF600BC5,
			0xFF720913, 0xFF770E31, 0xFF750B48, 0xFF7B1066, 0xFF790C7C, 0xFF7F119B, 0xFF7C0EB1, 0xFF8213D0,
			0xFF94111E, 0xFF920E34, 0xFF981352, 0xFF951069, 0xFF9B1587, 0xFF99129E, 0xFF9F17BC, 0xFF9D13D2,
			0xFFAE1120, 0xFFAC0E36, 0xFFB21355, 0xFFB0106B, 0xFFB6158A, 0xFFB312A0, 0xFFB917BF, 0xFFB714D5,
			0xFFC91123, 0xFFCF1641, 0xFFCC1358, 0xFFD21876, 0xFFD0158C, 0xFFD61AAB, 0xFFD417C1, 0xFFDA1CE0,
			0xFF092408, 0xFF07211E, 0xFF0D263D, 0xFF0A2353, 0xFF102872, 0xFF0E2588, 0xFF142AA7, 0xFF1127BD,
			0xFF23240B, 0xFF212121, 0xFF27263F, 0xFF252356, 0xFF2A2874, 0xFF28258B, 0xFF2E2AA9, 0xFF2C27BF,
			0xFF3E240D, 0xFF43292C, 0xFF412642, 0xFF472B61, 0xFF452877, 0xFF4B2D95, 0xFF482AAC, 0xFF4E2FCA,
			0xFF602C18, 0xFF5E292E, 0xFF642E4D, 0xFF612B63, 0xFF673082, 0xFF652D98, 0xFF6B32B7, 0xFF692FCD,
			0xFF7A2D1B, 0xFF782931, 0xFF7E2E50, 0xFF7C2B66, 0xFF823084, 0xFF7F2D9B, 0xFF8532B9, 0xFF832FD0,
			0xFF952D1D, 0xFF9B323C, 0xFF982F52, 0xFF9E3471, 0xFF9C3087, 0xFFA236A6, 0xFFA032BC, 0xFFA637DA,
			0xFFB73528, 0xFFB5323E, 0xFFBB375D, 0xFFB93473, 0xFFBF3992, 0xFFBC36A8, 0xFFC23BC7, 0xFFC038DD,
			0xFFD2352B, 0xFFCF3241, 0xFFD53760, 0xFFD33476, 0xFFD93994, 0xFFD736AB, 0xFFDC3BC9, 0xFFDA38E0,
			0xFF0A4008, 0xFF0F4526, 0xFF0D423D, 0xFF13475B, 0xFF114471, 0xFF174990, 0xFF1445A6, 0xFF1A4AC5,
			0xFF2C4813, 0xFF2A4529, 0xFF304A47, 0xFF2D475E, 0xFF334C7C, 0xFF314993, 0xFF2F46A9, 0xFF354BC7,
			0xFF464815, 0xFF44452B, 0xFF4A4A4A, 0xFF484760, 0xFF4E4C7F, 0xFF4B4995, 0xFF514EB4, 0xFF4F4BCA,
			0xFF614818, 0xFF674D36, 0xFF644A4D, 0xFF6A4F6B, 0xFF684C81, 0xFF6E51A0, 0xFF6C4EB6, 0xFF7253D5,
			0xFF835123, 0xFF814D39, 0xFF875257, 0xFF854F6E, 0xFF8B548C, 0xFF8851A3, 0xFF864EB9, 0xFF8C53D7,
			0xFF9E5125, 0xFF9B4D3C, 0xFFA1535A, 0xFF9F4F70, 0xFFA5548F, 0xFFA351A5, 0xFFA856C4, 0xFFA653DA,
			0xFFB85128, 0xFFBE5646, 0xFFBC535D, 0xFFC1587B, 0xFFBF5592, 0xFFC55AB0, 0xFFC356C6, 0xFFC95CE5,
			0xFFDA5933, 0xFFD85649, 0xFFDE5B68, 0xFFDC587E, 0xFFD95594, 0xFFDF5AB3, 0xFFDD57C9, 0xFFE35CE8,
			0xFF126410, 0xFF106126, 0xFF166645, 0xFF14625B, 0xFF1A6779, 0xFF176490, 0xFF1D69AE, 0xFF1B66C5,
			0xFF2D6412, 0xFF336931, 0xFF306647, 0xFF366B66, 0xFF34687C, 0xFF3A6D9B, 0xFF3869B1, 0xFF3E6FCF,
			0xFF476415, 0xFF4D6933, 0xFF4B664A, 0xFF516B68, 0xFF4E687F, 0xFF546D9D, 0xFF526AB3, 0xFF586FD2,
			0xFF6A6C20, 0xFF676936, 0xFF6D6E55, 0xFF6B6B6B, 0xFF717089, 0xFF6F6DA0, 0xFF7472BE, 0xFF726FD5,
			0xFF846C22, 0xFF8A7141, 0xFF886E57, 0xFF8D7376, 0xFF8B708C, 0xFF9175AB, 0xFF8F72C1, 0xFF9577DF,
			0xFF9E6C25, 0xFFA47144, 0xFFA26E5A, 0xFFA87378, 0xFFA6708F, 0xFFAB75AD, 0xFFA972C4, 0xFFAF77E2,
			0xFFC17530, 0xFFBE7246, 0xFFC47765, 0xFFC2737B, 0xFFC8799A, 0xFFC675B0, 0xFFCC7ACE, 0xFFC977E5,
			0xFFDB7532, 0xFFE17A51, 0xFFDF7767, 0xFFE57C86, 0xFFE2799C, 0xFFE87EBB, 0xFFE67BD1, 0xFFEC80F0,
			0xFF137F0F, 0xFF19842E, 0xFF178144, 0xFF1D8663, 0xFF1A8379, 0xFF208898, 0xFF1E85AE, 0xFF248ACD,
			0xFF36881A, 0xFF338531, 0xFF398A4F, 0xFF378665, 0xFF3D8C84, 0xFF3B889A, 0xFF418DB9, 0xFF3E8ACF,
			0xFF50881D, 0xFF568D3B, 0xFF548A52, 0xFF598F70, 0xFF578C87, 0xFF5D91A5, 0xFF5B8EBB, 0xFF6193DA,
			0xFF6A8820, 0xFF708D3E, 0xFF6E8A54, 0xFF748F73, 0xFF728C89, 0xFF7791A8, 0xFF758EBE, 0xFF7B93DD,
			0xFF8D902A, 0xFF8B8D41, 0xFF90925F, 0xFF8E8F76, 0xFF949494, 0xFF9291AA, 0xFF9896C9, 0xFF9593DF,
			0xFFA7902D, 0xFFAD954C, 0xFFAB9262, 0xFFB19780, 0xFFAE9497, 0xFFB499B5, 0xFFB296CC, 0xFFB89BEA,
			0xFFC19030, 0xFFC7964E, 0xFFC59264, 0xFFCB9783, 0xFFC99499, 0xFFCF99B8, 0xFFCC96CE, 0xFFD29BED,
			0xFFE4993A, 0xFFE29651, 0xFFE89B6F, 0xFFE59886, 0xFFEB9DA4, 0xFFE999BA, 0xFFEF9ED9, 0xFFED9BEF,
			0xFF1CA317, 0xFF22A836, 0xFF20A54C, 0xFF26AA6B, 0xFF23A781, 0xFF29ACA0, 0xFF27A9B6, 0xFF25A6CC,
			0xFF36A31A, 0xFF3CA939, 0xFF3AA54F, 0xFF40AA6D, 0xFF3EA784, 0xFF43ACA2, 0xFF41A9B9, 0xFF47AED7,
			0xFF59AC25, 0xFF57A93B, 0xFF5CAE5A, 0xFF5AAB70, 0xFF60B08F, 0xFF5EACA5, 0xFF64B2C3, 0xFF61AEDA,
			0xFF73AC28, 0xFF79B146, 0xFF77AE5C, 0xFF7DB37B, 0xFF7AB091, 0xFF78ADA8, 0xFF7EB2C6, 0xFF7CAEDC,
			0xFF8DAC2A, 0xFF93B149, 0xFF91AE5F, 0xFF97B37E, 0xFF95B094, 0xFF9BB5B2, 0xFF98B2C9, 0xFF9EB7E7,
			0xFFB0B435, 0xFFAEB14B, 0xFFB4B66A, 0xFFB1B380, 0xFFB7B89F, 0xFFB5B5B5, 0xFFBBBAD4, 0xFFB9B7EA,
			0xFFCAB438, 0xFFD0B956, 0xFFCEB66C, 0xFFD4BB8B, 0xFFD2B8A1, 0xFFCFB5B8, 0xFFD5BAD6, 0xFFD3B7EC,
			0xFFE5B53A, 0xFFEBBA59, 0xFFE8B66F, 0xFFEEBB8E, 0xFFECB8A4, 0xFFF2BDC2, 0xFFF0BAD9, 0xFFF5BFF7,
			0xFF25C71F, 0xFF23C436, 0xFF28C954, 0xFF26C66B, 0xFF2CCB89, 0xFF2AC89F, 0xFF30CDBE, 0xFF2DCAD4,
			0xFF3FC722, 0xFF3DC438, 0xFF43C957, 0xFF40C66D, 0xFF46CB8C, 0xFF44C8A2, 0xFF4ACDC1, 0xFF48CAD7,
			0xFF59C825, 0xFF5FCD43, 0xFF5DC959, 0xFF63CF78, 0xFF61CB8E, 0xFF67D0AD, 0xFF64CDC3, 0xFF6AD2E2,
			0xFF7CD02F, 0xFF7ACD46, 0xFF80D264, 0xFF7DCF7B, 0xFF83D499, 0xFF81D1AF, 0xFF87D6CE, 0xFF85D2E4,
			0xFF96D032, 0xFF94CD48, 0xFF9AD267, 0xFF98CF7D, 0xFF9ED49C, 0xFF9BD1B2, 0xFFA1D6D1, 0xFF9FD3E7,
			0xFFB1D035, 0xFFB7D553, 0xFFB4D26A, 0xFFBAD788, 0xFFB8D49E, 0xFFBED9BD, 0xFFBCD6D3, 0xFFC1DBF2,
			0xFFD3D840, 0xFFD1D556, 0xFFD7DA74, 0xFFD5D78B, 0xFFDADCA9, 0xFFD8D9C0, 0xFFDEDEDE, 0xFFDCDBF4,
			0xFFEED842, 0xFFEBD558, 0xFFF1DA77, 0xFFEFD78D, 0xFFF5DCAC, 0xFFF2D9C2, 0xFFF8DEE1, 0xFFF6DBF7,
			0xFF25E31F, 0xFF2BE83E, 0xFF29E554, 0xFF2FEA73, 0xFF2DE789, 0xFF33ECA7, 0xFF30E9BE, 0xFF36EEDC,
			0xFF48EB2A, 0xFF46E840, 0xFF4CED5F, 0xFF49EA75, 0xFF4FEF94, 0xFF4DECAA, 0xFF53F1C9, 0xFF51EEDF,
			0xFF62EC2D, 0xFF60E843, 0xFF66ED61, 0xFF64EA78, 0xFF6AEF96, 0xFF67ECAD, 0xFF6DF1CB, 0xFF6BEEE1,
			0xFF7DEC2F, 0xFF83F14E, 0xFF80EE64, 0xFF86F383, 0xFF84EF99, 0xFF8AF4B7, 0xFF88F1CE, 0xFF8DF6EC,
			0xFF9FF43A, 0xFF9DF150, 0xFFA3F66F, 0xFFA1F385, 0xFFA6F8A4, 0xFFA4F5BA, 0xFFAAFAD9, 0xFFA8F6EF,
			0xFFBAF43D, 0xFFB7F153, 0xFFBDF672, 0xFFBBF388, 0xFFC1F8A6, 0xFFBFF5BD, 0xFFC4FADB, 0xFFC2F7F2,
			0xFFD4F43F, 0xFFDAF95E, 0xFFD7F674, 0xFFDDFB93, 0xFFDBF8A9, 0xFFE1FDC8, 0xFFDFFADE, 0xFFE5FFFC,
			0xFFF6FC4A, 0xFFF4F960, 0xFFFAFE7F, 0xFFF8FB95, 0xFFFEFFB4, 0xFFFBFDCA, 0xFFFFFFE9, 0xFFFFFFFF,
		};
		PcEngineConfig pce = settings->GetPcEngineConfig();
		pce.Port1.Type = ControllerType::PceController;
		pce.RamPowerOnState = RamState::AllZeros;
		pce.Overscan.Top = 3; pce.Overscan.Left = 18; pce.Overscan.Right = 18;
		memcpy(pce.Palette, kDefaultPcePalette, sizeof(kDefaultPcePalette));
		settings->SetPcEngineConfig(pce);

		// WonderSwan: the picture rotates with the game's own orientation flag;
		// the vertical controller type only changes Mesen's keyboard tables,
		// which Relay does not use (the driver maps by orientation itself).
		WsConfig ws = settings->GetWsConfig();
		ws.ControllerHorizontal.Type = ControllerType::WsController;
		ws.ControllerVertical.Type = ControllerType::WsControllerVertical;
		ws.AutoRotate = true;
		settings->SetWsConfig(ws);

		SnesConfig snes = settings->GetSnesConfig();
		snes.Port1.Type = ControllerType::SnesController;
		snes.Port2.Type = ControllerType::SnesController;
		snes.RamPowerOnState = RamState::AllZeros;
		// Mesen's own default (UI/Config/SnesConfig.cs): the 224 lines a television showed.
		snes.Overscan.Top = 7;
		snes.Overscan.Bottom = 8;
		settings->SetSnesConfig(snes);
	}
};

extern "C" {

MesenRelayEmulator* mesen_relay_create(const char* homeFolder, const char* saveFolder, const char* saveStateFolder, const char* firmwareFolder)
{
	if(!homeFolder || !saveFolder || !saveStateFolder || !firmwareFolder) {
		return nullptr;
	}
	FolderUtilities::SetHomeFolder(homeFolder);

	auto* bridge = new MesenRelayEmulator();
	bridge->saveFolder = saveFolder;
	bridge->saveStateFolder = saveStateFolder;
	bridge->screenshotFolder = FolderUtilities::CombinePath(homeFolder, "Screenshots");
	bridge->firmwareFolder = firmwareFolder;
	bridge->battery->saveFolder = saveFolder;
	bridge->emu.reset(new Emulator());
	bridge->emu->Initialize(false);
	bridge->notificationLifetime = shared_ptr<INotificationListener>(bridge, [](INotificationListener*) {});
	bridge->emu->GetNotificationManager()->RegisterNotificationListener(bridge->notificationLifetime);
	bridge->configureSettings();
	bridge->emu->GetVideoRenderer()->RegisterRenderingDevice(bridge);
	bridge->emu->GetSoundMixer()->RegisterAudioDevice(bridge);
	bridge->emu->GetBatteryManager()->SetBatteryProvider(bridge->battery);
	return bridge;
}

void mesen_relay_destroy(MesenRelayEmulator* bridge)
{
	if(!bridge) {
		return;
	}
	mesen_relay_stop(bridge);
	bridge->emu->GetVideoRenderer()->UnregisterRenderingDevice(bridge);
	bridge->emu->GetSoundMixer()->RegisterAudioDevice(nullptr);
	bridge->emu->Release();
	bridge->emu.reset();
	delete bridge;
}

void mesen_relay_set_observer(MesenRelayEmulator* bridge, MesenRelayObserver observer, void* context)
{
	if(!bridge || !bridge->loaded) return;
	auto lock = bridge->emu->AcquireLock(false);
	bridge->observer = observer;
	bridge->observerContext = context;
}

void mesen_relay_with_machine(MesenRelayEmulator* bridge, void (*operation)(void*), void* context)
{
	if(!bridge || !bridge->loaded || !operation) return;
	auto lock = bridge->emu->AcquireLock(false);
	operation(context);
}

size_t mesen_relay_read_memory(MesenRelayEmulator* bridge, uint32_t region, uint32_t offset, uint8_t* out, size_t size)
{
	if(!bridge || !bridge->loaded || !out || !size) return 0;
	if(region == 0 && bridge->consoleType == ConsoleType::Nes) {
		if(offset >= 0x10000 || size > 0x10000 - offset) return 0;
		auto console = std::dynamic_pointer_cast<NesConsole>(bridge->emu->GetConsole());
		if(!console) return 0;
		for(size_t i = 0; i < size; ++i) out[i] = console->DebugRead((uint16_t)(offset + i));
		return size;
	}
	MemoryType type = MemoryType::None;
	switch(bridge->consoleType) {
		case ConsoleType::Snes:
			if(region == 1) type = MemoryType::SnesWorkRam;
			else if(region == 3) type = MemoryType::SnesSaveRam;
			else if(region == 4) type = MemoryType::Sa1InternalRam;
			break;
		case ConsoleType::Sms:
			if(region == 1) type = MemoryType::SmsWorkRam;
			else if(region == 3) type = MemoryType::SmsCartRam;
			break;
		case ConsoleType::PcEngine: if(region == 1) type = MemoryType::PceWorkRam; break;
		case ConsoleType::Ws:
			if(region == 1) type = MemoryType::WsWorkRam;
			else if(region == 3) type = MemoryType::WsCartRam;
			break;
		default: break;
	}
	if(type == MemoryType::None) return 0;
	ConsoleMemoryInfo memory = bridge->emu->GetMemory(type);
	if(!memory.Memory || offset >= memory.Size) return 0;
	size_t length = std::min(size, (size_t)memory.Size - offset);
	memcpy(out, (const uint8_t*)memory.Memory + offset, length);
	return length;
}

int mesen_relay_load_rom(MesenRelayEmulator* bridge, const char* romPath)
{
	if(!bridge || !romPath || bridge->loaded) {
		return 0;
	}
	string path = romPath;
	bridge->romName = FolderUtilities::GetFilename(path, false);
	bridge->battery->romName = bridge->romName;
	bridge->battery->primaryExtension = ".sav";

	// Hold the machine before it runs a single frame; the provider needs the
	// console type to know which of Mesen's files is the main battery.
	bridge->emu->Pause();
	VirtualFile rom(path);
	VirtualFile noPatch;
	if(!bridge->emu->LoadRom(rom, noPatch)) {
		bridge->emu->Resume();
		return 0;
	}
	bridge->consoleType = bridge->emu->GetConsoleType();
	bridge->battery->primaryExtension = primaryBatteryExtension(bridge->consoleType);
	shared_ptr<IConsole> console = bridge->emu->GetConsole();
	if(console) {
		console->GetControlManager()->RegisterInputProvider(bridge);
	}
	bridge->loaded = true;
	return 1;
}

MesenRelayConsole mesen_relay_console(MesenRelayEmulator* bridge)
{
	return (bridge && bridge->loaded) ? (MesenRelayConsole)bridge->consoleType : MesenRelayConsoleNone;
}

void mesen_relay_stop(MesenRelayEmulator* bridge)
{
	if(!bridge || !bridge->loaded) {
		return;
	}
	bridge->emu->Stop(false, true, true);
	bridge->mirrorBatteryToRelayFile(nullptr);
	bridge->loaded = false;
	bridge->flushAudio();
}

void mesen_relay_set_paused(MesenRelayEmulator* bridge, int paused)
{
	if(!bridge || !bridge->loaded) {
		return;
	}
	if(paused) {
		bridge->emu->Pause();
	} else {
		bridge->emu->Resume();
	}
}

int mesen_relay_is_paused(MesenRelayEmulator* bridge)
{
	return (bridge && bridge->loaded && bridge->emu->IsPaused()) ? 1 : 0;
}

void mesen_relay_set_speed_percent(MesenRelayEmulator* bridge, uint32_t percent)
{
	if(!bridge) {
		return;
	}
	EmulationConfig cfg = bridge->emu->GetSettings()->GetEmulationConfig();
	cfg.EmulationSpeed = percent;
	bridge->emu->GetSettings()->SetEmulationConfig(cfg);
}

double mesen_relay_fps(MesenRelayEmulator* bridge)
{
	if(!bridge || !bridge->loaded) {
		return 0;
	}
	std::lock_guard<std::mutex> lock(bridge->fpsMutex);
	auto now = std::chrono::steady_clock::now();
	double seconds = std::chrono::duration<double>(now - bridge->fpsSince).count();
	uint32_t frames = bridge->framesDelivered.load();
	if(seconds >= 0.25) {
		bridge->fpsLast = (frames - bridge->fpsFrames) / seconds;
		bridge->fpsFrames = frames;
		bridge->fpsSince = now;
	}
	return bridge->fpsLast;
}

uint32_t mesen_relay_frame_count(MesenRelayEmulator* bridge)
{
	return (bridge && bridge->loaded) ? bridge->emu->GetFrameCount() : 0;
}

int mesen_relay_lock_frame(MesenRelayEmulator* bridge, const uint8_t** pixels, MesenRelayFrameInfo* info)
{
	if(!bridge || !pixels || !info) {
		return 0;
	}
	bridge->frameMutex.lock();
	if(bridge->frame.empty()) {
		bridge->frameMutex.unlock();
		return 0;
	}
	bridge->frameLocked = true;
	*pixels = bridge->frame.data();
	*info = bridge->frameInfo;
	return 1;
}

void mesen_relay_unlock_frame(MesenRelayEmulator* bridge)
{
	if(bridge && bridge->frameLocked) {
		bridge->frameLocked = false;
		bridge->frameMutex.unlock();
	}
}

uint32_t mesen_relay_audio_sample_rate(MesenRelayEmulator* bridge)
{
	return bridge ? bridge->sampleRate.load() : 0;
}

size_t mesen_relay_read_audio(MesenRelayEmulator* bridge, int16_t* out, size_t frames)
{
	if(!bridge || !out) {
		return 0;
	}
	return bridge->readAudio(out, frames);
}

size_t mesen_relay_audio_buffered_frames(MesenRelayEmulator* bridge)
{
	if(!bridge) {
		return 0;
	}
	std::lock_guard<std::mutex> lock(bridge->audioMutex);
	return bridge->ringCount;
}

void mesen_relay_flush_audio(MesenRelayEmulator* bridge)
{
	if(bridge) {
		bridge->flushAudio();
	}
}

void mesen_relay_set_button(MesenRelayEmulator* bridge, uint8_t port, uint8_t bit, int pressed)
{
	if(!bridge || port >= 2 || bit >= 32) {
		return;
	}
	uint32_t mask = 1u << bit;
	if(pressed) {
		bridge->buttons[port].fetch_or(mask);
	} else {
		bridge->buttons[port].fetch_and(~mask);
	}
}

uint8_t* mesen_relay_copy_battery(MesenRelayEmulator* bridge, size_t* size)
{
	if(!bridge || !size || !bridge->loaded) {
		return nullptr;
	}
	{
		auto lock = bridge->emu->AcquireLock(false);
		shared_ptr<IConsole> console = bridge->emu->GetConsole();
		if(console) {
			console->SaveBattery();
		}
	}
	vector<uint8_t> bytes;
	bridge->mirrorBatteryToRelayFile(&bytes);
	if(bytes.empty()) {
		return nullptr;
	}
	uint8_t* copy = (uint8_t*)malloc(bytes.size());
	if(!copy) {
		return nullptr;
	}
	memcpy(copy, bytes.data(), bytes.size());
	*size = bytes.size();
	return copy;
}

const char* mesen_relay_rom_name(MesenRelayEmulator* bridge)
{
	return bridge ? bridge->romName.c_str() : "";
}

uint8_t* mesen_relay_serialize_state(MesenRelayEmulator* bridge, size_t* size)
{
	if(!bridge || !size || !bridge->loaded) {
		return nullptr;
	}
	stringstream stream;
	stream.write(kStateMagic, sizeof(kStateMagic));
	uint32_t version = SaveStateManager::FileFormatVersion;
	uint32_t console = (uint32_t)bridge->consoleType;
	stream.write((const char*)&version, sizeof(version));
	stream.write((const char*)&console, sizeof(console));
	{
		auto lock = bridge->emu->AcquireLock(false);
		// Level 0: raw bytes, so Relay's rewind deltas stay small.
		bridge->emu->Serialize(stream, false, 0);
	}
	string bytes = stream.str();
	uint8_t* copy = (uint8_t*)malloc(bytes.size());
	if(!copy) {
		return nullptr;
	}
	memcpy(copy, bytes.data(), bytes.size());
	*size = bytes.size();
	return copy;
}

int mesen_relay_deserialize_state(MesenRelayEmulator* bridge, const uint8_t* bytes, size_t size)
{
	if(!bridge || !bytes || !bridge->loaded || size < sizeof(kStateMagic) + 8) {
		return 0;
	}
	if(memcmp(bytes, kStateMagic, sizeof(kStateMagic)) != 0) {
		return 0;
	}
	uint32_t version, console;
	memcpy(&version, bytes + 4, sizeof(version));
	memcpy(&console, bytes + 8, sizeof(console));
	if(version != SaveStateManager::FileFormatVersion || console != (uint32_t)bridge->consoleType) {
		return 0;
	}
	string payload((const char*)bytes + 12, size - 12);
	stringstream stream(payload);
	auto lock = bridge->emu->AcquireLock(false);
	DeserializeResult result = bridge->emu->Deserialize(stream, version, false, bridge->consoleType, false);
	if(result == DeserializeResult::Success) {
		bridge->flushAudio();
		return 1;
	}
	return 0;
}

void mesen_relay_run_single_frame(MesenRelayEmulator* bridge)
{
	if(!bridge || !bridge->loaded || !bridge->emu->IsPaused()) {
		return;
	}
	uint32_t before = bridge->framesDelivered.load();
	bridge->emu->PauseOnNextFrame();
	// The frame is decoded on Mesen's decoder thread; wait for it to land so
	// the caller sees the new picture, but never for more than a moment.
	auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
	while(std::chrono::steady_clock::now() < deadline) {
		if(bridge->emu->IsPaused() && bridge->framesDelivered.load() != before) {
			return;
		}
		std::this_thread::sleep_for(std::chrono::milliseconds(1));
	}
}

int mesen_relay_ws_vertical(MesenRelayEmulator* bridge)
{
	if(!bridge || !bridge->loaded || bridge->consoleType != ConsoleType::Ws) {
		return 0;
	}
	shared_ptr<IConsole> console = bridge->emu->GetConsole();
	return console && ((WsConsole*)console.get())->IsVerticalMode() ? 1 : 0;
}

void mesen_relay_free(void* pointer)
{
	free(pointer);
}

/// Stands in for system() in Lua's os library (Package.swift renames the call):
/// Apple's mobile platforms have no shell, and Relay runs no Lua scripts anyway.
int mesen_relay_lua_system(const char*)
{
	errno = ENOSYS;
	return -1;
}

void mesen_relay_set_logging(int enabled)
{
	gLogToStdout = enabled != 0;
	MessageManager::SetOptions(false, gLogToStdout);
}

} // extern "C"
