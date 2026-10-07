import Foundation

/// A bundled third-party license, shown in full in the About window.
struct ThirdPartyLicense: Identifiable, Equatable, Sendable {
    let name: String
    let summary: String
    /// The text file in the app bundle, without the `.txt` extension.
    let resource: String

    var id: String { name }

    func text(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resource, withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

/// The text of the About window.
struct AboutInfo: Equatable, Sendable {
    static let notAffiliated = "Not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic."
    static let privacyNote = "Pitot edits Claude Code settings files. It never reads or stores your API keys."
    static let appLicense = "License: MIT"
    static let projectPage = ProjectLinks.repository
    static let thirdParty = [
        ThirdPartyLicense(
            name: "Sparkle 2.10.0", summary: "MIT License, with BSD and MIT-style notices for parts it includes.",
            resource: "Sparkle-LICENSE")
    ]

    let name: String
    let version: String
    let build: String

    init(infoDictionary: [String: Any]) {
        name = infoDictionary["CFBundleDisplayName"] as? String ?? infoDictionary["CFBundleName"] as? String ?? "Pitot"
        version = infoDictionary["CFBundleShortVersionString"] as? String ?? "unknown"
        build = infoDictionary["CFBundleVersion"] as? String ?? "unknown"
    }

    var versionLine: String { "Version \(version) (\(build))" }

    var projectURL: URL? {
        Self.projectPage.isEmpty ? nil : URL(string: Self.projectPage)
    }
}
