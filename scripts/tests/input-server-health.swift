// swiftc Sources/Araso/InputServerHealth.swift scripts/tests/input-server-health.swift -o /tmp/araso-health-test
// /tmp/araso-health-test
// Exercises distributed notifications with child processes. No keyboard or input-source changes.
import Foundation
import Darwin

@main struct HealthTests {
    static func main() throws {
        let args = CommandLine.arguments
        if args.count == 3 {
            let observer = args[1] == "--server"
                ? InputServerHealth.respond(bundleURL: URL(fileURLWithPath: args[2])) : nil
            withExtendedLifetime(observer) { RunLoop.current.run() }
            return
        }
        let bundle = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        func check(_ expected: Bool, _ name: String, path: URL? = nil) throws {
            let actual = InputServerHealth.check(bundleURL: path ?? bundle, timeout: 0.5)
            guard actual == expected else { throw NSError(domain: "InputServerHealthTests", code: 1, userInfo: [NSLocalizedDescriptionKey: name]) }
            print("PASS: \(name)")
        }
        func start(_ role: String) throws -> Process {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: args[0])
            process.arguments = [role, bundle.path]
            try process.run()
            return process
        }
        func stop(_ process: Process) {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        try check(false, "no server fails within the deadline")
        let settings = try start("--settings-only")
        defer { stop(settings) }
        try check(false, "another process without an IMK responder is not a server")
        let server = try start("--server")
        defer { if server.isRunning { kill(server.processIdentifier, SIGCONT) }; stop(server) }
        try check(true, "a responsive server at the expected path passes")
        try check(false, "a different build cannot satisfy the probe", path: bundle.appendingPathComponent("other"))
        kill(server.processIdentifier, SIGSTOP)
        try check(false, "a running but blocked server fails within the deadline")
        kill(server.processIdentifier, SIGCONT)
        try check(true, "a responsive server recovers without stale replies")
        stop(server)
        try check(false, "a terminated server fails")
        let restarted = try start("--server")
        defer { stop(restarted) }
        try check(true, "a restarted server passes with a new request token")
    }
}
