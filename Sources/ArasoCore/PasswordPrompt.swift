import Foundation

#if canImport(Darwin)
/// A terminal asking for a password (sudo, ssh): one of this user's terminals reads a line with
/// echo off, as a password prompt does (vim and other full-screen programs read raw keys, not
/// lines). Terminals that don't turn on Secure Event Input for it (Orca, Claude's) tell the input
/// method nothing, so the keys go to whichever app has focus as typed, as in a masked field.
/// - The input method can't tell which tty the focused tab is: another tab's prompt passes the
///   keys in every app until it ends (sudo gives up after 5 minutes).
/// - A prompt on the far side of ssh isn't seen: the local tty is raw while ssh runs.
public enum PasswordPrompt {
    /// Whether one of `devices` reads a password. A tty that isn't this user's, or isn't open,
    /// doesn't open and doesn't count. About 1–2 ms for 25–40 ttys.
    public static func isWaiting(devices: [String] = terminalDevices()) -> Bool {
        devices.contains { path in
            let fd = open(path, O_RDONLY | O_NOCTTY | O_NONBLOCK)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var t = termios()
            return tcgetattr(fd, &t) == 0 && readsPassword(t.c_lflag)
        }
    }

    /// A line read with echo off.
    static func readsPassword(_ lflag: tcflag_t) -> Bool {
        lflag & tcflag_t(ICANON) != 0 && lflag & tcflag_t(ECHO) == 0
    }

    /// The pseudo-terminals' devices, `/dev/ttys*`.
    public static func terminalDevices() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? [])
            .filter { $0.hasPrefix("ttys") }.map { "/dev/" + $0 }
    }
}
#endif
