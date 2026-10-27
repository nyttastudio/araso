import ArasoCore
import Foundation

/// The user's language for UI text on Windows and Linux, from the same `ko.lproj/Localizable.strings`
/// the Mac app has (plus `Windows.strings` or `Linux.strings` for what only that platform says).
/// English is the key itself.
public enum Strings {
    /// The table in use: empty for English.
    nonisolated(unsafe) private static var table: [String: String] = [:]

    /// Loads Korean when `language` starts with "ko" (the host passes Windows' UI language, the
    /// addon Linux's `LANG`).
    public static func load(language: String, platform: String = "Windows", from directories: [URL]) {
        guard language.lowercased().hasPrefix("ko") else { table = [:]; return }
        var merged: [String: String] = [:]
        for directory in directories {
            for name in ["Localizable.strings", platform + ".strings"] {
                let url = directory.appendingPathComponent("ko.lproj").appendingPathComponent(name)
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                merged.merge(parse(text)) { _, new in new }
            }
        }
        table = merged
    }

    public static func localized(_ key: String) -> String { table[key] ?? key }

    /// `%@`, `%ld` and `%d` filled in order with `arguments`.
    public static func format(_ key: String, _ arguments: [String]) -> String {
        fill(localized(key), arguments)
    }

    static func fill(_ format: String, _ arguments: [String]) -> String {
        var out = ""
        var rest = Substring(format)
        var next = arguments.makeIterator()
        while let percent = rest.firstIndex(of: "%") {
            out += rest[..<percent]
            let after = rest[rest.index(after: percent)...]
            if let spec = ["@", "ld", "d", "lu"].first(where: { after.hasPrefix($0) }) {
                out += next.next() ?? ""
                rest = after.dropFirst(spec.count)
            } else if after.hasPrefix("%") {
                out += "%"
                rest = after.dropFirst()
            } else {
                out += "%"
                rest = after
            }
        }
        return out + rest
    }

    /// `"key" = "value";` lines, with `/* */` and `//` comments and `\"`, `\n`, `\\` escapes.
    static func parse(_ text: String) -> [String: String] {
        var table: [String: String] = [:]
        var chars = Array(text)
        var i = 0
        func skipSpace() {
            while i < chars.count {
                if chars[i].isWhitespace { i += 1; continue }
                if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "*" {
                    i += 2
                    while i + 1 < chars.count, !(chars[i] == "*" && chars[i + 1] == "/") { i += 1 }
                    i += 2
                    continue
                }
                if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" {
                    while i < chars.count, chars[i] != "\n" { i += 1 }
                    continue
                }
                break
            }
        }
        func quoted() -> String? {
            guard i < chars.count, chars[i] == "\"" else { return nil }
            i += 1
            var s = ""
            while i < chars.count, chars[i] != "\"" {
                if chars[i] == "\\", i + 1 < chars.count {
                    i += 1
                    switch chars[i] {
                    case "n": s.append("\n")
                    case "t": s.append("\t")
                    default: s.append(chars[i])
                    }
                } else {
                    s.append(chars[i])
                }
                i += 1
            }
            i += 1
            return s
        }
        while i < chars.count {
            skipSpace()
            guard let key = quoted() else { break }
            skipSpace()
            guard i < chars.count, chars[i] == "=" else { break }
            i += 1
            skipSpace()
            guard let value = quoted() else { break }
            skipSpace()
            if i < chars.count, chars[i] == ";" { i += 1 }
            table[key] = value
        }
        chars.removeAll()
        return table
    }
}

/// The user's language for `key` (as the Mac app's `L`).
func L(_ key: String) -> String { Strings.localized(key) }

/// `L` with `%@`/`%ld` arguments filled in.
func L(_ key: String, _ arguments: String...) -> String { Strings.format(key, arguments) }
