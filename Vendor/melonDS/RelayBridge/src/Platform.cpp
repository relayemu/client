// SPDX-FileCopyrightText: 2026 Maiko BOSSUYT
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Relay's implementation of melonDS's Platform interface (src/Platform.h):
// files, threads, timing, logging, and the battery-save callback. Everything
// the DS talks to the outside world with (Wi-Fi, local multiplayer, cameras,
// the microphone, add-ons, dynamic libraries) is answered with "nothing
// there": Relay ships none of it.
#include <chrono>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <functional>
#include <mutex>
#include <string>
#include <thread>
#include <sys/stat.h>
#include "Platform.h"
#include "MelonRelayInternal.h"

namespace melonDS::Platform {

// MARK: Stop

void SignalStop(StopReason reason, void* userdata)
{
    melonRelayOnSignalStop(userdata, (int)reason);
}

// MARK: Files

struct FileHandle { FILE* file; };

static std::string modeString(FileMode mode, bool exists)
{
    bool read = mode & FileMode::Read;
    bool write = mode & FileMode::Write;
    bool append = mode & FileMode::Append;
    bool preserve = mode & FileMode::Preserve;
    bool noCreate = mode & FileMode::NoCreate;
    std::string m;
    if (append) m = read ? "a+" : "a";
    else if (write && read) m = (preserve || (noCreate && exists)) ? "r+" : "w+";
    else if (write) m = (preserve && exists) ? "r+" : "w";
    else m = "r";
    if (!(mode & FileMode::Text)) m += "b";
    return m;
}

FileHandle* OpenFile(const std::string& path, FileMode mode)
{
    if (mode == FileMode::None) return nullptr;
    struct stat st;
    bool exists = stat(path.c_str(), &st) == 0;
    if ((mode & FileMode::NoCreate) && !exists) return nullptr;
    FILE* f = fopen(path.c_str(), modeString(mode, exists).c_str());
    if (!f) return nullptr;
    return new FileHandle{f};
}

std::string GetLocalFilePath(const std::string& filename)
{
    return melonRelayLocalFolder() + "/" + filename;
}

FileHandle* OpenLocalFile(const std::string& path, FileMode mode)
{
    return OpenFile(GetLocalFilePath(path), mode);
}

bool FileExists(const std::string& name)
{
    struct stat st;
    return stat(name.c_str(), &st) == 0;
}

bool LocalFileExists(const std::string& name)
{
    return FileExists(GetLocalFilePath(name));
}

bool CheckFileWritable(const std::string& filepath)
{
    FILE* f = fopen(filepath.c_str(), "ab");
    if (!f) return false;
    fclose(f);
    return true;
}

bool CheckLocalFileWritable(const std::string& name)
{
    return CheckFileWritable(GetLocalFilePath(name));
}

bool CloseFile(FileHandle* file)
{
    if (!file) return false;
    bool ok = fclose(file->file) == 0;
    delete file;
    return ok;
}

bool IsEndOfFile(FileHandle* file) { return feof(file->file) != 0; }
bool FileReadLine(char* str, int count, FileHandle* file) { return fgets(str, count, file->file) != nullptr; }
u64 FilePosition(FileHandle* file) { return (u64)ftello(file->file); }

bool FileSeek(FileHandle* file, s64 offset, FileSeekOrigin origin)
{
    int whence = origin == FileSeekOrigin::Start ? SEEK_SET : origin == FileSeekOrigin::Current ? SEEK_CUR : SEEK_END;
    return fseeko(file->file, offset, whence) == 0;
}

void FileRewind(FileHandle* file) { rewind(file->file); }
u64 FileRead(void* data, u64 size, u64 count, FileHandle* file) { return fread(data, size, count, file->file); }
bool FileFlush(FileHandle* file) { return fflush(file->file) == 0; }
u64 FileWrite(const void* data, u64 size, u64 count, FileHandle* file) { return fwrite(data, size, count, file->file); }

u64 FileWriteFormatted(FileHandle* file, const char* fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    int n = vfprintf(file->file, fmt, args);
    va_end(args);
    return n < 0 ? 0 : (u64)n;
}

u64 FileLength(FileHandle* file)
{
    off_t pos = ftello(file->file);
    fseeko(file->file, 0, SEEK_END);
    off_t len = ftello(file->file);
    fseeko(file->file, pos, SEEK_SET);
    return (u64)len;
}

// MARK: Logging

void Log(LogLevel level, const char* fmt, ...)
{
    if (!melonRelayLoggingEnabled()) return;
    va_list args;
    va_start(args, fmt);
    vfprintf(stdout, fmt, args);
    va_end(args);
    fflush(stdout);
}

// MARK: Threads

struct Thread { std::thread thread; };
struct Semaphore { std::mutex mutex; std::condition_variable cv; int count = 0; };
struct Mutex { std::mutex mutex; };

Thread* Thread_Create(std::function<void()> func) { return new Thread{std::thread(func)}; }
void Thread_Free(Thread* thread) { delete thread; }
void Thread_Wait(Thread* thread) { if (thread->thread.joinable()) thread->thread.join(); }

Semaphore* Semaphore_Create() { return new Semaphore(); }
void Semaphore_Free(Semaphore* sema) { delete sema; }
void Semaphore_Reset(Semaphore* sema) { std::lock_guard<std::mutex> lock(sema->mutex); sema->count = 0; }
void Semaphore_Wait(Semaphore* sema)
{
    std::unique_lock<std::mutex> lock(sema->mutex);
    sema->cv.wait(lock, [&] { return sema->count > 0; });
    sema->count--;
}
bool Semaphore_TryWait(Semaphore* sema, int timeout_ms)
{
    std::unique_lock<std::mutex> lock(sema->mutex);
    if (!sema->cv.wait_for(lock, std::chrono::milliseconds(timeout_ms), [&] { return sema->count > 0; })) return false;
    sema->count--;
    return true;
}
void Semaphore_Post(Semaphore* sema, int count)
{
    std::lock_guard<std::mutex> lock(sema->mutex);
    sema->count += count;
    sema->cv.notify_all();
}

Mutex* Mutex_Create() { return new Mutex(); }
void Mutex_Free(Mutex* mutex) { delete mutex; }
void Mutex_Lock(Mutex* mutex) { mutex->mutex.lock(); }
void Mutex_Unlock(Mutex* mutex) { mutex->mutex.unlock(); }
bool Mutex_TryLock(Mutex* mutex) { return mutex->mutex.try_lock(); }

// MARK: Time

void Sleep(u64 usecs) { std::this_thread::sleep_for(std::chrono::microseconds(usecs)); }
u64 GetMSCount() { return (u64)std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
u64 GetUSCount() { return (u64)std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

// MARK: Saves and firmware

void WriteNDSSave(const u8* savedata, u32 savelen, u32 writeoffset, u32 writelen, void* userdata)
{
    melonRelayOnBatteryWrite(userdata, savedata, savelen);
}
void WriteGBASave(const u8*, u32, u32, u32, void*) {}
void WriteFirmware(const Firmware&, u32, u32, void*) {}
void WriteDateTime(int, int, int, int, int, int, void*) {}

// MARK: Network, multiplayer: none

void MP_Begin(void*) {}
void MP_End(void*) {}
int MP_SendPacket(u8*, int, u64, void*) { return 0; }
int MP_RecvPacket(u8*, u64*, void*) { return 0; }
int MP_SendCmd(u8*, int, u64, void*) { return 0; }
int MP_SendReply(u8*, int, u64, u16, void*) { return 0; }
int MP_SendAck(u8*, int, u64, void*) { return 0; }
int MP_RecvHostPacket(u8*, u64*, void*) { return 0; }
u16 MP_RecvReplies(u8*, u64, u16, void*) { return 0; }
int Net_SendPacket(u8*, int, void*) { return 0; }
int Net_RecvPacket(u8*, void*) { return 0; }

// MARK: Camera, microphone, DSi audio codec: none

void Camera_Start(int, void*) {}
void Camera_Stop(int, void*) {}
void Camera_CaptureFrame(int, u32*, int, int, bool, void*) {}
void Mic_Start(void*) {}
void Mic_Stop(void*) {}
int Mic_ReadInput(s16*, int, void*) { return 0; }
AACDecoder* AAC_Init() { return nullptr; }
void AAC_DeInit(AACDecoder*) {}
bool AAC_Configure(AACDecoder*, int, int) { return false; }
bool AAC_DecodeFrame(AACDecoder*, const void*, int, void*, int) { return false; }

// MARK: Add-ons, dynamic libraries: none

bool Addon_KeyDown(KeyType, void*) { return false; }
void Addon_RumbleStart(u32, void*) {}
void Addon_RumbleStop(void*) {}
float Addon_MotionQuery(MotionQueryType, void*) { return 0; }
DynamicLibrary* DynamicLibrary_Load(const char*) { return nullptr; }
void DynamicLibrary_Unload(DynamicLibrary*) {}
void* DynamicLibrary_LoadFunction(DynamicLibrary*, const char*) { return nullptr; }

}
