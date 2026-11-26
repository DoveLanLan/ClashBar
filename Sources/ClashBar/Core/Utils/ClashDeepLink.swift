import Foundation

/// A subscription installation link emitted by subscription websites.
/// Supports `clash://install-config?url=...` and `clashbar://install-config?url=...`.
struct ClashDeepLink: Equatable, Sendable {
    let remoteURL: URL
    let suggestedFileName: String?

    static func parse(_ url: URL) -> ClashDeepLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "clash" || scheme == "clashbar" else {
            return nil
        }
        let action = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        guard action == "install-config" || action == "install" else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            if let value = item.value { query[item.name.lowercased()] = value }
        }
        let rawRemoteURL = query["url"] ?? query["config"] ?? query["subscription"]
        guard let rawRemoteURL,
              let remoteURL = URL(string: rawRemoteURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let remoteScheme = remoteURL.scheme?.lowercased(),
              remoteScheme == "http" || remoteScheme == "https",
              remoteURL.host != nil
        else { return nil }
        let suggested = (query["name"] ?? query["filename"] ?? query["file"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ClashDeepLink(
            remoteURL: remoteURL,
            suggestedFileName: suggested?.isEmpty == false ? suggested : nil)
    }
}
