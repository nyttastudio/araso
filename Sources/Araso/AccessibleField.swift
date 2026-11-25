import ApplicationServices
import ArasoCore
import Cocoa
import os

private let log = Logger(subsystem: "com.nyttastudio.inputmethod.Araso", category: "input")

/// The focused field as Accessibility describes it, for password fields nothing else gives away
/// (`MaskedField.isSecure`: LINE's login). Only where the user gave Araso Accessibility; Araso
/// never asks for it.
///
/// Never asked while a key is handled: the app waits for the key's answer then and can't answer
/// Accessibility (LINE timed out on every key, real keys, 2026-11-25). The app's focus changes are
/// watched instead (`watch`; LINE posts one for each field), and each newly focused element is
/// looked at when it comes, before the keys typed into it. Everything Accessibility is asked
/// goes through `queue`, so an app slow to answer never holds up the keys of another.
@MainActor enum AccessibleField {
    /// Every language's role description of a secure text field: an app answers in its own.
    nonisolated private static let secureDescriptions: Set<String> = {
        let url = URL(fileURLWithPath: "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Resources/RoleDescriptions.loctable")
        var descriptions = (NSDictionary(contentsOf: url) as? [String: Any]).map(MaskedField.secureDescriptions) ?? []
        if let own = NSAccessibility.Role.textField.description(with: .secureTextField) { descriptions.insert(own) }
        return descriptions
    }()

    nonisolated private static let queue = DispatchQueue(label: "com.nyttastudio.inputmethod.Araso.accessibility")
    /// How long an answer may take, on `queue`.
    nonisolated private static let timeout: Float = 0.25

    /// An observer made on `queue`, handed to the main run loop.
    private final class Watch: @unchecked Sendable {
        let pid: pid_t
        let observer: AXObserver
        init(pid: pid_t, observer: AXObserver) { self.pid = pid; self.observer = observer }
    }

    private static var watched: Watch?
    /// The app being watched, or about to be.
    private static var wanted: pid_t?
    /// Whether the focused element of the watched app is a secure text field, as last looked at.
    private static var secure = false

    /// Whether the focused element of the active text field's app (`watch`) was a secure text
    /// field when it got the focus.
    static var isSecure: Bool { watched != nil && secure }

    /// Watches the focus of the app with this bundle identifier (the text field's), letting go of
    /// the one watched before, when a text field becomes active. Already watched, its focused
    /// element is looked at again (a window that came without a focus change); tried again when
    /// it couldn't be watched. Nothing without Accessibility.
    static func watch(app bundleIdentifier: String?) {
        let apps = bundleIdentifier.map(NSRunningApplication.runningApplications(withBundleIdentifier:)) ?? []
        let front = NSWorkspace.shared.frontmostApplication
        let pid = (apps.first { $0 == front } ?? apps.first)?.processIdentifier
        if pid == wanted, watched != nil { return look() }
        if let old = watched {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old.observer), .defaultMode)
            watched = nil
        }
        secure = false
        wanted = pid
        guard let pid, AXIsProcessTrusted() else { return }
        subscribe(pid, tries: 5)
    }

    /// The app may be busy answering the activation (LINE: kAXErrorCannotComplete): tried again.
    private static func subscribe(_ pid: pid_t, tries: Int) {
        queue.async {
            var observer: AXObserver?
            guard AXObserverCreate(pid, { _, _, _, _ in
                MainActor.assumeIsolated { AccessibleField.look() }
            }, &observer) == .success, let observer else { return }
            let added = AXObserverAddNotification(observer, AXUIElementCreateApplication(pid),
                                                  kAXFocusedUIElementChangedNotification as CFString, nil)
            let watch = Watch(pid: pid, observer: observer)
            DispatchQueue.main.async {
                guard wanted == pid, watched?.pid != pid else { return } // another app came meanwhile, or it's watched
                guard added == .success else {
                    if tries > 1 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { subscribe(pid, tries: tries - 1) }
                    } else {
                        log.info("accessibility: can't watch the app's focus (\(added.rawValue))")
                    }
                    return
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(watch.observer), .defaultMode)
                watched = watch
                look() // the field that has the focus now
            }
        }
    }

    /// Looks at the watched app's focused element, on `queue`. No answer (the app busy) keeps
    /// what was known and asks again.
    private static func look(tries: Int = 4) {
        guard let pid = watched?.pid else { return }
        queue.async {
            let answer = askSecure(pid)
            DispatchQueue.main.async {
                guard watched?.pid == pid else { return }
                guard let answer else {
                    if tries > 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { look(tries: tries - 1) } }
                    return
                }
                guard answer != secure else { return }
                secure = answer
                log.info("accessibility: focused field \(answer ? "secure" : "not secure", privacy: .public)")
            }
        }
    }

    /// Nil when the app didn't answer; false when nothing has the focus.
    nonisolated private static func askSecure(_ pid: pid_t) -> Bool? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        var focused: CFTypeRef?
        switch AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) {
        case .success: break
        case .noValue, .attributeUnsupported: return false
        default: return nil
        }
        guard let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, timeout)
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXRoleDescriptionAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let values = values as? [Any], values.count == 3 else { return nil }
        return MaskedField.isSecure(role: values[0] as? String, subrole: values[1] as? String,
                                    roleDescription: values[2] as? String, secureDescriptions: secureDescriptions)
    }
}
