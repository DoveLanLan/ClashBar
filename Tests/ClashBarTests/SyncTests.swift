import Foundation
@testable import ClashBar

@MainActor
struct SyncTests {
    private static let yaml = Data("proxies: []\nproxy-groups: []\nrules: []\n".utf8)

    func snapshotIncludesLocalAndSubscriptionFiles() throws {
        let source = try SyncFixture()
        defer { source.cleanup() }
        let localNames = ["ClashBar.yaml", "ccs-bytevirt-199.fixed.yaml"]
        let remoteNames = ["234.yaml", "company.yaml", "ikuuu.yaml", "mojie.yaml", "宝可梦星云.yaml"]
        for name in localNames + remoteNames {
            try source.write(name, data: Self.yaml)
        }
        for name in ["proxy/provider.yaml", "rule/rules.yaml", "cache.db", "ASN.mmdb", "ClashBar.yaml.bak-sync-1"] {
            try source.write(name, data: Data("cache".utf8))
        }
        source.model.remoteConfigSubscriptions = Self.subscriptions(for: remoteNames)
        source.model.selectedConfigName = "mojie.yaml"

        let snapshot = try source.model.makeSyncSnapshot()

        try expect(snapshot.configs.map(\.name) == (localNames + remoteNames).sorted())
        try expect(snapshot.configEntries.count == 7)
        try expect(snapshot.payload.subscriptions.map(\.name) == remoteNames.sorted())
        try expect(snapshot.payload.selectedConfig == "mojie.yaml")
        try expect(snapshot.configs.allSatisfy { $0.data == Self.yaml })
    }

    func bundleRestoresCompleteConfigState() async throws {
        let source = try SyncFixture()
        defer { source.cleanup() }
        let destination = try SyncFixture()
        defer { destination.cleanup() }
        let localNames = ["ClashBar.yaml", "local.yml"]
        let remoteNames = ["mojie.yaml", "宝可梦星云.yaml"]
        for name in localNames + remoteNames {
            try source.write(name, data: Data("# \(name)\n".utf8) + Self.yaml)
        }
        source.model.remoteConfigSubscriptions = Self.subscriptions(for: remoteNames)
        source.model.selectedConfigName = "mojie.yaml"
        let snapshot = try source.model.makeSyncSnapshot()
        let bundle = try await SyncArchive.makeBundle(settingsData: snapshot.settingsData, configs: snapshot.configs)
        let contents = try await SyncArchive.extractBundle(bundle, expected: snapshot.configEntries)
        let payload = try JSONDecoder.sync.decode(SyncPayload.self, from: contents.settings)

        try destination.write("ClashBar.yaml", data: Data("old config".utf8))
        try destination.write("destination-only.yaml", data: Self.yaml)
        let service = try destination.syncService()
        // 订阅地址指向 .invalid；成功恢复说明完整包不依赖重新请求订阅。
        try await service.restoreLocalConfigs(contents.configs, payload: payload)
        await destination.model.applySyncPayload(payload)

        try expect(destination.model.availableConfigFileNames == (localNames + remoteNames + ["destination-only.yaml"]).sorted())
        try expect(destination.model.remoteConfigSubscriptions == source.model.remoteConfigSubscriptions)
        try expect(destination.model.selectedConfigName == "mojie.yaml")
        try expect(destination.model.configService.selectedConfig?.lastPathComponent == "mojie.yaml")
        try expect(destination.model.defaults.string(forKey: destination.model.selectedConfigKey) == "mojie.yaml")
        try expect(destination.model.loadPersistedRemoteConfigSubscriptions() == source.model.remoteConfigSubscriptions)
        try expect(destination.model.remoteConfigAutoUpdateTask != nil)
        for config in snapshot.configs {
            try expect(try Data(contentsOf: destination.directory.appendingPathComponent(config.name)) == config.data)
        }
        let backups = try FileManager.default.contentsOfDirectory(atPath: destination.directory.path)
            .filter { $0.hasPrefix("ClashBar.yaml.bak-sync-") }
        try expect(backups.count == 1)
        try expect(try Data(contentsOf: destination.directory.appendingPathComponent(backups[0])) == Data("old config".utf8))
    }

    func subscriptionOnlySnapshotHasConfigFiles() async throws {
        let source = try SyncFixture()
        defer { source.cleanup() }
        try source.write("remote.yaml", data: Self.yaml)
        source.model.remoteConfigSubscriptions = Self.subscriptions(for: ["remote.yaml"])
        source.model.selectedConfigName = "remote.yaml"

        let snapshot = try source.model.makeSyncSnapshot()
        let bundle = try await SyncArchive.makeBundle(settingsData: snapshot.settingsData, configs: snapshot.configs)
        let contents = try await SyncArchive.extractBundle(bundle, expected: snapshot.configEntries)

        try expect(contents.configs == [LocalConfigFile(name: "remote.yaml", data: Self.yaml)])
    }

    func oldBundleDownloadsOnlyMissingSubscriptions() async throws {
        let destination = try SyncFixture()
        defer { destination.cleanup() }
        try destination.write("existing.yaml", data: Self.yaml)
        let configs = [LocalConfigFile(name: "bundled.yaml", data: Self.yaml)]
        let subscriptions = ["bundled.yaml", "existing.yaml", "missing.yaml"].map {
            SubscriptionSection(name: $0, url: "https://example.invalid/\($0)", autoUpdate: false, intervalHours: 6)
        }
        let downloads = DownloadRecorder(data: Self.yaml)

        let completed = try await SyncService.completingSubscriptionConfigs(
            configs,
            subscriptions: subscriptions,
            existingDirectory: destination.directory,
            download: { try await downloads.download($0) })

        try expect(completed.map(\.name) == ["bundled.yaml", "missing.yaml"])
        let downloadedURLs = await downloads.urls
        try expect(downloadedURLs.map(\.lastPathComponent) == ["missing.yaml"])
    }

    func missingSubscriptionDownloadFailureIsReported() async throws {
        let destination = try SyncFixture()
        defer { destination.cleanup() }
        let subscriptions = [SubscriptionSection(
            name: "missing.yaml", url: "https://example.invalid/sub", autoUpdate: false, intervalHours: 6)]

        try await expectThrows(DownloadFailure.self) {
            _ = try await SyncService.completingSubscriptionConfigs(
                [], subscriptions: subscriptions, existingDirectory: destination.directory,
                download: { _ in throw DownloadFailure() })
        }
        try expect(!FileManager.default.fileExists(atPath: destination.directory.appendingPathComponent("missing.yaml").path))
    }

    func missingSubscriptionValidation() async throws {
        let destination = try SyncFixture()
        defer { destination.cleanup() }
        let invalidContents = DownloadRecorder(data: Data("<html>login</html>".utf8))
        let subscription = SubscriptionSection(
            name: "missing.yaml", url: "https://example.invalid/sub", autoUpdate: false, intervalHours: 6)
        try await expectThrows(SyncError.self) {
            _ = try await SyncService.completingSubscriptionConfigs(
                [], subscriptions: [subscription], existingDirectory: destination.directory,
                download: { try await invalidContents.download($0) })
        }

        let downloads = DownloadRecorder(data: Self.yaml)
        var unsafe = subscription
        unsafe.name = "../outside.yaml"
        try await expectThrows(SyncError.self) {
            _ = try await SyncService.completingSubscriptionConfigs(
                [], subscriptions: [unsafe], existingDirectory: destination.directory,
                download: { try await downloads.download($0) })
        }
        let downloadedURLs = await downloads.urls
        try expect(downloadedURLs.isEmpty)
    }

    private static func subscriptions(for names: [String]) -> [String: RemoteConfigSubscription] {
        Dictionary(uniqueKeysWithValues: names.map { name in
            (name, RemoteConfigSubscription(
                urlString: "https://example.invalid/sub/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)",
                autoUpdateEnabled: name != "宝可梦星云.yaml",
                autoUpdateIntervalHours: 12,
                lastUpdateCheckAt: Date(timeIntervalSince1970: 1_790_000_000)))
        })
    }
}

private struct DownloadFailure: Error {}

private actor DownloadRecorder {
    let data: Data
    private(set) var urls: [URL] = []

    init(data: Data) {
        self.data = data
    }

    func download(_ url: URL) throws -> Data {
        self.urls.append(url)
        return self.data
    }
}

@MainActor
private final class SyncFixture {
    let home: URL
    let defaultsName: String
    let model: AppViewModel

    var directory: URL {
        self.model.workingDirectoryManager.configDirectoryURL
    }

    init() throws {
        self.home = FileManager.default.temporaryDirectory.appendingPathComponent("ClashBarSyncTests-\(UUID().uuidString)")
        self.defaultsName = "ClashBarSyncTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: self.defaultsName) else {
            throw TestFailure(message: "Cannot create isolated defaults")
        }
        let directories = WorkingDirectoryManager(homeDirectory: self.home)
        try directories.bootstrapDirectories()
        let configManager = ConfigDirectoryManager(workingDirectoryManager: directories)
        configManager.setConfigDirectory(directories.configDirectoryURL)
        let session = URLSession(configuration: .ephemeral)
        let dependencies = AppDependencies(
            processManager: MihomoProcessManager(workingDirectoryManager: directories),
            configService: ConfigService(configManager: configManager, configImportService: ConfigImportService()),
            systemProxyService: SystemProxyService(),
            tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(),
            workingDirectoryManager: directories,
            networkReachabilityMonitor: NetworkReachabilityMonitor(),
            ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(session: session),
            proxyGroupIconCache: ProxyGroupIconCache(iconDirectory: directories.iconDirectoryURL, session: session),
            clashbarLogStore: AppLogStore(logFileURL: directories.logsDirectoryURL.appendingPathComponent("clashbar.log")),
            mihomoLogStore: AppLogStore(logFileURL: directories.logsDirectoryURL.appendingPathComponent("mihomo.log")))
        self.model = AppViewModel(dependencies: dependencies, defaults: defaults)
    }

    func write(_ name: String, data: Data) throws {
        let target = self.directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target)
    }

    func syncService() throws -> SyncService {
        try SyncService(
            config: WebDAVConfig(
                endpoint: "http://127.0.0.1:9/", username: "test", password: "test",
                remoteDirectory: "ClashBar", useSystemProxy: false),
            directories: self.model.workingDirectoryManager,
            deviceName: "test-destination")
    }

    func cleanup() {
        self.model.cancelOwnedTasks()
        self.model.defaults.removePersistentDomain(forName: self.defaultsName)
        try? FileManager.default.removeItem(at: self.home)
    }
}

private struct TestFailure: Error {
    let message: String
}

private func expect(
    _ condition: @autoclosure () throws -> Bool,
    file: StaticString = #filePath,
    line: UInt = #line) throws
{
    guard try condition() else {
        throw TestFailure(message: "Assertion failed at \(file):\(line)")
    }
}

@MainActor
private func expectThrows<T: Error>(_ type: T.Type, operation: () async throws -> Void) async throws {
    do {
        try await operation()
    } catch is T {
        return
    }
    throw TestFailure(message: "Expected \(type)")
}

// Command Line Tools 不附带 XCTest / Testing，使用原生 Swift 入口运行实际服务的回归测试。
@main
struct SyncTestRunner {
    @MainActor
    static func main() async throws {
        let tests = SyncTests()
        let cases: [(String, @MainActor () async throws -> Void)] = [
            ("all local and subscription YAML in snapshot", { try tests.snapshotIncludesLocalAndSubscriptionFiles() }),
            ("ZIP restores files, subscriptions and selection", { try await tests.bundleRestoresCompleteConfigState() }),
            ("subscription-only snapshot includes YAML", { try await tests.subscriptionOnlySnapshotHasConfigFiles() }),
            ("old bundle downloads only missing subscriptions", { try await tests.oldBundleDownloadsOnlyMissingSubscriptions() }),
            ("missing subscription download errors propagate", { try await tests.missingSubscriptionDownloadFailureIsReported() }),
            ("invalid content and unsafe names rejected", { try await tests.missingSubscriptionValidation() }),
        ]
        var failures = 0
        for (name, test) in cases {
            do {
                try await test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        guard failures == 0 else {
            throw TestFailure(message: "\(failures) regression tests failed")
        }
        print("All \(cases.count) sync regression tests passed.")
    }
}
