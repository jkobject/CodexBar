import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CrossHostUsageSettingsTests {
    @Test
    func `host is opt in, persists across settings reload, and removal disables it`() throws {
        let defaults = InMemoryUserDefaults()
        let config = testConfigStore(suiteName: "CrossHostUsageSettings-\(UUID().uuidString)")
        let settings = Self.settings(defaults: defaults, config: config)
        #expect(settings.crossHostUsageHost.isEmpty)

        try settings.setCrossHostUsageHost("  rambo\n")
        #expect(settings.crossHostUsageHost == "rambo")
        #expect(settings.costUsageEnabled)
        let reloaded = Self.settings(defaults: defaults, config: config)
        #expect(reloaded.crossHostUsageHost == "rambo")

        try reloaded.setCrossHostUsageHost("")
        #expect(defaults.object(forKey: "crossHostUsageHost") == nil)
        #expect(Self.settings(defaults: defaults, config: config).crossHostUsageHost.isEmpty)
    }

    @Test(arguments: ["-oProxyCommand=bad", "rambo; touch /tmp/bad", "rambo other", "$(hostname)"])
    func `invalid additions cannot replace the saved host or schedule refreshes`(_ invalid: String) throws {
        let defaults = InMemoryUserDefaults()
        let config = testConfigStore(suiteName: "CrossHostUsageSettings-\(UUID().uuidString)")
        let settings = Self.settings(defaults: defaults, config: config)
        try settings.setCrossHostUsageHost("rambo")
        let costRevision = settings.costUsageSettingsRevision
        let backgroundRevision = settings.backgroundWorkSettingsRevision

        #expect(throws: (any Error).self) { try settings.setCrossHostUsageHost(invalid) }
        #expect(settings.crossHostUsageHost == "rambo")
        #expect(defaults.string(forKey: "crossHostUsageHost") == "rambo")
        #expect(settings.costUsageSettingsRevision == costRevision)
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision)
    }

    @Test
    func `invalid persisted host is ignored and identical saves do not restart work`() throws {
        let defaults = InMemoryUserDefaults(values: ["crossHostUsageHost": "-bad"])
        let config = testConfigStore(suiteName: "CrossHostUsageSettings-\(UUID().uuidString)")
        let settings = Self.settings(defaults: defaults, config: config)
        #expect(settings.crossHostUsageHost.isEmpty)
        settings.costUsageEnabled = true
        let costRevision = settings.costUsageSettingsRevision
        let backgroundRevision = settings.backgroundWorkSettingsRevision
        try settings.setCrossHostUsageHost("rambo")
        #expect(settings.costUsageSettingsRevision == costRevision + 1)
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision + 1)
        try settings.setCrossHostUsageHost(" rambo ")
        #expect(settings.costUsageSettingsRevision == costRevision + 1)
        #expect(settings.backgroundWorkSettingsRevision == backgroundRevision + 1)
    }

    private static func settings(defaults: UserDefaults, config: CodexBarConfigStore) -> SettingsStore {
        SettingsStore(
            userDefaults: defaults,
            configStore: config,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }
}
