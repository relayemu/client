// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
#include "../include/PCSXRelay.h"
#include "../../deps/libretro-common/include/libretro.h"
extern "C" {
#include "../../libpcsxcore/misc.h"
#include "../../libpcsxcore/sio.h"
int relay_pcsx_validate_spu_state(const unsigned char *bytes, size_t length);
void relay_pcsx_pad_wire_state(unsigned *request, unsigned *replug);
void relay_pcsx_restore_pad_wire(unsigned request, unsigned replug);
int relay_pcsx_pad_mode(void);
int relay_pcsx_set_pad_mode(int enabled);
}
#include <CommonCrypto/CommonDigest.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <csetjmp>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using Clock = std::chrono::steady_clock;
namespace {
constexpr size_t cardBytes = 2 * 128 * 1024;
constexpr size_t audioCapacity = 16384;
constexpr size_t coreStateBytes = 0x440000;
constexpr size_t biosSize = 0x80000;
// Upstream SaveState: header[32], version[u32], HLE[u8], screenpic, RAM.
constexpr size_t biosOffset = 32 + 4 + 1 + 128 * 96 * 3 + 0x200000;
constexpr size_t stateHeaderSize = 64;
constexpr size_t stateSize = stateHeaderSize + cardBytes + coreStateBytes + 32;
std::mutex ownership;
PCSXRelayEmulator* active = nullptr;
uint32_t read32(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24; }
void write32(uint8_t* p, uint32_t v) { for (int i=0;i<4;i++) p[i]=uint8_t(v>>(i*8)); }
void digest(const void* p, size_t n, uint8_t* out) { CC_SHA256(p, static_cast<CC_LONG>(n), out); }
}

struct PCSXRelayEmulator {
    std::mutex coreMutex, frameMutex, audioMutex, sleepMutex;
    std::condition_variable wake;
    std::thread thread;
    std::atomic<bool> quit{false}, paused{true};
    std::atomic<unsigned> speed{100}, buttons{0};
    std::array<std::atomic<int16_t>,4> axes{};
    std::map<std::string,std::string> options;
    std::string firmwareDirectory, saveDirectory;
    retro_disk_control_ext_callback discs{};
    std::vector<uint8_t> pixels;
    std::array<int16_t,audioCapacity*2> audio{};
    size_t audioRead=0, audioWrite=0, audioCount=0;
    uint32_t width=320, height=240, pixelFormat=RETRO_PIXEL_FORMAT_RGB565;
    uint64_t frameNumber=0;
    std::atomic<uint64_t> frameCount{0}, produced{0}, requested{0}, missing{0}, discarded{0};
    std::atomic<double> fps{0}, targetFPS{59.8261}, maxFrameMS{0};
    std::array<uint8_t,biosSize> bootBIOS{};
    std::array<uint8_t,32> biosDigest{};
    bool initialized=false, loaded=false, analog=false, hle=true;
};

namespace {
// PCSX delegates save IO through SaveFuncs. Replace the libretro frontend's
// unchecked memcpy callbacks with a bounded memory stream. A failed read or
// seek rejects the load and restores the previous machine state.
struct StateIO { uint8_t* bytes=nullptr; size_t position=0; bool writing=false, failed=false; };
thread_local StateIO stateIO;
thread_local std::jmp_buf stateJump;
thread_local bool restoringState = false;
void rejectState() { stateIO.failed=true; if(restoringState)std::longjmp(stateJump,1); }
void* stateOpen(const char* name,const char* mode) {
    if (!name || !mode) return nullptr;
    stateIO={reinterpret_cast<uint8_t*>(const_cast<char*>(name)),0,mode[0]=='w',false};
    return &stateIO;
}
int stateRead(void* f,void* out,u32 n) {
    auto s=static_cast<StateIO*>(f);
    if (!s || n>coreStateBytes || s->position>coreStateBytes-n) {
        if(s)rejectState();
        if(out && n<=coreStateBytes)std::memset(out,0,n);
        return -1;
    }
    std::memcpy(out,s->bytes+s->position,n);s->position+=n;return int(n);
}
int stateWrite(void* f,const void* in,u32 n) {
    auto s=static_cast<StateIO*>(f);
    if (!s || n>coreStateBytes || s->position>coreStateBytes-n) {if(s)rejectState();return -1;}
    std::memcpy(s->bytes+s->position,in,n);s->position+=n;return int(n);
}
long stateSeek(void* f,long offset,int whence) {
    auto s=static_cast<StateIO*>(f);if(!s)return -1;
    int64_t pos=(whence==SEEK_CUR?int64_t(s->position):0)+offset;
    if((whence!=SEEK_CUR && whence!=SEEK_SET)||pos<0||pos>int64_t(coreStateBytes)){rejectState();return -1;}
    s->position=size_t(pos);return long(pos);
}
void stateClose(void*) {}
void logMessage(enum retro_log_level,const char*,...) {} // private paths stay out of public logs
bool environment(unsigned command,void* data) {
    auto e=active;if(!e)return false;
    switch(command) {
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY: *static_cast<const char**>(data)=e->firmwareDirectory.c_str();return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY: *static_cast<const char**>(data)=e->saveDirectory.c_str();return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE: static_cast<retro_log_callback*>(data)->log=logMessage;return true;
    case RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION: *static_cast<unsigned*>(data)=2;return true;
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2:
    case RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL: {
        auto o=command==RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2?static_cast<retro_core_options_v2*>(data):static_cast<retro_core_options_v2_intl*>(data)->us;
        for(auto d=o->definitions;d&&d->key;d++)if(!e->options.count(d->key))e->options[d->key]=d->default_value?d->default_value:d->values[0].value;
        return true;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        auto v=static_cast<retro_variable*>(data);auto i=e->options.find(v->key);
        v->value=i==e->options.end()?nullptr:i->second.c_str();return v->value!=nullptr;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE: *static_cast<bool*>(data)=false;return true;
    case RETRO_ENVIRONMENT_GET_CAN_DUPE: *static_cast<bool*>(data)=true;return true;
    case RETRO_ENVIRONMENT_GET_INPUT_BITMASKS: return true;
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT: {
        auto format=*static_cast<unsigned*>(data);
        if(format!=RETRO_PIXEL_FORMAT_RGB565 && format!=RETRO_PIXEL_FORMAT_XRGB8888 && format!=RETRO_PIXEL_FORMAT_0RGB1555)return false;
        e->pixelFormat=format;return true;
    }
    case RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION: *static_cast<unsigned*>(data)=1;return true;
    case RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE: e->discs=*static_cast<retro_disk_control_ext_callback*>(data);return true;
    case RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO: {
        auto av=static_cast<retro_system_av_info*>(data);
        if(av->timing.fps>=45 && av->timing.fps<=65)e->targetFPS=av->timing.fps;
        return true;
    }
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME: return true;
    default: return false;
    }
}
void video(const void* data,unsigned width,unsigned height,size_t pitch) {
    auto e=active;
    if(!e||!data||data==RETRO_HW_FRAME_BUFFER_VALID||!width||!height||width>1024||height>512)return;
    const unsigned stride=e->pixelFormat==RETRO_PIXEL_FORMAT_XRGB8888?4:2;
    if(pitch<width*stride)return;
    std::lock_guard<std::mutex> guard(e->frameMutex);
    e->pixels.resize(size_t(width)*height*4);
    for(unsigned y=0;y<height;y++)for(unsigned x=0;x<width;x++) {
        const auto p=static_cast<const uint8_t*>(data)+y*pitch+x*stride;
        auto out=e->pixels.data()+(size_t(y)*width+x)*4;
        if(stride==4){out[0]=p[2];out[1]=p[1];out[2]=p[0];}
        else {
            const unsigned c=unsigned(p[0])|unsigned(p[1])<<8;
            if(e->pixelFormat==RETRO_PIXEL_FORMAT_RGB565){out[0]=((c>>11)&31)*255/31;out[1]=((c>>5)&63)*255/63;}
            else {out[0]=((c>>10)&31)*255/31;out[1]=((c>>5)&31)*255/31;}
            out[2]=(c&31)*255/31;
        }
        out[3]=255;
    }
    e->width=width;e->height=height;e->frameNumber++;
}
size_t audioBatch(const int16_t* samples,size_t frames) {
    auto e=active;if(!e||!samples)return frames;e->produced+=frames;
    if(e->speed!=100)return frames; // fast-forward is deliberately silent
    std::lock_guard<std::mutex> guard(e->audioMutex);
    for(size_t i=0;i<frames;i++) {
        if(e->audioCount==audioCapacity){e->audioRead=(e->audioRead+1)%audioCapacity;e->audioCount--;e->discarded++;}
        e->audio[e->audioWrite*2]=samples[i*2];e->audio[e->audioWrite*2+1]=samples[i*2+1];
        e->audioWrite=(e->audioWrite+1)%audioCapacity;e->audioCount++;
    }
    return frames;
}
void audioSample(int16_t l,int16_t r) {int16_t s[2]={l,r};audioBatch(s,1);}
void inputPoll() {}
int16_t inputState(unsigned port,unsigned device,unsigned index,unsigned id) {
    auto e=active;if(!e||port)return 0;
    if(device==RETRO_DEVICE_JOYPAD){unsigned b=e->buttons.load();if(id==RETRO_DEVICE_ID_JOYPAD_MASK)return int16_t(b);return id<16 && (b&(1u<<id))?1:0;}
    if(device==RETRO_DEVICE_ANALOG && index<2 && id<2)return e->axes[index*2+id].load();
    return 0;
}
void loop(PCSXRelayEmulator* e) {
    auto deadline=Clock::now(),measure=deadline;uint64_t measured=0;
    while(!e->quit) {
        if(e->paused) {
            std::unique_lock<std::mutex> sleep(e->sleepMutex);
            e->wake.wait(sleep,[e]{return e->quit||!e->paused;});
            deadline=Clock::now();measure=deadline;measured=0;
            continue;
        }
        const auto begin=Clock::now();
        {
            std::lock_guard<std::mutex> guard(e->coreMutex);
            if(e->quit||e->paused)continue;
            retro_run();
        }
        e->frameCount++;measured++;
        const auto end=Clock::now();const double ms=std::chrono::duration<double,std::milli>(end-begin).count();
        if(ms>e->maxFrameMS)e->maxFrameMS=ms;
        const double seconds=std::chrono::duration<double>(end-measure).count();
        if(seconds>=1){e->fps=double(measured)/seconds;measure=end;measured=0;}
        double period=100.0/(e->targetFPS*e->speed);
        // Follow the output clock with at most 0.5% pacing correction. Apple
        // audio and the emulated crystal are independent clocks; a fixed
        // limiter otherwise drains a healthy buffer over a long session.
        if(e->requested>0 && e->speed==100){
            std::lock_guard<std::mutex> guard(e->audioMutex);
            const double error=(double(e->audioCount)-3072.0)/3072.0;
            period*=1.0+std::max(-1.0,std::min(1.0,error))*0.005;
        }
        deadline+=std::chrono::duration_cast<Clock::duration>(std::chrono::duration<double>(period));
        // A suspension must not produce seconds of catch-up and stale audio.
        if(end-deadline>std::chrono::milliseconds(100))deadline=end;
        std::unique_lock<std::mutex> sleep(e->sleepMutex);
        e->wake.wait_until(sleep,deadline,[e]{return e->quit||e->paused;});
    }
}
void copyCards(uint8_t* out) {std::memcpy(out,Mcd1Data,MCD_SIZE);std::memcpy(out+MCD_SIZE,Mcd2Data,MCD_SIZE);}
void loadCards(const uint8_t* bytes) {std::memcpy(Mcd1Data,bytes,MCD_SIZE);std::memcpy(Mcd2Data,bytes+MCD_SIZE,MCD_SIZE);}
bool switchDisc(PCSXRelayEmulator* e,unsigned index) {
    auto& d=e->discs;
    if(!d.get_num_images||!d.get_image_index||!d.set_eject_state||!d.set_image_index||index>=d.get_num_images())return false;
    const unsigned old=d.get_image_index();if(old==index)return true;
    if(!d.set_eject_state(true))return false;
    if(!d.set_image_index(index)){d.set_image_index(old);d.set_eject_state(false);return false;}
    if(!d.set_eject_state(false)){d.set_image_index(old);d.set_eject_state(false);return false;}
    return true;
}
bool restoreRaw(const std::vector<uint8_t>& bytes) {
    // The called stack consists of upstream C functions with no C++ destructors.
    // Stop at the first bad stream operation before a decoder uses partial data.
    restoringState=true;
    if(setjmp(stateJump)){restoringState=false;return false;}
    const bool ok=retro_unserialize(bytes.data(),bytes.size()) && !stateIO.failed;
    restoringState=false;return ok;
}
bool captureRaw(std::vector<uint8_t>& out) {
    out.assign(coreStateBytes,0);
    return retro_serialize(out.data(),out.size()) && !stateIO.failed;
}
}

extern "C" {
PCSXRelayEmulator* pcsx_relay_create(const char* firmware,const char* saves) {
    std::lock_guard<std::mutex> guard(ownership);
    if(active||!firmware||!saves)return nullptr;
    auto e=new(std::nothrow) PCSXRelayEmulator();if(!e)return nullptr;
    e->firmwareDirectory=firmware;e->saveDirectory=saves;
    e->options={{"pcsx_rearmed_memcard1","libretro"},{"pcsx_rearmed_memcard2","libretro"},
        {"pcsx_rearmed_bios","auto"},{"pcsx_rearmed_frameskip_type","disabled"},
        {"pcsx_rearmed_gpu_thread_rendering","disabled"},{"pcsx_rearmed_fractional_framerate","enabled"},
        {"pcsx_rearmed_analog_axis_modifier","circle"},{"pcsx_rearmed_analog_combo","disabled"},{"pcsx_rearmed_multitap","disabled"}};
    active=e;retro_set_environment(environment);retro_set_video_refresh(video);
    retro_set_audio_sample(audioSample);retro_set_audio_sample_batch(audioBatch);
    retro_set_input_poll(inputPoll);retro_set_input_state(inputState);
    retro_init();e->initialized=true;
    SaveFuncs={stateOpen,stateRead,stateWrite,stateSeek,stateClose};
    return e;
}
void pcsx_relay_destroy(PCSXRelayEmulator* e) {
    if(!e)return;e->quit=true;e->wake.notify_all();if(e->thread.joinable())e->thread.join();
    std::lock_guard<std::mutex> guard(ownership);
    if(e->loaded)retro_unload_game();if(e->initialized)retro_deinit();
    if(active==e)active=nullptr;delete e;
}
int pcsx_relay_load(PCSXRelayEmulator* e,const char* path) {
    if(!e||!path||e->loaded)return 0;
    std::lock_guard<std::mutex> guard(e->coreMutex);
    retro_game_info info={path,nullptr,0,nullptr};
    if(!retro_load_game(&info))return 0;e->loaded=true;e->hle=Config.HLE!=0;
    std::memcpy(e->bootBIOS.data(),psxRegs.ptrs.psxR,biosSize);digest(e->bootBIOS.data(),biosSize,e->biosDigest.data());
    retro_set_controller_port_device(0,RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD,0));
    retro_set_controller_port_device(1,RETRO_DEVICE_NONE);
    retro_system_av_info av{};retro_get_system_av_info(&av);
    if(av.timing.fps>=45&&av.timing.fps<=65)e->targetFPS=av.timing.fps;
    e->thread=std::thread(loop,e);return 1;
}
void pcsx_relay_set_paused(PCSXRelayEmulator* e,int value) {
    if(!e)return;e->paused=value!=0;e->wake.notify_all();
    if(value){std::lock_guard<std::mutex> guard(e->coreMutex);}
}
void pcsx_relay_set_speed(PCSXRelayEmulator* e,unsigned percent) {
    if(!e)return;e->speed=percent==200?200:100;pcsx_relay_flush_audio(e);e->wake.notify_all();
}
void pcsx_relay_run_frame(PCSXRelayEmulator* e) {
    if(!e||!e->loaded||!e->paused)return;std::lock_guard<std::mutex> guard(e->coreMutex);retro_run();
}
int pcsx_relay_lock_frame(PCSXRelayEmulator* e,const uint8_t** pixels,PCSXRelayFrameInfo* info) {
    if(!e||!pixels||!info)return 0;e->frameMutex.lock();
    if(e->pixels.empty()){e->frameMutex.unlock();return 0;}
    *pixels=e->pixels.data();*info={e->width,e->height,e->frameNumber};return 1;
}
void pcsx_relay_unlock_frame(PCSXRelayEmulator* e){if(e)e->frameMutex.unlock();}
size_t pcsx_relay_read_audio(PCSXRelayEmulator* e,int16_t* out,size_t frames) {
    if(!out)return 0;std::memset(out,0,frames*4);if(!e)return 0;
    e->requested+=frames;std::unique_lock<std::mutex> guard(e->audioMutex,std::try_to_lock);
    if(!guard.owns_lock()){e->missing+=frames;return 0;}
    const size_t n=std::min(frames,e->audioCount);
    for(size_t i=0;i<n;i++){out[i*2]=e->audio[e->audioRead*2];out[i*2+1]=e->audio[e->audioRead*2+1];e->audioRead=(e->audioRead+1)%audioCapacity;}
    e->audioCount-=n;e->missing+=frames-n;return n;
}
void pcsx_relay_flush_audio(PCSXRelayEmulator* e){if(!e)return;std::lock_guard<std::mutex> guard(e->audioMutex);e->audioRead=e->audioWrite=e->audioCount=0;}
void pcsx_relay_set_button(PCSXRelayEmulator* e,unsigned bit,int pressed){if(!e||bit>=16)return;if(pressed)e->buttons.fetch_or(1u<<bit);else e->buttons.fetch_and(~(1u<<bit));}
void pcsx_relay_set_axis(PCSXRelayEmulator* e,unsigned axis,int16_t value){if(e&&axis<4)e->axes[axis]=value;}
int pcsx_relay_set_controller(PCSXRelayEmulator* e,int analog){if(!e||!e->loaded)return 0;std::lock_guard<std::mutex> guard(e->coreMutex);retro_set_controller_port_device(0,analog?RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG,1):RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD,0));e->analog=analog!=0;return 1;}
int pcsx_relay_controller(PCSXRelayEmulator* e){if(!e)return 0;std::lock_guard<std::mutex> guard(e->coreMutex);return e->analog;}
int pcsx_relay_set_analog_mode(PCSXRelayEmulator* e,int enabled){if(!e)return 0;std::lock_guard<std::mutex> guard(e->coreMutex);if(!e->analog)return 0;return relay_pcsx_set_pad_mode(enabled!=0);}
int pcsx_relay_analog_mode(PCSXRelayEmulator* e){if(!e)return 0;std::lock_guard<std::mutex> guard(e->coreMutex);return e->analog?relay_pcsx_pad_mode():0;}
size_t pcsx_relay_card_size(void){return cardBytes;}
int pcsx_relay_copy_cards(PCSXRelayEmulator* e,uint8_t* out,size_t size){if(!e||!e->loaded||!out||size!=cardBytes)return 0;std::lock_guard<std::mutex> guard(e->coreMutex);copyCards(out);return 1;}
int pcsx_relay_load_cards(PCSXRelayEmulator* e,const uint8_t* bytes,size_t size){if(!e||!e->loaded||!bytes||size!=cardBytes)return 0;std::lock_guard<std::mutex> guard(e->coreMutex);loadCards(bytes);return 1;}
unsigned pcsx_relay_disc_count(PCSXRelayEmulator* e){if(!e)return 0;std::lock_guard<std::mutex> guard(e->coreMutex);return e->discs.get_num_images?e->discs.get_num_images():0;}
unsigned pcsx_relay_disc_index(PCSXRelayEmulator* e){if(!e)return 0;std::lock_guard<std::mutex> guard(e->coreMutex);return e->discs.get_image_index?e->discs.get_image_index():0;}
int pcsx_relay_switch_disc(PCSXRelayEmulator* e,unsigned index){if(!e)return 0;std::lock_guard<std::mutex> guard(e->coreMutex);return switchDisc(e,index);}
int pcsx_relay_uses_hle(PCSXRelayEmulator* e){return e&&e->hle;}
void pcsx_relay_diagnostics(PCSXRelayEmulator* e,PCSXRelayDiagnostics* out){
    if(!e||!out)return;*out={};out->framesPerSecond=e->fps;out->targetFramesPerSecond=e->targetFPS;out->longestFrameMilliseconds=e->maxFrameMS;
    out->frames=e->frameCount;out->audioFramesProduced=e->produced;out->audioFramesRequested=e->requested;out->audioFramesMissing=e->missing;out->audioFramesDiscarded=e->discarded;
    std::lock_guard<std::mutex> guard(e->audioMutex);out->audioBufferedFrames=uint32_t(e->audioCount);
}
uint8_t* pcsx_relay_save_state(PCSXRelayEmulator* e,size_t* size){
    if(!e||!e->loaded||!size)return nullptr;*size=0;std::lock_guard<std::mutex> guard(e->coreMutex);
    std::vector<uint8_t> raw;if(!captureRaw(raw))return nullptr;
    // Real BIOS is ROM; retain it locally, omit it from every portable state.
    if(!e->hle){if(std::memcmp(raw.data()+biosOffset,e->bootBIOS.data(),biosSize))return nullptr;std::memset(raw.data()+biosOffset,0,biosSize);}
    auto out=static_cast<uint8_t*>(std::calloc(1,stateSize));if(!out)return nullptr;
    std::memcpy(out,"RLPSX001",8);write32(out+8,uint32_t(coreStateBytes));
    write32(out+12,e->discs.get_image_index?e->discs.get_image_index():0);
    write32(out+16,e->discs.get_num_images?e->discs.get_num_images():0);
    out[20]=e->hle;out[21]=e->analog;out[22]=e->analog?relay_pcsx_pad_mode():0;
    if(!e->hle)std::memcpy(out+24,e->biosDigest.data(),32);
    unsigned request=0,replug=0;relay_pcsx_pad_wire_state(&request,&replug);
    write32(out+56,request);write32(out+60,replug);
    copyCards(out+stateHeaderSize);std::memcpy(out+stateHeaderSize+cardBytes,raw.data(),raw.size());
    digest(out,stateSize-32,out+stateSize-32);*size=stateSize;return out;
}
int pcsx_relay_load_state(PCSXRelayEmulator* e,const uint8_t* bytes,size_t size){
    if(!e||!e->loaded||!bytes||size!=stateSize||std::memcmp(bytes,"RLPSX001",8)||read32(bytes+8)!=coreStateBytes||bytes[20]>1||bytes[21]>1||bytes[22]>1)return 0;
    if(read32(bytes+56)>256)return 0;
    uint8_t sum[32];digest(bytes,size-32,sum);if(std::memcmp(sum,bytes+size-32,32))return 0;
    std::lock_guard<std::mutex> guard(e->coreMutex);
    if(bool(bytes[20])!=e->hle||(!e->hle&&std::memcmp(bytes+24,e->biosDigest.data(),32)))return -2;
    const unsigned count=e->discs.get_num_images?e->discs.get_num_images():0;
    const unsigned index=read32(bytes+12);
    if(read32(bytes+16)!=count||(count&&index>=count)||(!count&&index))return 0;
    std::vector<uint8_t> raw(bytes+stateHeaderSize+cardBytes,bytes+stateHeaderSize+cardBytes+coreStateBytes);
    if(std::memcmp(raw.data(),"STv4 PCSX",9)||read32(raw.data()+32)!=0x8b410006||raw[36]!=e->hle)return 0;
    constexpr size_t spuOffset=biosOffset+biosSize+0x10000+offsetof(psxRegisters,gteBusyCycle)+sizeof(GPUFreeze_t)+1024*512*2;
    const uint32_t spuSize=read32(raw.data()+spuOffset);
    if(spuSize>raw.size()-spuOffset-4 || !relay_pcsx_validate_spu_state(raw.data()+spuOffset+4,spuSize))return 0;
    if(!e->hle)std::memcpy(raw.data()+biosOffset,e->bootBIOS.data(),biosSize);
    std::vector<uint8_t> previous;if(!captureRaw(previous))return 0;
    const unsigned old=e->discs.get_image_index?e->discs.get_image_index():0;
    if(count&&!switchDisc(e,index))return 0;
    unsigned oldRequest=0,oldReplug=0;relay_pcsx_pad_wire_state(&oldRequest,&oldReplug);
    const bool oldAnalog=e->analog;
    retro_set_controller_port_device(0,bytes[21]?RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG,1):RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD,0));
    if(!restoreRaw(raw)){
        retro_set_controller_port_device(0,oldAnalog?RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_ANALOG,1):RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD,0));
        restoreRaw(previous);relay_pcsx_restore_pad_wire(oldRequest,oldReplug);if(count)switchDisc(e,old);return 0;
    }
    relay_pcsx_restore_pad_wire(read32(bytes+56),read32(bytes+60));
    loadCards(bytes+stateHeaderSize);e->analog=bytes[21];
    if(e->analog)relay_pcsx_set_pad_mode(bytes[22]);pcsx_relay_flush_audio(e);return 1;
}
void pcsx_relay_free(void* bytes){std::free(bytes);}
}
