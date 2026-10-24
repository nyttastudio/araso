#include "Server.h"

#include "Bridge.h"
#include "Updater.h"

#include <sddl.h>

#include <ctime>

namespace araso {

namespace {

constexpr UINT kRequestMessage = WM_APP + 1;
constexpr UINT kDisconnectMessage = WM_APP + 2;
constexpr UINT kReleaseMessage = WM_APP + 3;
constexpr UINT kDrawMessage = WM_APP + 4;
constexpr UINT_PTR kUpdateTimer = 1;

Server *g_server = nullptr;

/// A request handed from a pipe thread to the main thread.
struct Work {
    std::string request;
    std::string answer;
    int client = 0;
};

RECT RectFrom(const Json &value, bool &ok) {
    RECT rect = {};
    ok = value.isArray() && value.size() == 4;
    if (ok) {
        rect.left = value[0].asInt();
        rect.top = value[1].asInt();
        rect.right = value[2].asInt();
        rect.bottom = value[3].asInt();
        ok = rect.bottom > rect.top;
    }
    return rect;
}

/// Who may open the pipe: this user, apps in sandboxes (AppContainers) and low-integrity apps such
/// as browsers' renderers, so typing works in Store apps too.
SECURITY_ATTRIBUTES *PipeSecurity() {
    static SECURITY_ATTRIBUTES attributes = {sizeof attributes, nullptr, FALSE};
    if (attributes.lpSecurityDescriptor) return &attributes;
    std::wstring user = L"OW";
    HANDLE token = nullptr;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        BYTE buffer[256];
        DWORD size = 0;
        if (GetTokenInformation(token, TokenUser, buffer, sizeof buffer, &size)) {
            LPWSTR sid = nullptr;
            if (ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER *>(buffer)->User.Sid, &sid)) {
                user = sid;
                LocalFree(sid);
            }
        }
        CloseHandle(token);
    }
    std::wstring sddl = L"D:(A;;GA;;;" + user + L")(A;;GA;;;SY)(A;;GA;;;AC)(A;;GA;;;S-1-15-2-2)S:(ML;;NW;;;LW)";
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.c_str(), SDDL_REVISION_1, &descriptor, nullptr)) {
        attributes.lpSecurityDescriptor = descriptor;
    }
    return &attributes;
}

/// GitHub's latest release (or ARASO_UPDATE_FEED's file), handed to the window in `parameter`.
DWORD WINAPI FetchRelease(LPVOID parameter) {
    wchar_t feed[1024] = L"";
    std::wstring url = GetEnvironmentVariableW(L"ARASO_UPDATE_FEED", feed, 1024) ? feed : updater::kLatest;
    auto *body = new std::string();
    if (!updater::Get(url, *body)) body->clear();
    PostMessageW(static_cast<HWND>(parameter), kReleaseMessage, 0, reinterpret_cast<LPARAM>(body));
    return 0;
}

}  // namespace

void Server::OpenSettings(const std::string &tab) {
    wchar_t path[MAX_PATH] = L"";
    GetModuleFileNameW(nullptr, path, MAX_PATH);
    // One settings window: an open one comes forward on the pane asked for.
    if (HWND open = FindWindowW(kSettingsWindowClass, nullptr)) {
        std::string data = tab;
        COPYDATASTRUCT copy = {kCopyShowTab, static_cast<DWORD>(data.size()), data.data()};
        SendMessageTimeoutW(open, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&copy), SMTO_ABORTIFHUNG, 500, nullptr);
        SetForegroundWindow(open);
        return;
    }
    std::wstring command = L"\"" + std::wstring(path) + L"\" --settings " + Wide(tab);
    STARTUPINFOW startup = {sizeof startup};
    PROCESS_INFORMATION process = {};
    if (CreateProcessW(path, command.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &startup, &process)) {
        AllowSetForegroundWindow(process.dwProcessId);
        CloseHandle(process.hThread);
        CloseHandle(process.hProcess);
    }
}

int Server::Run() {
    HANDLE single = CreateMutexW(nullptr, TRUE, kHostMutex);
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        if (single) CloseHandle(single);
        return 0;
    }
    g_server = this;
    std::wstring error;
    if (!Bridge::Shared().Start(error)) {
        Log("%s", Utf8(error).c_str());
        MessageBoxW(nullptr, error.c_str(), L"Araso", MB_ICONERROR);
        return 1;
    }

    WNDCLASSEXW cls = {sizeof cls};
    cls.lpfnWndProc = Proc;
    cls.hInstance = GetModuleHandleW(nullptr);
    cls.lpszClassName = kHostWindowClass;
    RegisterClassExW(&cls);
    window_ = CreateWindowExW(WS_EX_TOOLWINDOW, kHostWindowClass, L"Araso", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
                              GetModuleHandleW(nullptr), nullptr);
    if (!window_) return 1;
    // The settings window and `--vim` may run at another integrity level.
    ChangeWindowMessageFilterEx(window_, WM_COPYDATA, MSGFLT_ALLOW, nullptr);
    pendingMessage_ = RegisterWindowMessageW(kPendingMessage);

    // The models and the kanji dictionary load before the first key is served: a key waiting on
    // them would time out and go to the app as typed.
    Bridge::Shared().WarmUp();
    CloseHandle(CreateThread(nullptr, 0, Listen, this, 0, nullptr));
    // The first update check a minute after starting, then hourly wake-ups that check once a day.
    SetTimer(window_, kUpdateTimer, 60 * 1000, nullptr);
    Log("host ready");

    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return 0;
}

DWORD WINAPI Server::Listen(LPVOID) {
    std::wstring name = PipeName();
    while (true) {
        HANDLE pipe = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX,
                                       PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                       PIPE_UNLIMITED_INSTANCES, 64 * 1024, 64 * 1024, 0, PipeSecurity());
        if (pipe == INVALID_HANDLE_VALUE) {
            Log("could not create the pipe (%lu)", GetLastError());
            Sleep(1000);
            continue;
        }
        if (ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED) {
            HANDLE thread = CreateThread(nullptr, 0, Serve, pipe, 0, nullptr);
            if (thread) CloseHandle(thread); else CloseHandle(pipe);
        } else {
            CloseHandle(pipe);
        }
    }
}

/// One text service's connection: its requests, one at a time, answered on the main thread.
DWORD WINAPI Server::Serve(LPVOID parameter) {
    HANDLE pipe = static_cast<HANDLE>(parameter);
    int client = 0;
    Work work;
    while (ReadMessage(pipe, work.request)) {
        work.client = client;
        SendMessageW(g_server->window_, kRequestMessage, 0, reinterpret_cast<LPARAM>(&work));
        client = work.client;
        if (!WriteMessage(pipe, work.answer)) break;
    }
    if (client) PostMessageW(g_server->window_, kDisconnectMessage, static_cast<WPARAM>(client), 0);
    DisconnectNamedPipe(pipe);
    CloseHandle(pipe);
    return 0;
}

std::string Server::Handle(const std::string &text, int &connectionClient) {
    Json request = Json::parse(text);
    std::string op = request["op"].asString();
    std::string answer = Bridge::Shared().RequestText(text);
    Json response = Json::parse(answer);
    int id = request["client"].asInt();

    if (op == "attach") {
        id = response["reply"]["client"].asInt();
        if (id) {
            Client &client = clients_[id];
            client.window = reinterpret_cast<HWND>(static_cast<uintptr_t>(request["window"].asNumber()));
            client.pid = static_cast<DWORD>(request["pid"].asNumber());
            connectionClient = id;
        }
        return answer;
    }
    if (op == "detach") {
        Disconnected(id);
        connectionClient = 0;
        return answer;
    }
    auto found = clients_.find(id);
    if (found != clients_.end()) {
        Client &client = found->second;
        bool ok = false;
        RECT word = RectFrom(request["rects"]["word"], ok);
        if (op == "key") { client.keyWord = word; client.hasKeyWord = ok; }
        if (ok) { client.word = word; client.hasWord = true; }
        RECT caret = RectFrom(request["rects"]["caret"], ok);
        if (ok) { client.caret = caret; client.hasCaret = true; }
        if (op == "focus") HideAll();
        const Json &ui = response["ui"];
        if (op == "place") {
            client.preview = Wide(request["preview"].asString());
            DrawSoon(id);
        } else if (ui.isObject()) {
            client.ui = ui;
            const Json &tab = ui["openSettings"];
            if (tab.isString()) OpenSettings(tab.asString());
            if (ui["settingsChanged"].asBool()) SendToSettings(kCopyFilesChanged, "");
            // A key's answer is drawn once the text service says where the word went (`place`).
            if (op != "key" && op != "keyUp" && op != "pending" && op != "blur") DrawSoon(id);
        } else if (op == "key" || op == "keyUp" || op == "pending" || op == "blur" || op == "terminated") {
            client.ui = Json();
            if (stripFor_ == id) strip_.Hide();
        }
    }
    Notify(response);
    return answer;
}

/// Draws once the answer is on its way: the text service waits for it (200 ms for `place`), and
/// drawing can take longer, the first time above all (the window, its fonts). An answer too late
/// left the text service without one.
void Server::DrawSoon(int id) {
    if (drawPending_.insert(id).second) PostMessageW(window_, kDrawMessage, static_cast<WPARAM>(id), 0);
}

void Server::Draw(int id) {
    auto found = clients_.find(id);
    if (found == clients_.end()) return;
    Client &client = found->second;
    const Json &ui = client.ui;
    RECT anchor = client.hasWord ? client.word : client.caret;
    bool placed = client.hasWord || client.hasCaret;
    if (!client.preview.empty() && client.hasCaret) {
        word_.Show(client.preview, client.caret);
        wordFor_ = id;
        RECT shown;
        if (word_.Shown(shown)) anchor = shown; // the candidates go under the word
    } else if (wordFor_ == id) {
        word_.Hide();
        wordFor_ = 0;
    }
    // One strip shows them all, so this is the one place that decides which: the candidates while a
    // clause is converted, else the readings a switch key just went through, else what a
    // correction did, by the word it was about.
    const Json &list = ui["candidates"];
    const Json &readings = ui["readings"];
    const Json &learned = ui["learned"];
    auto ask = [this, id](const char *op, int index) {
        Json request = Json::object();
        request.set("op", op);
        request.set("client", id);
        request.set("index", index);
        Notify(Bridge::Shared().Request(request));
    };
    if (list.isObject() && placed) {
        std::vector<std::wstring> texts;
        for (const Json &text : list["texts"].items()) texts.push_back(Wide(text.asString()));
        strip_.ShowCandidates(texts, list["selected"].asInt(), Wide(list["reading"].asString()), anchor,
                              [ask](int index) { ask("choose", index); });
        stripFor_ = id;
    } else if (readings.isObject() && placed) {
        std::vector<std::wstring> texts;
        std::vector<StripWindow::Mark> marks;
        int remembered = readings["remembered"].asInt(-1), once = readings["once"].asInt(-1);
        for (size_t k = 0; k < readings["texts"].size(); k++) {
            texts.push_back(Wide(readings["texts"][k].asString()));
            int index = static_cast<int>(k);
            marks.push_back(index == remembered ? StripWindow::Mark::remembered
                            : index == once     ? StripWindow::Mark::once
                                                : StripWindow::Mark::none);
        }
        strip_.ShowReadings(texts, marks, readings["selected"].asInt(), anchor, [ask](int index) { ask("pick", index); });
        stripFor_ = id;
    } else if (learned.isObject() && (client.hasKeyWord || client.hasWord)) {
        strip_.Settle(Wide(learned["text"].asString()), learned["learning"].asString(),
                      client.hasKeyWord ? client.keyWord : client.word);
        stripFor_ = id;
    } else if (stripFor_ == id) {
        strip_.Hide();
    }
    client.ui.remove("learned");
    if (ui["paused"].isBool()) strip_.Hide(true);
    if (ui["paused"].isBool() && client.hasCaret) pause_.Show(ui["paused"].asBool(), client.caret);
    else if (ui["paused"].isBool() && placed) pause_.Show(ui["paused"].asBool(), anchor);
    // Shown once: the next answer says again what to draw.
    client.ui.remove("paused");
}

void Server::HideAll() {
    strip_.Hide(true);
    stripFor_ = 0;
    word_.Hide();
    wordFor_ = 0;
}

/// The text services with edits waiting fetch them now.
void Server::Notify(const Json &response) {
    for (const Json &id : response["notify"].items()) {
        auto found = clients_.find(id.asInt());
        if (found != clients_.end() && found->second.window) {
            PostMessageW(found->second.window, pendingMessage_, 0, 0);
        }
    }
}

void Server::Disconnected(int id) {
    if (!id || !clients_.count(id)) return;
    Json detach = Json::object();
    detach.set("op", "detach");
    detach.set("client", id);
    Bridge::Shared().Request(detach);
    if (stripFor_ == id || wordFor_ == id) HideAll();
    clients_.erase(id);
}

void Server::SendToSettings(ULONG_PTR kind, const std::string &data) {
    HWND settings = FindWindowW(kSettingsWindowClass, nullptr);
    if (!settings) return;
    COPYDATASTRUCT copy = {kind, static_cast<DWORD>(data.size()), const_cast<char *>(data.data())};
    SendMessageTimeoutW(settings, WM_COPYDATA, reinterpret_cast<WPARAM>(window_), reinterpret_cast<LPARAM>(&copy),
                        SMTO_ABORTIFHUNG, 300, nullptr);
}

/// Asks GitHub for the latest release once a day (when allowed), on a worker thread.
void Server::CheckForUpdates(bool always) {
    Json request = Json::object();
    request.set("op", "settings");
    Json model = Bridge::Shared().Request(request)["settings"];
    if (!model["settings"]["checkForUpdates"].asBool(true)) return;
    double now = static_cast<double>(std::time(nullptr));
    if (!always && now - model["checked"].asNumber() < 24 * 60 * 60) return;
    CloseHandle(CreateThread(nullptr, 0, FetchRelease, window_, 0, nullptr));
}

LRESULT CALLBACK Server::Proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    Server *self = g_server;
    switch (message) {
    case kRequestMessage: {
        auto *work = reinterpret_cast<Work *>(lParam);
        work->answer = self->Handle(work->request, work->client);
        return 0;
    }
    case kDrawMessage:
        self->drawPending_.erase(static_cast<int>(wParam));
        self->Draw(static_cast<int>(wParam));
        return 0;
    case kDisconnectMessage:
        self->Disconnected(static_cast<int>(wParam));
        return 0;
    case kReleaseMessage: {
        auto *body = reinterpret_cast<std::string *>(lParam);
        Json request = Json::object();
        request.set("op", "release");
        if (!body->empty()) request.set("body", *body);
        Bridge::Shared().Request(request);
        self->SendToSettings(kCopyFilesChanged, "");
        delete body;
        return 0;
    }
    case WM_TIMER:
        if (wParam == kUpdateTimer) {
            SetTimer(window, kUpdateTimer, 60 * 60 * 1000, nullptr);
            self->CheckForUpdates(false);
        }
        return 0;
    case WM_COPYDATA: {
        auto *copy = reinterpret_cast<COPYDATASTRUCT *>(lParam);
        std::string data(static_cast<const char *>(copy->lpData), copy->cbData);
        if (copy->dwData == kCopyReload) {
            Json request = Json::object();
            request.set("op", "reload");
            request.set("kanjiReset", data == "kanjiReset");
            Bridge::Shared().Request(request);
        } else if (copy->dwData == kCopyVim) {
            Json signal = Json::parse(data);
            Json request = Json::object();
            request.set("op", "vim");
            request.set("vim", signal["vim"]);
            if (signal["app"].isString()) request.set("app", signal["app"]);
            self->Notify(Bridge::Shared().Request(request));
        }
        return TRUE;
    }
    case WM_DISPLAYCHANGE:
    case WM_SETTINGCHANGE:
        self->HideAll();
        return 0;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

}  // namespace araso
