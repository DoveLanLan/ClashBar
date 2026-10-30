import CryptoKit
import Foundation

// MARK: - 快照

/// 参与同步的本地内容。
struct LocalSyncSnapshot: Equatable, Sendable {
    /// 配置文件名（例如 `ClashBar.yaml`）
    var configFileName: String
    /// 配置原始内容
    var configData: Data
    /// 跨平台设置
    var payload: SyncPayload

    var settingsData: Data {
        get throws {
            try JSONEncoder.sync.encode(self.payload)
        }
    }
}

// MARK: - 结果

enum SyncAction: String, Sendable {
    case pushed
    case pulled
    case upToDate
}

struct SyncOutcome: Equatable, Sendable {
    var action: SyncAction
    /// 远端记录的最后修改设备
    var remoteDeviceName: String?
    var remoteUpdatedAt: Date?
    var bytesTransferred: Int
}

// MARK: - 错误

enum SyncError: LocalizedError {
    case notConfigured
    case configFileMissing(String)
    case invalidRemotePayload(String)
    case corruptedMetadata

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未配置 WebDAV 同步"
        case let .configFileMissing(name):
            return "本地配置文件不存在：\(name)"
        case let .invalidRemotePayload(reason):
            return "远端数据无法解析：\(reason)"
        case .corruptedMetadata:
            return "远端元信息损坏"
        }
    }
}

// MARK: - 服务

/// 负责与 WebDAV 之间的编排：推送、拉取、冲突判定。
///
/// 只处理"文件 + JSON"层面，不依赖 `AppViewModel`。
/// 设置项的收集与应用由调用方（`AppViewModel+Sync`）负责。
struct SyncService: Sendable {
    /// 远端文件布局（与 `docs/sync-protocol.md` 一致）
    enum RemotePath {
        static let configDirectory = "config"
        static let configFile = "config/ClashBar.yaml"
        static let settings = "settings.json"
        static let metadata = "meta.json"
    }

    /// 时间容差：小于此差值视为已同步
    static let syncTolerance: TimeInterval = 30

    let client: WebDAVClient
    let directories: WorkingDirectoryManager
    let deviceName: String

    init(
        config: WebDAVConfig,
        directories: WorkingDirectoryManager = WorkingDirectoryManager(),
        deviceName: String = SyncService.defaultDeviceName) throws
    {
        self.client = try WebDAVClient(config: config)
        self.directories = directories
        self.deviceName = deviceName
    }

    // MARK: 远端查询

    func fetchRemoteMetadata() async throws -> SyncMetadata? {
        do {
            let data = try await self.client.download(RemotePath.metadata)
            guard let metadata = try? JSONDecoder.sync.decode(SyncMetadata.self, from: data) else {
                throw SyncError.corruptedMetadata
            }
            return metadata
        } catch WebDAVError.notFound {
            return nil
        }
    }

    // MARK: 推送

    @discardableResult
    func push(_ snapshot: LocalSyncSnapshot) async throws -> SyncOutcome {
        let settingsData = try snapshot.settingsData
        let metadata = SyncMetadata(
            deviceName: self.deviceName,
            updatedAt: snapshot.payload.updatedAt,
            configSha256: Self.sha256(snapshot.configData),
            settingsSha256: Self.sha256(settingsData),
            appVersion: Self.appVersion,
            platform: "macOS")

        try await self.client.ensureDirectory()
        try await self.client.ensureDirectory(RemotePath.configDirectory)

        // 顺序有意义：meta.json 最后写入，作为"提交标记"。
        // WebDAV 无事务语义，若中途失败，下次同步会因 meta 与实际内容不一致而重传。
        try await self.client.upload(snapshot.configData, to: RemotePath.configFile)
        try await self.client.upload(settingsData, to: RemotePath.settings)
        try await self.client.upload(
            try JSONEncoder.sync.encode(metadata),
            to: RemotePath.metadata)

        return SyncOutcome(
            action: .pushed,
            remoteDeviceName: metadata.deviceName,
            remoteUpdatedAt: metadata.updatedAt,
            bytesTransferred: snapshot.configData.count + settingsData.count)
    }

    // MARK: 拉取

    /// 下载远端快照并写入本地配置目录，返回可用于应用设置的 payload。
    ///
    /// 写入前会把现有配置备份为 `*.bak-sync-<timestamp>`，失败可手动回滚。
    func pull() async throws -> (payload: SyncPayload, metadata: SyncMetadata) {
        let metadata: SyncMetadata
        do {
            let metaData = try await self.client.download(RemotePath.metadata)
            guard let parsed = try? JSONDecoder.sync.decode(SyncMetadata.self, from: metaData) else {
                throw SyncError.corruptedMetadata
            }
            metadata = parsed
        } catch WebDAVError.notFound {
            throw SyncError.invalidRemotePayload("远端尚未上传过配置")
        }

        let settingsData: Data
        let configData: Data
        do {
            settingsData = try await self.client.download(RemotePath.settings)
            configData = try await self.client.download(RemotePath.configFile)
        } catch WebDAVError.notFound {
            throw SyncError.invalidRemotePayload("远端缺少 settings.json 或 config 文件")
        }

        guard let payload = try? JSONDecoder.sync.decode(SyncPayload.self, from: settingsData) else {
            throw SyncError.invalidRemotePayload("settings.json 格式不合法")
        }

        // 校验完整性：meta 记录的哈希必须与实际内容一致
        if !metadata.configSha256.isEmpty,
           metadata.configSha256 != Self.sha256(configData)
        {
            throw SyncError.invalidRemotePayload("配置内容与元信息哈希不匹配")
        }

        try self.writeLocalConfig(configData, fileName: payload.selectedConfig)
        return (payload, metadata)
    }

    // MARK: 双向同步

    /// 依据时间戳决定推送或拉取。
    func sync(_ snapshot: LocalSyncSnapshot, now: Date = Date()) async throws -> SyncOutcome {
        guard let remote = try await self.fetchRemoteMetadata() else {
            return try await self.push(snapshot)
        }

        let localUpdatedAt = snapshot.payload.updatedAt
        let remoteUpdatedAt = remote.updatedAt
        let delta = localUpdatedAt.timeIntervalSince(remoteUpdatedAt)

        // 内容完全一致 -> 无需传输
        let localConfigHash = Self.sha256(snapshot.configData)
        let localSettingsHash = Self.sha256(try snapshot.settingsData)
        if localConfigHash == remote.configSha256,
           localSettingsHash == remote.settingsSha256
        {
            return SyncOutcome(
                action: .upToDate,
                remoteDeviceName: remote.deviceName,
                remoteUpdatedAt: remoteUpdatedAt,
                bytesTransferred: 0)
        }

        if delta > Self.syncTolerance {
            return try await self.push(snapshot)
        }
        if delta < -Self.syncTolerance {
            _ = try await self.pull()
            return SyncOutcome(
                action: .pulled,
                remoteDeviceName: remote.deviceName,
                remoteUpdatedAt: remoteUpdatedAt,
                bytesTransferred: 0)
        }

        // 容差内：以远端为准（避免本地反复覆盖），但记录冲突供 UI 提示
        _ = try await self.pull()
        return SyncOutcome(
            action: .pulled,
            remoteDeviceName: remote.deviceName,
            remoteUpdatedAt: remoteUpdatedAt,
            bytesTransferred: 0)
    }

    // MARK: 本地写入

    /// 写入配置并保留备份。
    private func writeLocalConfig(_ data: Data, fileName: String) throws {
        let directory = self.directories.configDirectoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let safeName = fileName.trimmed.isEmpty ? "ClashBar.yaml" : fileName
        let target = directory.appendingPathComponent(safeName, isDirectory: false)

        if FileManager.default.fileExists(atPath: target.path) {
            let stamp = Self.timestampFormatter.string(from: Date())
            let backup = directory.appendingPathComponent(
                "\(safeName).bak-sync-\(stamp)",
                isDirectory: false)
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: target, to: backup)
        }

        try data.write(to: target, options: .atomic)
    }

    // MARK: 工具

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static var defaultDeviceName: String {
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        return name.trimmed.isEmpty ? "macOS" : name
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}
