#include "HostConnection.h"

#include "Tsf.h"

namespace araso {

HostConnection::~HostConnection() { Close(); }

void HostConnection::Close() {
    if (pipe_ != INVALID_HANDLE_VALUE) CloseHandle(pipe_);
    pipe_ = INVALID_HANDLE_VALUE;
    client_ = 0;
    late_ = false;
}

bool HostConnection::Connect() {
    if (pipe_ != INVALID_HANDLE_VALUE) return true;
    std::wstring name = PipeName();
    for (int attempt = 0; attempt < 2; attempt++) {
        pipe_ = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                            FILE_FLAG_OVERLAPPED, nullptr);
        if (pipe_ != INVALID_HANDLE_VALUE) break;
        DWORD error = GetLastError();
        if (error == ERROR_PIPE_BUSY) {
            // Every instance busy for a moment: another app's key.
            if (!WaitNamedPipeW(name.c_str(), 100)) return false;
            continue;
        }
        if (error == ERROR_FILE_NOT_FOUND) LaunchHost();
        return false;
    }
    if (pipe_ == INVALID_HANDLE_VALUE) return false;
    DWORD mode = PIPE_READMODE_MESSAGE;
    if (!SetNamedPipeHandleState(pipe_, &mode, nullptr, nullptr)) {
        Close();
        return false;
    }
    return true;
}

/// The host starts at sign-in (the installer's Run entry); if it isn't running, start it, at most
/// every ten seconds. A sandboxed app can't start processes: its keys pass until the host is up.
void HostConnection::LaunchHost() {
    DWORD now = GetTickCount();
    if (lastLaunch_ && now - lastLaunch_ < 10000) return;
    lastLaunch_ = now;
    wchar_t path[MAX_PATH] = L"";
    GetModuleFileNameW(g_instance, path, MAX_PATH);
    std::wstring folder = path;
    size_t slash = folder.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return;
    folder = folder.substr(0, slash);
    // The 32-bit DLL sits in a subfolder (x86, arm64) of the install folder.
    std::wstring host = folder + L"\\ArasoHost.exe";
    if (GetFileAttributesW(host.c_str()) == INVALID_FILE_ATTRIBUTES) {
        size_t up = folder.find_last_of(L"\\/");
        if (up != std::wstring::npos) host = folder.substr(0, up) + L"\\ArasoHost.exe";
    }
    std::wstring command = L"\"" + host + L"\" --server";
    STARTUPINFOW startup = {sizeof startup};
    PROCESS_INFORMATION process = {};
    if (CreateProcessW(host.c_str(), command.data(), nullptr, nullptr, FALSE, DETACHED_PROCESS | CREATE_NO_WINDOW,
                       nullptr, nullptr, &startup, &process)) {
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
        Log("started the host");
    }
}

HostConnection::Sent HostConnection::Send(const Json &request, Json &response, DWORD timeoutMs) {
    if (!Connect()) return Sent::failed;
    std::string answer;
    // An answer that came too late for its request is still on its way: it goes first, unread.
    if (late_) {
        bool timedOut = false;
        if (!Receive(pipe_, answer, timeoutMs, &timedOut)) {
            if (timedOut) return Sent::slow;
            Log("host went away (%lu)", GetLastError());
            Close();
            return Sent::failed;
        }
        late_ = false;
    }
    bool timedOut = false;
    if (!Transact(pipe_, request.dump(), answer, timeoutMs, &timedOut)) {
        if (timedOut) {
            // The host is busy, not gone: its answer comes later. The connection, and with it the
            // session and the word being typed, stays.
            Log("host didn't answer in time");
            late_ = true;
            return Sent::slow;
        }
        Log("host didn't answer (%lu)", GetLastError());
        Close();
        return Sent::failed;
    }
    bool ok = false;
    response = Json::parse(answer, &ok);
    return ok ? Sent::ok : Sent::failed;
}

void HostConnection::Attach(const std::wstring &app, HWND window) {
    app_ = app;
    window_ = window;
    AttachNow();
}

bool HostConnection::AttachNow() {
    Json request = Json::object();
    request.set("op", "attach");
    request.set("app", Utf8(app_));
    request.set("window", static_cast<double>(reinterpret_cast<uintptr_t>(window_)));
    request.set("pid", static_cast<double>(GetCurrentProcessId()));
    Json response;
    if (Send(request, response, 2000) != Sent::ok) return false;
    client_ = response["reply"]["client"].asInt();
    return client_ != 0;
}

void HostConnection::Detach() {
    if (pipe_ == INVALID_HANDLE_VALUE || !client_) return;
    Json request = Json::object();
    request.set("op", "detach");
    request.set("client", client_);
    Json response;
    Send(request, response, 300);
    Close();
}

bool HostConnection::Request(Json request, Json &response, DWORD timeoutMs) {
    for (int attempt = 0; attempt < 2; attempt++) {
        if (!client_ && !AttachNow()) return false;
        request.set("client", client_);
        Sent sent = Send(request, response, timeoutMs);
        if (sent == Sent::slow) return false;
        if (sent == Sent::failed) {
            client_ = 0;
            continue;
        }
        if (response["error"].asString() == "unknown client") {
            client_ = 0;
            continue;
        }
        return true;
    }
    return false;
}

}  // namespace araso
