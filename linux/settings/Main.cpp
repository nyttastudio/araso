// araso-settings: what `Araso --settings` and `Araso --vim` are on macOS and ArasoHost.exe's on Windows.
//   --settings [tab]                        the settings window: general, keys, apps, learning, typing, about
//   --vim insert|normal|off [--app <name>]  vim's mode (scripts/vim), passed to the addon
//   --check-update                          the addon's daily update check, without a window
#include "Settings.h"

#include <QApplication>
#include <QCoreApplication>

#include <cstring>
#include <string>

namespace {

const char *After(int argc, char **argv, const char *flag) {
    for (int k = 1; k + 1 < argc; k++) {
        if (std::strcmp(argv[k], flag) == 0 && argv[k + 1][0] != '-') return argv[k + 1];
    }
    return nullptr;
}

bool Has(int argc, char **argv, const char *flag) {
    for (int k = 1; k < argc; k++) if (std::strcmp(argv[k], flag) == 0) return true;
    return false;
}

}  // namespace

int main(int argc, char **argv) {
    using araso::Json;
    if (Has(argc, argv, "--vim")) {
        // Nothing to start: one datagram to the addon, which hands it to the session in front.
        const char *mode = After(argc, argv, "--vim");
        if (!mode) return 2;
        Json signal = Json::object();
        signal.set("op", "vim");
        signal.set("vim", mode);
        if (const char *app = After(argc, argv, "--app")) {
            std::string name = app;
            for (char &c : name) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
            if (!name.empty()) signal.set("app", name);
        }
        return araso::Send("ime", signal.dump()) ? 0 : 1;
    }
    if (Has(argc, argv, "--check-update")) {
        QCoreApplication app(argc, argv);
        return araso::CheckUpdateQuietly();
    }
    QApplication app(argc, argv);
    QApplication::setApplicationName("araso-settings");
    QApplication::setDesktopFileName("araso-settings");
    const char *tab = After(argc, argv, "--settings");
    return araso::RunSettings(tab ? tab : "general");
}
