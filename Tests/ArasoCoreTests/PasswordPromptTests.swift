#if canImport(Darwin)
import Foundation
import Testing
@testable import ArasoCore

/// A terminal waiting for a password gets the keys as typed (`PasswordPrompt`).
@Suite struct PasswordPromptTests {
    /// A line read with echo off (sudo's prompt) is a password; echo on or raw keys (vim) aren't.
    @Test func passwordPromptIsALineReadWithEchoOff() throws {
        var master: Int32 = 0, slave: Int32 = 0
        try #require(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { close(master); close(slave) }
        let path = String(cString: ttyname(slave))
        var t = termios()
        tcgetattr(slave, &t)
        #expect(!PasswordPrompt.isWaiting(devices: [path]))
        t.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(slave, TCSANOW, &t)
        #expect(PasswordPrompt.isWaiting(devices: [path]))
        t.c_lflag &= ~tcflag_t(ICANON)
        tcsetattr(slave, TCSANOW, &t)
        #expect(!PasswordPrompt.isWaiting(devices: [path]))
    }

    /// A tty that is gone, or a path that isn't one, doesn't count.
    @Test func missingDeviceIsNotWaiting() {
        #expect(!PasswordPrompt.isWaiting(devices: ["/dev/ttys-araso-missing", "/dev/null"]))
    }

    @Test func devicesArePseudoTerminals() {
        #expect(PasswordPrompt.terminalDevices().allSatisfy { $0.hasPrefix("/dev/ttys") })
    }
}
#endif
