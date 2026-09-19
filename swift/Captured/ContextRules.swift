import Foundation

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Context rules — the pure answer to "what is in front?"
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Everything here is pure so the same rules can judge a live window and a
//  watcher line written months ago. A password manager's title and a private
//  browser window's address must never reach a line, an item or an
//  attachment; the redaction lives here, once, for every caller.

enum ContextRules {

    /// The one owner of the password-manager list. `InputCoalescer` keeps its
    /// keystrokes out of the log with the same set.
    static let privateBundleIDs: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7",
        "com.bitwarden.desktop", "com.apple.keychainaccess",
        "com.dashlane.Dashlane", "com.lastpass.LastPass",
        "org.keepassxc.keepassxc", "com.apple.SecurityAgent",
    ]

    /// Older watcher lines stored a display name and no bundle identifier, so
    /// the name alone has to be enough for those lines.
    static let privateAppNames: Set<String> = [
        "1Password", "Bitwarden", "Keychain Access", "Dashlane",
        "LastPass", "KeePassXC", "SecurityAgent",
    ]

    /// True when the bundle identifier is one of the private ones, when the
    /// application name contains one of the private names, when secure input
    /// is on, or when the front browser window is a private one.
    static func isPrivate(bundleID: String?, appName: String?,
                          secureInput: Bool, incognito: Bool) -> Bool {
        if let bundleID, privateBundleIDs.contains(bundleID) { return true }
        if let appName {
            let lower = appName.lowercased()
            if privateAppNames.contains(where: { lower.contains($0.lowercased()) }) {
                return true
            }
        }
        return secureInput || incognito
    }

    /// Host, port and path only: the query string, the fragment and any
    /// credentials are dropped, and a lone trailing slash goes. Anything that
    /// is not `http` or `https`, and anything that is not an address, gives
    /// nothing.
    static func cleanURL(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty,
              let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty else { return nil }
        var cleaned = host
        if let port = components.port { cleaned += ":\(port)" }
        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" { cleaned += path }
        return cleaned
    }

    /// At most 120 UTF-16 units, and never inside a character: what comes back
    /// is always the beginning of what went in.
    static func cutWindowTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        guard title.utf16.count > 120 else { return title }
        var cut = ""
        var units = 0
        for character in title {
            let width = character.utf16.count
            if units + width > 120 { break }
            cut.append(character)
            units += width
        }
        return cut
    }
}
