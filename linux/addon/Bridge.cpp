#include "Bridge.h"

#include "araso_config.h"

#include <dlfcn.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

#include <cstdlib>
#include <cstring>

namespace araso {

namespace {

std::string Env(const char *name) {
    const char *value = std::getenv(name);
    return value && *value ? value : "";
}

std::string Home() {
    std::string home = Env("HOME");
    return home.empty() ? "/tmp" : home;
}

/// The user's UI language: LC_ALL, LC_MESSAGES, LANG (`ko_KR.UTF-8`).
std::string Language() {
    for (const char *name : {"LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"}) {
        std::string value = Env(name);
        if (!value.empty() && value != "C" && value != "POSIX") return value;
    }
    return "en";
}

std::string Machine() {
#if defined(__x86_64__)
    return "x86_64";
#elif defined(__aarch64__)
    return "aarch64";
#else
    return "unknown";
#endif
}

}  // namespace

Bridge &Bridge::shared() {
    static Bridge bridge;
    return bridge;
}

std::string Bridge::resourcesFolder() {
    std::string env = Env("ARASO_RESOURCES");
    return env.empty() ? ARASO_DATADIR : env;
}

std::string Bridge::bridgePath() {
    std::string env = Env("ARASO_BRIDGE");
    return env.empty() ? std::string(ARASO_LIBDIR) + "/libArasoBridge.so" : env;
}

std::string Bridge::settingsProgram() {
    std::string env = Env("ARASO_SETTINGS");
    return env.empty() ? std::string(ARASO_BINDIR) + "/araso-settings" : env;
}

std::string Bridge::supportFolder() {
    std::string env = Env("ARASO_SUPPORT_DIR");
    if (!env.empty()) return env;
    std::string config = Env("XDG_CONFIG_HOME");
    return (config.empty() ? Home() + "/.config" : config) + "/araso";
}

std::string Bridge::socketFolder() {
    std::string runtime = Env("XDG_RUNTIME_DIR");
    // Without a runtime folder (a bare session): one of this user's own in /tmp.
    return runtime.empty() ? "/tmp/araso-" + std::to_string(getuid()) : runtime + "/araso";
}

std::string Bridge::version() { return ARASO_VERSION; }

std::string Bridge::asset() { return "Araso-linux-" + Machine() + ".tar.gz"; }

bool Bridge::start(std::string &error, bool converter) {
    if (request_) return true;
    std::string path = bridgePath();
    // RTLD_LOCAL: the Swift runtime inside stays to itself, beside any other addon's.
    module_ = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (!module_) {
        const char *why = dlerror();
        error = "can't load " + path + (why ? std::string(": ") + why : "");
        return false;
    }
    start_ = reinterpret_cast<StartFn>(dlsym(module_, "araso_start"));
    warmUp_ = reinterpret_cast<WarmUpFn>(dlsym(module_, "araso_warm_up"));
    request_ = reinterpret_cast<RequestFn>(dlsym(module_, "araso_request"));
    localize_ = reinterpret_cast<RequestFn>(dlsym(module_, "araso_localize"));
    free_ = reinterpret_cast<FreeFn>(dlsym(module_, "araso_free"));
    if (!start_ || !warmUp_ || !request_ || !localize_ || !free_) {
        error = path + " isn't Araso's bridge";
        request_ = nullptr;
        return false;
    }
    Json config = Json::object();
    config.set("resources", resourcesFolder());
    config.set("support", supportFolder());
    config.set("version", version());
    config.set("language", Language());
    config.set("ownApp", "araso-settings");
    config.set("converter", converter);
    config.set("platform", "linux");
    config.set("asset", asset());
    if (start_(config.dump().c_str()) != 0) {
        error = "the bridge didn't start";
        request_ = nullptr;
        return false;
    }
    return true;
}

void Bridge::warmUp() {
    if (warmUp_) warmUp_();
}

Json Bridge::request(const Json &request) {
    if (!request_) return Json();
    char *answer = request_(request.dump().c_str());
    if (!answer) return Json();
    Json parsed = Json::parse(answer);
    free_(answer);
    return parsed;
}

std::string Bridge::localize(const char *english) {
    if (!localize_) return english;
    char *answer = localize_(english);
    if (!answer) return english;
    std::string out = answer;
    free_(answer);
    return out;
}

std::string L(const char *english) { return Bridge::shared().localize(english); }

std::string L(const char *english, std::initializer_list<std::string> arguments) {
    std::string format = L(english), out;
    auto next = arguments.begin();
    for (size_t i = 0; i < format.size(); ++i) {
        if (format[i] != '%' || i + 1 >= format.size()) { out += format[i]; continue; }
        size_t length = 0;
        for (const char *spec : {"@", "ld", "lu", "d"}) {
            if (format.compare(i + 1, std::strlen(spec), spec) == 0) { length = std::strlen(spec); break; }
        }
        if (length) {
            if (next != arguments.end()) out += *next++;
            i += length;
        } else if (format[i + 1] == '%') {
            out += '%';
            ++i;
        } else {
            out += '%';
        }
    }
    return out;
}

bool Send(const std::string &name, const std::string &message) {
    std::string path = Bridge::socketFolder() + "/" + name;
    sockaddr_un address{};
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof address.sun_path) return false;
    std::memcpy(address.sun_path, path.c_str(), path.size() + 1);
    int fd = socket(AF_UNIX, SOCK_DGRAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return false;
    bool sent = sendto(fd, message.data(), message.size(), 0, reinterpret_cast<sockaddr *>(&address), sizeof address) ==
                static_cast<ssize_t>(message.size());
    close(fd);
    return sent;
}

}  // namespace araso
