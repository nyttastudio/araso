// The text service's line to ArasoHost.exe: a named pipe in message mode, one JSON request and its
// answer at a time. When the host isn't there the text service passes every key to the app.
#pragma once

#include "../common/Common.h"
#include "../common/Json.h"

namespace araso {

class HostConnection {
public:
    HostConnection() = default;
    ~HostConnection();
    HostConnection(const HostConnection &) = delete;
    HostConnection &operator=(const HostConnection &) = delete;

    /// Attaches this text service (its app and message window) and keeps its client id.
    void Attach(const std::wstring &app, HWND window);
    void Detach();

    /// Sends `request` with this client's id; the answer, or false when the host can't be reached
    /// (after one reconnect: a host that restarted gives new client ids) or is too busy to answer in
    /// time (no reconnect: that would end the session).
    bool Request(Json request, Json &response, DWORD timeoutMs = 1500);

    int client() const { return client_; }

private:
    HANDLE pipe_ = INVALID_HANDLE_VALUE;
    int client_ = 0;
    std::wstring app_;
    HWND window_ = nullptr;
    DWORD lastLaunch_ = 0;
    /// A request timed out and its answer hasn't been read yet.
    bool late_ = false;

    enum class Sent { ok, slow, failed };

    bool Connect();
    void Close();
    bool AttachNow();
    Sent Send(const Json &request, Json &response, DWORD timeoutMs);
    void LaunchHost();
};

}  // namespace araso
