import Foundation
import Testing

@testable import Pitot

@MainActor
final class FakeUpdater: UpdateChecking {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var onEvent: ((UpdateEvent) -> Void)?
    private(set) var checks = 0

    func checkForUpdates() {
        checks += 1
    }
}

@MainActor
struct UpdatesTests {
    static let key = "not-a-real-key-only-for-tests="

    private func model(key: String?, environment: [String: String] = [:], made: FakeUpdater = FakeUpdater()) -> (UpdatesModel, () -> Int) {
        var created = 0
        let model = UpdatesModel(publicKey: key, environment: environment) {
            created += 1
            return made
        }
        return (model, { created })
    }

    @Test func emptyKeyNeverCreatesAnUpdater() {
        for key in [nil, "", "   "] as [String?] {
            let (model, created) = model(key: key)
            model.start()
            #expect(created() == 0)
            #expect(!model.hasUpdater)
            #expect(!model.isMenuEnabled)
            #expect(model.menuTitle == "Updates are not set up yet")
            #expect(model.statusMessage == "Updates are not set up yet")
            model.checkForUpdates()
            model.setAutomaticChecks(true)
            #expect(!model.automaticallyChecks)
        }
    }

    @Test func testsAndCustomPathsNeverStartAnUpdater() {
        for environment in [["XCTestConfigurationFilePath": "/x"], ["PITOT_SETTINGS_PATH": "/tmp/settings.json"]] {
            let (model, created) = model(key: Self.key, environment: environment)
            model.start()
            #expect(created() == 0)
            #expect(!model.isConfigured)
        }
    }

    @Test func theAppBundleHoldsAValidPublicKeyButNothingStartsUnderTests() {
        let key = Bundle(for: SettingsModel.self).object(forInfoDictionaryKey: "SUPublicEDKey") as? String
        #expect(Data(base64Encoded: key ?? "")?.count == 32)
        let (model, created) = model(key: key, environment: ProcessInfo.processInfo.environment)
        model.start()
        #expect(created() == 0)
    }

    @Test func configuredUpdaterDrivesTheMenu() {
        let fake = FakeUpdater()
        let (model, created) = model(key: Self.key, made: fake)
        model.start()
        model.start()
        #expect(created() == 1)
        #expect(model.menuTitle == "Check for Updates…")
        #expect(model.isMenuEnabled)

        model.checkForUpdates()
        #expect(fake.checks == 1)

        fake.canCheckForUpdates = false
        fake.onEvent?(.stateChanged)
        #expect(!model.isMenuEnabled)
        model.checkForUpdates()
        #expect(fake.checks == 1)
    }

    @Test func switchWritesThroughToTheUpdater() {
        let fake = FakeUpdater()
        let (model, _) = model(key: Self.key, made: fake)
        model.start()
        #expect(!model.automaticallyChecks)
        model.setAutomaticChecks(true)
        #expect(fake.automaticallyChecksForUpdates)
        #expect(model.automaticallyChecks)
        model.setAutomaticChecks(false)
        #expect(!fake.automaticallyChecksForUpdates)
    }

    @Test func failedCheckShowsAQuietMessage() {
        let fake = FakeUpdater()
        let (model, _) = model(key: Self.key, made: fake)
        model.start()
        #expect(model.statusMessage == nil)
        fake.onEvent?(.checkFailed)
        #expect(model.statusMessage == "Could not check for updates")
        model.checkForUpdates()
        #expect(model.statusMessage == nil)
    }

    @Test func infoPlistTurnsOffEverythingAutomatic() {
        let info = Bundle(for: SettingsModel.self).infoDictionary ?? [:]
        #expect(info["SUFeedURL"] as? String == "https://voiceflow-gallagan.github.io/pitot/appcast.xml")
        #expect(info["SUEnableAutomaticChecks"] as? Bool == false)
        #expect(info["SUAutomaticallyUpdate"] as? Bool == false)
        #expect(info["SUEnableSystemProfiling"] as? Bool == false)
        #expect(info["SUVerifyUpdateBeforeExtraction"] as? Bool == true)
        #expect(info["SURequireSignedFeed"] as? Bool == true)
        #expect(info["SUSignedFeedFailureExpirationInterval"] as? Int == 0)
        #expect(info["CFBundleVersion"] as? String == "1")
        #expect(info["CFBundleShortVersionString"] as? String == "0.1.0")
    }

    // MARK: About

    @Test func aboutStrings() {
        let info = AboutInfo(infoDictionary: ["CFBundleDisplayName": "Pitot", "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1"])
        #expect(info.name == "Pitot")
        #expect(info.versionLine == "Version 0.1.0 (1)")
        #expect(AboutInfo.notAffiliated == "Not affiliated with or endorsed by Anthropic. Claude and Claude Code are trademarks of Anthropic.")
        #expect(AboutInfo.privacyNote == "Pitot edits Claude Code settings files. It never reads or stores your API keys.")
        #expect(AboutInfo.appLicense == "License: MIT")
        #expect(info.projectURL?.absoluteString == "https://github.com/voiceflow-gallagan/pitot")
        #expect(AboutInfo(infoDictionary: [:]).versionLine == "Version unknown (unknown)")
    }

    @Test func sparkleLicenseIsBundled() throws {
        let sparkle = try #require(AboutInfo.thirdParty.first { $0.name.hasPrefix("Sparkle") })
        let text = try #require(sparkle.text(in: Bundle(for: SettingsModel.self)))
        #expect(text.contains("Andy Matuschak"))
        #expect(text.contains("Permission is hereby granted, free of charge"))
    }
}
