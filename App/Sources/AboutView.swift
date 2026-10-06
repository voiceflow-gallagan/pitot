import AppKit
import SwiftUI

/// The About window: version, the non-affiliation line, the update switch and the licenses.
struct AboutView: View {
    let updates: UpdatesModel
    let info: AboutInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(info.name).font(.title.bold())
                    Text(info.versionLine).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            // The window has a fixed width, so wrapping these lines at full height is safe.
            Text(AboutInfo.privacyNote).fixedSize(horizontal: false, vertical: true)
            Text(AboutInfo.notAffiliated).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            UpdatesSection(updates: updates)
            Divider()
            LicensesSection()
            if let url = info.projectURL {
                Link("Project page", destination: url)
            }
        }
        .padding(20)
        .frame(width: 480, alignment: .leading)
    }
}

private struct UpdatesSection: View {
    let updates: UpdatesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Updates").font(.headline)
            Toggle("Automatically check for updates", isOn: Binding(get: { updates.automaticallyChecks }, set: updates.setAutomaticChecks))
                .disabled(!updates.isConfigured)
            HStack {
                Button(UpdatesModel.checkTitle) { updates.checkForUpdates() }
                    .disabled(!updates.isMenuEnabled)
                if let message = updates.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Pitot never checks without your permission. Turn on the switch to check once a day.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct LicensesSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Licenses").font(.headline)
            Text(AboutInfo.appLicense)
            ForEach(AboutInfo.thirdParty) { license in
                DisclosureGroup {
                    ScrollView {
                        Text(license.text() ?? "The license text is missing from the app bundle.")
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(license.name)
                        Text(license.summary).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// "About Pitot" and "Check for Updates…" in the app menu.
struct AppMenuItems: View {
    let updates: UpdatesModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Pitot") { openWindow(id: "about") }
        Button(updates.menuTitle) { updates.checkForUpdates() }
            .disabled(!updates.isMenuEnabled)
    }
}
