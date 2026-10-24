#include "Common.h"

#include <cstdarg>
#include <cstdio>
#include <vector>

namespace araso {

std::wstring Wide(const std::string &utf8) {
    if (utf8.empty()) return {};
    int length = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    std::wstring out(static_cast<size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), static_cast<int>(utf8.size()), out.data(), length);
    return out;
}

std::string Utf8(const wchar_t *wide, size_t count) {
    if (!wide || count == 0) return {};
    int length = WideCharToMultiByte(CP_UTF8, 0, wide, static_cast<int>(count), nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(length), '\0');
    WideCharToMultiByte(CP_UTF8, 0, wide, static_cast<int>(count), out.data(), length, nullptr, nullptr);
    return out;
}

std::string Utf8(const std::wstring &wide) { return Utf8(wide.data(), wide.size()); }

std::wstring PipeName() {
    DWORD session = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &session);
    wchar_t user[257] = L"";
    DWORD size = 257;
    if (!GetUserNameW(user, &size)) lstrcpyW(user, L"user");
    return L"\\\\.\\pipe\\Araso." + std::to_wstring(session) + L"." + user;
}

namespace {

bool Wait(HANDLE pipe, OVERLAPPED &overlapped, DWORD &transferred, DWORD timeoutMs, bool &moreData, bool &timedOut) {
    moreData = false;
    timedOut = false;
    DWORD error = GetLastError();
    if (error == ERROR_MORE_DATA) {
        moreData = true;
        return GetOverlappedResult(pipe, &overlapped, &transferred, FALSE) || GetLastError() == ERROR_MORE_DATA;
    }
    if (error != ERROR_IO_PENDING) return false;
    if (WaitForSingleObject(overlapped.hEvent, timeoutMs) != WAIT_OBJECT_0) {
        CancelIo(pipe);
        // It may have finished just before the cancel: then the answer is here.
        if (GetOverlappedResult(pipe, &overlapped, &transferred, TRUE)) return true;
        if (GetLastError() == ERROR_MORE_DATA) { moreData = true; return true; }
        timedOut = true;
        return false;
    }
    if (GetOverlappedResult(pipe, &overlapped, &transferred, FALSE)) return true;
    if (GetLastError() == ERROR_MORE_DATA) { moreData = true; return true; }
    return false;
}

/// The rest of a message longer than the buffer.
bool ReadRest(HANDLE pipe, OVERLAPPED &overlapped, std::vector<char> &buffer, std::string &answer, DWORD timeoutMs,
              bool moreData) {
    bool ok = true, timedOut = false;
    while (ok && moreData) {
        ResetEvent(overlapped.hEvent);
        DWORD transferred = 0;
        if (ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()), &transferred, &overlapped)) {
            moreData = false;
        } else {
            ok = Wait(pipe, overlapped, transferred, timeoutMs, moreData, timedOut);
        }
        if (ok) answer.append(buffer.data(), transferred);
    }
    return ok;
}

}  // namespace

bool Transact(HANDLE pipe, const std::string &request, std::string &answer, DWORD timeoutMs, bool *timedOut) {
    answer.clear();
    if (timedOut) *timedOut = false;
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!overlapped.hEvent) return false;
    std::vector<char> buffer(64 * 1024);
    DWORD transferred = 0;
    bool moreData = false, late = false;
    bool ok;
    if (TransactNamedPipe(pipe, const_cast<char *>(request.data()), static_cast<DWORD>(request.size()), buffer.data(),
                          static_cast<DWORD>(buffer.size()), &transferred, &overlapped)) {
        ok = true;
    } else {
        ok = Wait(pipe, overlapped, transferred, timeoutMs, moreData, late);
    }
    if (ok) answer.append(buffer.data(), transferred);
    // A long answer (a menu, a settings model) comes in more than one read.
    ok = ok && ReadRest(pipe, overlapped, buffer, answer, timeoutMs, moreData);
    if (timedOut) *timedOut = late;
    CloseHandle(overlapped.hEvent);
    return ok;
}

bool Receive(HANDLE pipe, std::string &answer, DWORD timeoutMs, bool *timedOut) {
    answer.clear();
    if (timedOut) *timedOut = false;
    OVERLAPPED overlapped = {};
    overlapped.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!overlapped.hEvent) return false;
    std::vector<char> buffer(64 * 1024);
    DWORD transferred = 0;
    bool moreData = false, late = false;
    bool ok;
    if (ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()), &transferred, &overlapped)) {
        ok = true;
    } else {
        ok = Wait(pipe, overlapped, transferred, timeoutMs, moreData, late);
    }
    if (ok) answer.append(buffer.data(), transferred);
    ok = ok && ReadRest(pipe, overlapped, buffer, answer, timeoutMs, moreData);
    if (timedOut) *timedOut = late;
    CloseHandle(overlapped.hEvent);
    return ok;
}

bool ReadMessage(HANDLE pipe, std::string &message) {
    message.clear();
    std::vector<char> buffer(64 * 1024);
    while (true) {
        DWORD read = 0;
        if (ReadFile(pipe, buffer.data(), static_cast<DWORD>(buffer.size()), &read, nullptr)) {
            message.append(buffer.data(), read);
            return true;
        }
        if (GetLastError() != ERROR_MORE_DATA) return false;
        message.append(buffer.data(), read);
    }
}

bool WriteMessage(HANDLE pipe, const std::string &message) {
    DWORD written = 0;
    return WriteFile(pipe, message.data(), static_cast<DWORD>(message.size()), &written, nullptr) &&
           written == message.size();
}

std::wstring ProcessName() {
    wchar_t path[MAX_PATH] = L"";
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    std::wstring name = path;
    size_t slash = name.find_last_of(L"\\/");
    if (slash != std::wstring::npos) name = name.substr(slash + 1);
    CharLowerBuffW(name.data(), static_cast<DWORD>(name.size()));
    return name;
}

void Log(const char *format, ...) {
    char buffer[512];
    int prefix = std::snprintf(buffer, sizeof buffer, "Araso: ");
    va_list args;
    va_start(args, format);
    std::vsnprintf(buffer + prefix, sizeof buffer - static_cast<size_t>(prefix), format, args);
    va_end(args);
    OutputDebugStringA(buffer);
    // ARASO_LOG names a file to append to as well (the CI's typing test reads it).
    wchar_t path[MAX_PATH] = L"";
    if (GetEnvironmentVariableW(L"ARASO_LOG", path, MAX_PATH)) {
        HANDLE file = CreateFileW(path, FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, 0, nullptr);
        if (file != INVALID_HANDLE_VALUE) {
            char line[600];
            int length = std::snprintf(line, sizeof line, "[%lu %lu] %s\r\n", GetCurrentProcessId(), GetTickCount(), buffer);
            DWORD written = 0;
            WriteFile(file, line, static_cast<DWORD>(length), &written, nullptr);
            CloseHandle(file);
        }
    }
}

}  // namespace araso
