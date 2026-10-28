// The About pane: version, updates (Updater.swift on macOS) and files.
#include "SettingsInternal.h"
#include "Updater.h"

#include <shellapi.h>

#include <ctime>

namespace araso {
namespace settings {

namespace {

std::wstring TempInstaller(const std::string &version) {
    wchar_t folder[MAX_PATH] = L"";
    GetTempPathW(MAX_PATH, folder);
    return std::wstring(folder) + L"Araso-Setup-" + Wide(version) + L".exe";
}

void Open(const std::wstring &target) {
    ShellExecuteW(g.frame, L"open", target.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
}

struct DownloadJob {
    std::wstring url, path;
    HWND window;
};

DWORD WINAPI DownloadInstaller(LPVOID parameter) {
    auto *job = static_cast<DownloadJob *>(parameter);
    auto *path = new std::wstring(updater::Download(job->url, job->path) ? job->path : L"");
    PostMessageW(job->window, kDownloaded, 0, reinterpret_cast<LPARAM>(path));
    delete job;
    return 0;
}

DWORD WINAPI FetchRelease(LPVOID parameter) {
    wchar_t feed[1024] = L"";
    std::wstring url = GetEnvironmentVariableW(L"ARASO_UPDATE_FEED", feed, 1024) ? feed : updater::kLatest;
    auto *body = new std::string();
    if (!updater::Get(url, *body)) body->clear();
    PostMessageW(static_cast<HWND>(parameter), kReleaseChecked, 0, reinterpret_cast<LPARAM>(body));
    return 0;
}

/// Downloads the installer on a worker thread; `Downloaded` checks and opens it.
void Install() {
    const Json &update = g.model["update"];
    if (!update.isObject() || g.busy) return;
    // A copy built without a signing identity can't check the installer's: the release page instead.
    if (updater::Publisher().empty()) {
        Open(Wide(update["page"].isString() ? update["page"].asString()
                                            : "https://github.com/nyttastudio/araso/releases/latest"));
        return;
    }
    g.busy = true;
    g.updateStatus = L("Downloading… The installer opens when it's done.");
    Rebuild();
    auto *job = new DownloadJob{Wide(update["installer"].asString()), TempInstaller(update["version"].asString()), g.frame};
    CloseHandle(CreateThread(nullptr, 0, DownloadInstaller, job, 0, nullptr));
}

}  // namespace

void CheckForUpdates() {
    if (g.busy) return;
    g.busy = true;
    g.updateStatus = L("Checking for updates…");
    CloseHandle(CreateThread(nullptr, 0, FetchRelease, g.frame, 0, nullptr));
}

void ReleaseChecked(std::string *body) {
    g.busy = false;
    Json request = Json::object();
    request.set("op", "release");
    if (!body->empty()) request.set("body", *body);
    Json answer = Request(request);
    delete body;
    if (answer["upToDate"].asBool()) {
        g.updateStatus = L("Araso is up to date");
    } else if (!answer["release"].isObject()) {
        g.updateStatus = L("Couldn't reach GitHub. Try again later.");
    } else if (answer["release"]["newer"].asBool()) {
        g.updateStatus = L("Araso %@ is available", {Wide(answer["release"]["version"].asString())});
    } else {
        g.updateStatus = L("Araso is up to date");
    }
    LoadModel();
    if (FindWindowW(kHostWindowClass, nullptr)) {
        // The host's input menu offers the update too.
        HWND host = FindWindowW(kHostWindowClass, nullptr);
        std::string data;
        COPYDATASTRUCT copy = {kCopyReload, 0, data.data()};
        SendMessageTimeoutW(host, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&copy), SMTO_ABORTIFHUNG, 1000, nullptr);
    }
    if (g.pane == 5) Rebuild();
}

void Downloaded(std::wstring *path) {
    g.busy = false;
    std::wstring file = *path;
    delete path;
    if (file.empty()) {
        g.updateStatus = L("Couldn't download the update. Try again later.");
    } else if (!updater::IsSigned(file, updater::Publisher())) {
        DeleteFileW(file.c_str());
        g.updateStatus = L("The downloaded installer isn't signed by Araso's developer, so it was deleted.");
    } else {
        g.updateStatus.clear();
        // The installer asks for administrator rights itself.
        ShellExecuteW(g.frame, L"open", file.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
    }
    if (g.pane == 5) Rebuild();
}

void BuildAbout() {
    const Json &update = g.model["update"];
    Make(L"STATIC", L("Version %@", {Wide(g.model["version"].asString())}), SS_NOPREFIX, Pad(), g.y, ContentWidth(), S(22),
         g.bold);
    g.y += S(30);

    Heading(L("Updates"));
    if (!g.updateStatus.empty()) Note(g.updateStatus);
    Push(L("Check Now"), Pad(), S(140), [] {
        CheckForUpdates();
        Rebuild();
    }, !g.busy);
    if (update.isObject()) {
        Push(L("Install %@…", {Wide(update["version"].asString())}), Pad() + S(150), S(180), Install, !g.busy);
    }
    g.y += S(38);
    if (update.isObject() && update["notes"].size() > 0) {
        Heading(L("What's changed"));
        for (const Json &note : update["notes"].items()) {
            std::wstring line = L"•  " + Wide(note["title"].asString());
            if (note["detail"].isString()) line += L" — " + Wide(note["detail"].asString());
            Note(line);
        }
        std::string page = update["page"].asString();
        Push(L("Full Release Notes"), Pad(), S(180), [page] { Open(Wide(page)); }, !page.empty());
        g.y += S(38);
    }
    if (updater::Publisher().empty()) Note(L("This copy isn't signed, so updates open the release page."));
    Check(L("Check for updates automatically"), g.model["settings"]["checkForUpdates"].asBool(true), true,
          [](bool on) { ChangeSettings([on](Json &s) { s.set("checkForUpdates", on); }); });
    Note(L("Once a day, and each time this window opens. Only the latest version number is asked of GitHub; nothing you type is sent."), S(20));

    Heading(L("Settings files"));
    Note(L("Settings, per-app rules and the dictionary are JSON files in this folder."));
    Push(L("Open Settings Folder"), Pad(), S(200), [] {
        std::wstring folder = Bridge::SupportFolder();
        CreateDirectoryW(folder.c_str(), nullptr);
        Open(folder);
    });
    g.y += S(38);

    Heading(L("Uninstall Araso"));
    std::wstring uninstaller = Bridge::ExeFolder() + L"\\unins000.exe";
    bool installed = GetFileAttributesW(uninstaller.c_str()) != INVALID_FILE_ATTRIBUTES;
    Note(installed ? L("Removes Araso from this PC. The uninstaller asks whether to delete settings and learned words too.")
                   : L("Araso isn't installed here, so it can't be uninstalled from this window."));
    Push(L("Uninstall…"), Pad(), S(140), [uninstaller] {
        if (!Confirm(L("Uninstall Araso?"),
                     L("Removes Araso from this PC. The uninstaller asks whether to delete settings and learned words too."))) {
            return;
        }
        ShellExecuteW(g.frame, L"open", uninstaller.c_str(), nullptr, nullptr, SW_SHOWNORMAL);
        DestroyWindow(g.frame);
    }, installed);
    g.y += S(38);
}

}  // namespace settings
}  // namespace araso
