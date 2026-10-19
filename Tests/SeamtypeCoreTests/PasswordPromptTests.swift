import Foundation
import Testing
@testable import SeamtypeCore

@Suite struct PasswordPromptTests {
    /// A line read with echo off (sudo's prompt) is a password; echo on or raw keys (vim) aren't.
    @Test func passwordPromptIsALineReadWithEchoOff() throws {
        var master: Int32 = 0, slave: Int32 = 0
        try #require(openpty(&master, &slave, nil, nil, nil) == 0)
        defer { close(master); close(slave) }
        let path = String(cString: ttyname(slave))
        #expect(PasswordPrompt.terminalDevices().contains(path))
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
}
