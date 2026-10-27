// libArasoBridge.so (Swift: ArasoService over ArasoCore, Sources/ArasoBridge), loaded at run time.
// Every request and answer is JSON (`ServiceRequest`, `ServiceResponse`). Called on fcitx5's main
// thread only (Swift's main actor), in the addon and in araso-settings alike.
#pragma once

#include "Json.h"

#include <initializer_list>
#include <string>

namespace araso {

class Bridge {
public:
    /// Loads the library and starts the runtime with the install's resources and the user's
    /// settings folder. False (with `error`) when the library can't be loaded.
    /// `converter`: load the kanji converter too (the input method; the settings window doesn't).
    /// `ownApp`: the program whose field reports how words were decided (Try Typing).
    bool start(std::string &error, bool converter = true);
    void warmUp();
    bool started() const { return request_ != nullptr; }

    /// One request; the parsed answer (Null when the bridge isn't there).
    Json request(const Json &request);
    std::string localize(const char *english);

    static Bridge &shared();

    /// Where things are: the data files (`<prefix>/share/araso`), the bridge library, the settings
    /// program, and the settings folder (`$XDG_CONFIG_HOME/araso`). Each can be set by the
    /// environment (ARASO_RESOURCES, ARASO_BRIDGE, ARASO_SETTINGS, ARASO_SUPPORT_DIR) for
    /// development and tests.
    static std::string resourcesFolder();
    static std::string bridgePath();
    static std::string settingsProgram();
    static std::string supportFolder();
    /// The socket the addon listens on (`$XDG_RUNTIME_DIR/araso/ime`) and the settings window's.
    static std::string socketFolder();
    static std::string version();
    /// The release asset this machine updates from (`Araso-linux-x86_64.tar.gz`).
    static std::string asset();

private:
    using StartFn = int (*)(const char *);
    using WarmUpFn = void (*)();
    using RequestFn = char *(*)(const char *);
    using FreeFn = void (*)(char *);

    void *module_ = nullptr;
    StartFn start_ = nullptr;
    WarmUpFn warmUp_ = nullptr;
    RequestFn request_ = nullptr;
    RequestFn localize_ = nullptr;
    FreeFn free_ = nullptr;
};

/// UI text in the user's language (Localizable.strings through the bridge); English is the key.
std::string L(const char *english);
/// `L` with `%@`/`%ld`/`%d` filled in order.
std::string L(const char *english, std::initializer_list<std::string> arguments);

/// Sends one datagram to the socket `name` in `Bridge::socketFolder()`; false when nobody listens.
bool Send(const std::string &name, const std::string &message);

}  // namespace araso
