import Foundation

/// A bounded liveness check, not an authentication mechanism. Only the warmed-up IMK server
/// answers: another Araso process (settings, registration or a self-test) is not proof of input.
enum InputServerHealth {
    private static let request = Notification.Name("com.nyttastudio.inputmethod.Araso.checkServer")
    private static let response = Notification.Name("com.nyttastudio.inputmethod.Araso.serverReady")

    static func respond(bundleURL: URL = Bundle.main.bundleURL) -> NSObjectProtocol {
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let center = DistributedNotificationCenter.default()
        return center.addObserver(forName: request, object: nil, queue: .main) { note in
            guard let token = note.object as? String, UUID(uuidString: token) != nil else { return }
            center.postNotificationName(response, object: token, userInfo: ["bundlePath": path],
                                        deliverImmediately: true)
        }
    }

    /// Does not launch, enable or select an input source. A different build cannot satisfy it.
    static func check(bundleURL: URL = Bundle.main.bundleURL, timeout: TimeInterval = 5) -> Bool {
        let center = DistributedNotificationCenter.default()
        let token = UUID().uuidString
        let path = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        var ready = false
        let observer = center.addObserver(forName: response, object: token, queue: .main) { note in
            if note.userInfo?["bundlePath"] as? String == path { ready = true }
        }
        defer { center.removeObserver(observer) }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        repeat {
            center.postNotificationName(request, object: token, userInfo: nil, deliverImmediately: true)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            if ready { return true }
        } while ProcessInfo.processInfo.systemUptime < deadline
        return false
    }
}
