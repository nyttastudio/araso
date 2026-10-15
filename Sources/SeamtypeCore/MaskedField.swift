import Foundation

/// A masked password field that still reaches the input method (KakaoTalk's login, App Store's
/// password sheet). Asked to show marked text while handling a key, KakaoTalk's types that key
/// itself (lowercase when ⇧ was already down) and drops what the input method inserts; App
/// Store's loses keys. Its keys go to the app as typed, as when paused.
public enum MaskedField {
    /// Whether the focused field is one: Secure Event Input is on, held by the frontmost app,
    /// and the field reports no caret.
    /// - The frontmost app, not the client's: App Store's sheet is a PassKit extension while
    ///   App Store holds Secure Event Input. An app behind the one being typed in doesn't count.
    /// - A terminal with Secure Keyboard Entry holds it too, but reports its caret.
    /// - `owner` is `kCGSSessionSecureInputPID`, `frontmost` the frontmost app's process.
    public static func passesKeys(secureInput: Bool, owner: Int32?, frontmost: Int32?, caret: NSRange) -> Bool {
        guard secureInput, caret.location == NSNotFound, let owner else { return false }
        return owner == frontmost
    }
}

/// A terminal asking for a password (sudo, ssh): one of this user's terminals reads a line with
/// echo off, as a password prompt does (vim and other full-screen programs read raw keys, not
/// lines). Keys go to whichever app has focus as typed, as in a masked field.
public enum PasswordPrompt {
    public static func isWaiting(devices: [String] = terminalDevices()) -> Bool {
        devices.contains { path in
            let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var t = termios()
            return tcgetattr(fd, &t) == 0 && readsPassword(t.c_lflag)
        }
    }

    static func readsPassword(_ lflag: tcflag_t) -> Bool {
        lflag & tcflag_t(ICANON) != 0 && lflag & tcflag_t(ECHO) == 0
    }

    public static func terminalDevices() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("ttys") }.map { "/dev/" + $0 }
    }
}
