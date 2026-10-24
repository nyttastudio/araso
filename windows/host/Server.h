// `ArasoHost.exe --server`: one per user session, started at sign-in. Text services connect over
// the named pipe; each request goes to the main thread, through the bridge, and back, and the UI
// the session asks for is drawn here.
#pragma once

#include "../common/Common.h"
#include "../common/Json.h"
#include "Strip.h"
#include "Ui.h"

#include <map>
#include <set>
#include <string>

namespace araso {

class Server {
public:
    int Run();

    /// Starts the settings window at `tab` (its own process).
    static void OpenSettings(const std::string &tab);

private:
    struct Client {
        HWND window = nullptr;
        DWORD pid = 0;
        RECT word = {};
        RECT caret = {};
        bool hasWord = false;
        bool hasCaret = false;
        /// The word as it was when the last key was pressed, before that key changed it: the word
        /// a correction was about, which that key put in.
        RECT keyWord = {};
        bool hasKeyWord = false;
        /// What the last answer asked to draw, shown once the text service says where (`place`).
        Json ui;
        /// The word being typed where the app can't show it composed (`place`'s `preview`).
        std::wstring preview;
    };

    HWND window_ = nullptr;
    std::map<int, Client> clients_;
    StripWindow strip_;
    PauseHud pause_;
    WordWindow word_;
    int wordFor_ = 0;
    int stripFor_ = 0;
    UINT pendingMessage_ = 0;
    /// Clients whose UI is drawn as soon as the answer has gone (`DrawSoon`).
    std::set<int> drawPending_;

    static LRESULT CALLBACK Proc(HWND window, UINT message, WPARAM wParam, LPARAM lParam);
    static DWORD WINAPI Listen(LPVOID server);
    static DWORD WINAPI Serve(LPVOID connection);

    /// One request from a text service (on the main thread): the answer to send back.
    std::string Handle(const std::string &request, int &connectionClient);
    void Disconnected(int client);
    void Notify(const Json &response);
    void Draw(int client);
    void DrawSoon(int client);
    void HideAll();
    void SendToSettings(ULONG_PTR kind, const std::string &data);
    void CheckForUpdates(bool always);
};

}  // namespace araso
