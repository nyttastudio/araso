// The About pane: version, updates (Updater.swift on macOS, Updater.cpp on Windows) and files.
#include "Settings.h"

#include "araso_config.h"

#include <QCoreApplication>
#include <QDesktopServices>
#include <QDir>
#include <QFile>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QPushButton>
#include <QStandardPaths>
#include <QTimer>
#include <QUrl>

#include <cstdlib>
#include <ctime>

namespace araso {
namespace settings {

namespace {

const char *kLatest = "https://api.github.com/repos/nyttastudio/araso/releases/latest";
const char *kReleases = "https://github.com/nyttastudio/araso/releases/latest";

/// GitHub's latest release (or ARASO_UPDATE_FEED's file), then `done` with its body (empty: failed).
void FetchRelease(QObject *owner, std::function<void(const std::string &)> done) {
    const char *feed = std::getenv("ARASO_UPDATE_FEED");
    QUrl url(feed && *feed ? QString(feed) : QString(kLatest));
    if (url.isLocalFile()) {
        QFile file(url.toLocalFile());
        std::string body = file.open(QIODevice::ReadOnly) ? file.readAll().toStdString() : std::string();
        // Later, as a reply would come: callers quit an event loop they haven't entered yet.
        QTimer::singleShot(0, owner, [done, body] { done(body); });
        return;
    }
    auto *network = new QNetworkAccessManager(owner);
    QNetworkRequest request(url);
    request.setRawHeader("Accept", "application/vnd.github+json");
    request.setRawHeader("User-Agent", "Araso/" ARASO_VERSION);
    request.setTransferTimeout(15000);
    QNetworkReply *reply = network->get(request);
    QObject::connect(reply, &QNetworkReply::finished, owner, [reply, network, done] {
        std::string body = reply->error() == QNetworkReply::NoError ? reply->readAll().toStdString() : std::string();
        reply->deleteLater();
        network->deleteLater();
        done(body);
    });
}

/// The answer to `release`: what GitHub said, kept for the addon's menu too.
Json Released(const std::string &body) {
    Json request = Json::object();
    request.set("op", "release");
    if (!body.empty()) request.set("body", body);
    return Request(request);
}

std::string Uninstaller() { return std::string(ARASO_LIBDIR) + "/uninstall.sh"; }

}  // namespace

void CheckForUpdates() {
    if (g.busy) return;
    g.busy = true;
    g.updateStatus = T("Checking for updates…");
    FetchRelease(g.window, [](const std::string &body) {
        g.busy = false;
        Json answer = Released(body);
        if (!answer["release"].isObject()) {
            g.updateStatus = T("Couldn't reach GitHub. Try again later.");
        } else if (answer["release"]["newer"].asBool()) {
            g.updateStatus = T("Araso %@ is available", {answer["release"]["version"].asString()});
        } else {
            g.updateStatus = T("Araso is up to date");
        }
        LoadModel();
        // The input menu offers the update too.
        TellInputMethod();
        if (g.pane == PaneIndex("about")) Rebuild();
    });
}

void BuildAbout() {
    const Json &update = g.model["update"];
    Heading(T("Version %@", {g.model["version"].asString()}));

    Heading(T("Updates"));
    if (!g.updateStatus.isEmpty()) Note(g.updateStatus);
    auto *row = Line();
    Push(T("Check Now"), [] {
        CheckForUpdates();
        Rebuild();
    }, !g.busy, row);
    if (update.isObject()) {
        // No package to check and install here: the release's own install script does it.
        std::string page = update["page"].isString() ? update["page"].asString() : kReleases;
        Push(T("Install %@…", {update["version"].asString()}), [page] { QDesktopServices::openUrl(QUrl(Q(page))); },
             !g.busy, row);
    }
    row->addStretch(1);
    if (update.isObject() && update["notes"].size() > 0) {
        Heading(T("What's changed"));
        for (const Json &note : update["notes"].items()) {
            QString line = "•  " + Q(note["title"].asString());
            if (note["detail"].isString()) line += " — " + Q(note["detail"].asString());
            Note(line);
        }
        std::string page = update["page"].asString();
        Push(T("Full Release Notes"), [page] { QDesktopServices::openUrl(QUrl(Q(page))); }, !page.empty());
    }
    Note(T("Updates come from the release page: download the new version and run its install.sh."));
    Check(T("Check for updates automatically"), g.model["settings"]["checkForUpdates"].asBool(true), true,
          [](bool on) { ChangeSettings([on](Json &s) { s.set("checkForUpdates", on); }); });
    Note(T("Once a day, and each time this window opens. Only the latest version number is asked of GitHub; nothing you type is sent."), 20);

    Heading(T("Settings files"));
    Note(T("Settings, per-app rules and the dictionary are JSON files in this folder."));
    Note(Q(Bridge::supportFolder()));
    Push(T("Open Settings Folder"), [] {
        QString folder = Q(Bridge::supportFolder());
        QDir().mkpath(folder);
        QDesktopServices::openUrl(QUrl::fromLocalFile(folder));
    });

    Heading(T("Uninstall Araso"));
    bool installed = QFile::exists(Q(Uninstaller()));
    Note(installed ? T("Removes Araso from this computer; it asks for your password. Settings and learned words can go too.")
                   : T("Araso isn't installed here, so it can't be uninstalled from this window."));
    Push(T("Uninstall…"), [] {
        if (!Confirm(T("Uninstall Araso?"),
                     T("Removes Araso from this computer; it asks for your password. Settings and learned words can go too."))) {
            return;
        }
        bool data = Confirm(T("Delete settings and learned words too?"), Q(Bridge::supportFolder()));
        QStringList arguments = {Q(Uninstaller())};
        if (QProcess::execute("pkexec", arguments) != 0) return;
        if (data) QDir(Q(Bridge::supportFolder())).removeRecursively();
        qApp->quit();
    }, installed);
}

}  // namespace settings

int CheckUpdateQuietly() {
    using namespace settings;
    std::string error;
    if (!Bridge::shared().start(error, false)) return 1;
    LoadModel();
    // Once a day at most, and only when updates are on (the addon asks every few hours).
    double checked = g.model["checked"].asNumber();
    if (!g.model["settings"]["checkForUpdates"].asBool(true) || std::time(nullptr) - checked < 24 * 3600) return 0;
    int status = 1;
    FetchRelease(qApp, [&status](const std::string &body) {
        Json answer = Released(body);
        status = answer["release"].isObject() ? 0 : 1;
        TellInputMethod();
        qApp->quit();
    });
    qApp->exec();
    return status;
}

}  // namespace araso
