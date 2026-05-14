import Foundation

struct ReleaseInfo {
    let version: String
    let htmlURL: URL
}

actor UpdateChecker {
    private let apiURL = URL(string: "https://api.github.com/repos/bcanozgur/quota-warmer/releases/latest")!

    func checkForUpdate() async -> ReleaseInfo? {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return nil }

        var req = URLRequest(url: apiURL)
        req.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10

        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tagName = json["tag_name"] as? String,
              let htmlURLStr = json["html_url"] as? String,
              let htmlURL = URL(string: htmlURLStr)
        else { return nil }

        let remote = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
        guard remote.compare(current, options: .numeric) == .orderedDescending else { return nil }
        return ReleaseInfo(version: remote, htmlURL: htmlURL)
    }
}
