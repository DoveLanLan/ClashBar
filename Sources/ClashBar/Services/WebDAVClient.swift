import Foundation

// MARK: - 配置

/// 坚果云 WebDAV 连接配置。
///
/// 注意：`password` 必须是**应用密码**（坚果云 → 账户信息 → 安全选项 → 添加应用），
/// 不是登录密码。
struct WebDAVConfig: Codable, Equatable, Sendable {
    /// WebDAV 服务器根地址，例如 `https://dav.jianguoyun.com/dav/`
    var endpoint: String
    /// 登录邮箱
    var username: String
    /// 应用密码
    var password: String
    /// 远端子目录名，例如 `ClashBar`
    var remoteDirectory: String
    /// 是否让同步请求走系统代理（默认 false：直连，避免与自身代理形成环路）
    var useSystemProxy: Bool

    static let nutstoreEndpoint = "https://dav.jianguoyun.com/dav/"
    static let defaultRemoteDirectory = "ClashBar"

    static let empty = WebDAVConfig(
        endpoint: WebDAVConfig.nutstoreEndpoint,
        username: "",
        password: "",
        remoteDirectory: WebDAVConfig.defaultRemoteDirectory,
        useSystemProxy: false)

    var isConfigured: Bool {
        !self.endpoint.trimmed.isEmpty
            && !self.username.trimmed.isEmpty
            && !self.password.isEmpty
            && !self.remoteDirectory.trimmed.isEmpty
    }

    /// 归一化后的根 URL（保证以 `/` 结尾）
    var normalizedRootURL: URL? {
        var text = self.endpoint.trimmed
        guard !text.isEmpty else { return nil }
        if !text.hasSuffix("/") {
            text += "/"
        }
        guard let base = URL(string: text), base.scheme != nil, base.host != nil else {
            return nil
        }
        let dir = self.remoteDirectory.trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !dir.isEmpty else { return base }
        return base.appendingPathComponent(dir, isDirectory: true)
    }
}

// MARK: - 错误

enum WebDAVError: LocalizedError, Equatable {
    case invalidConfiguration
    case unauthorized
    case notFound
    case parentMissing(String)
    case rateLimited
    case server(Int)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "WebDAV 配置不完整或地址无效"
        case .unauthorized:
            return "认证失败，请检查坚果云邮箱与应用密码"
        case .notFound:
            return "远端文件不存在"
        case let .parentMissing(path):
            return "父目录不存在：\(path)（请检查远端目录名是否含非法字符）"
        case .rateLimited:
            return "坚果云请求过于频繁或流量超限，请稍后再试"
        case let .server(code):
            return "服务器返回 HTTP \(code)"
        case let .transport(message):
            return "网络错误：\(message)"
        }
    }
}

// MARK: - 远端文件状态

struct WebDAVFileState: Equatable, Sendable {
    var exists: Bool
    var modifiedAt: Date?
    var contentLength: Int?
}

// MARK: - 客户端

/// 极简 WebDAV 客户端，只实现同步所需的方法。
///
/// 设计取舍：
/// - 用 `HEAD` 代替 `PROPFIND`：坚果云对 `PROPFIND` 限流更严
/// - 不实现 `LOCK`/`UNLOCK`：坚果云不支持，冲突由时间戳与 SHA256 判定
/// - 默认关闭系统代理：避免 ClashBar 自身的代理设置影响同步请求
final class WebDAVClient: Sendable {
    private let config: WebDAVConfig
    private let session: URLSession
    private let rootURL: URL

    init(config: WebDAVConfig) throws {
        guard config.isConfigured, let root = config.normalizedRootURL else {
            throw WebDAVError.invalidConfiguration
        }
        self.config = config
        self.rootURL = root

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 120
        sessionConfig.httpMaximumConnectionsPerHost = 2
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfig.httpCookieStorage = nil
        sessionConfig.urlCredentialStorage = nil

        // 关键：绕开系统代理。使用 ClashBar 自身代理时，同步请求若走代理会形成环路。
        if !config.useSystemProxy {
            sessionConfig.connectionProxyDictionary = [:]
        }

        self.session = URLSession(configuration: sessionConfig)
    }

    // MARK: 基础请求

    private func makeRequest(
        method: String,
        path: String,
        body: Data? = nil,
        extraHeaders: [String: String] = [:]) -> URLRequest
    {
        let url = path.isEmpty
            ? self.rootURL
            : self.rootURL.appendingPathComponent(path, isDirectory: false)

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.setValue(self.authHeader(), forHTTPHeaderField: "Authorization")
        request.setValue("ClashBar/\(Self.appVersion)", forHTTPHeaderField: "User-Agent")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func authHeader() -> String {
        let raw = "\(self.config.username.trimmed):\(self.config.password)"
        let encoded = Data(raw.utf8).base64EncodedString()
        return "Basic \(encoded)"
    }

    private func execute(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw WebDAVError.transport("响应格式异常")
            }
            return (data, http)
        } catch let error as WebDAVError {
            throw error
        } catch {
            throw WebDAVError.transport(error.localizedDescription)
        }
    }

    private func checkStatus(_ http: HTTPURLResponse, accepted: Set<Int>) throws {
        if accepted.contains(http.statusCode) { return }
        switch http.statusCode {
        case 401, 403:
            throw WebDAVError.unauthorized
        case 404:
            throw WebDAVError.notFound
        case 409:
            // MKCOL/PUT 时父目录不存在，或路径中间某一级是文件而非目录
            throw WebDAVError.parentMissing(http.url?.path ?? "")
        case 429, 503:
            throw WebDAVError.rateLimited
        default:
            throw WebDAVError.server(http.statusCode)
        }
    }

    // MARK: 公开操作

    /// 递归创建目录。已存在（405）视为成功。
    ///
    /// WebDAV 的 `MKCOL` 不会自动创建父目录，父目录缺失时会返回 `409 Conflict`。
    /// 因此需要逐级创建。
    func ensureDirectory(_ path: String = "") async throws {
        try await self.createDirectory("")

        let components = path
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !components.isEmpty else { return }

        var accumulated = ""
        for component in components {
            accumulated = accumulated.isEmpty ? component : "\(accumulated)/\(component)"
            try await self.createDirectory(accumulated)
        }
    }

    private func createDirectory(_ path: String) async throws {
        let request = self.makeRequest(method: "MKCOL", path: path)
        let (_, http) = try await self.execute(request)
        // 201 = 创建成功；405 = 已存在
        guard [201, 405].contains(http.statusCode) else {
            try self.checkStatus(http, accepted: [])
            return
        }
    }

    /// 上传文件。
    func upload(_ data: Data, to path: String) async throws {
        let request = self.makeRequest(
            method: "PUT",
            path: path,
            body: data,
            extraHeaders: ["Content-Type": "application/octet-stream"])
        let (_, http) = try await self.execute(request)
        try self.checkStatus(http, accepted: [200, 201, 204])
    }

    /// 下载文件。
    func download(_ path: String) async throws -> Data {
        let request = self.makeRequest(method: "GET", path: path)
        let (data, http) = try await self.execute(request)
        try self.checkStatus(http, accepted: [200])
        return data
    }

    /// 读取文件状态。用 `HEAD` 而非 `PROPFIND`，对坚果云更友好。
    func stat(_ path: String) async throws -> WebDAVFileState {
        var request = self.makeRequest(method: "HEAD", path: path)
        // 部分服务端对 HEAD 返回 405，回退到 GET 只取头部
        var (_, http) = try await self.execute(request)

        if http.statusCode == 405 {
            request.httpMethod = "GET"
            let (data, retryHTTP) = try await self.execute(request)
            http = retryHTTP
            if http.statusCode == 200 {
                return WebDAVFileState(
                    exists: true,
                    modifiedAt: Self.parseHTTPDate(http.value(forHTTPHeaderField: "Last-Modified")),
                    contentLength: data.count)
            }
        }

        if http.statusCode == 404 {
            return WebDAVFileState(exists: false, modifiedAt: nil, contentLength: nil)
        }
        try self.checkStatus(http, accepted: [200])
        return WebDAVFileState(
            exists: true,
            modifiedAt: Self.parseHTTPDate(http.value(forHTTPHeaderField: "Last-Modified")),
            contentLength: http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init))
    }

    /// 删除文件（不存在时静默成功）。
    func delete(_ path: String) async throws {
        let request = self.makeRequest(method: "DELETE", path: path)
        let (_, http) = try await self.execute(request)
        guard [200, 204, 404].contains(http.statusCode) else {
            try self.checkStatus(http, accepted: [])
            return
        }
    }

    // MARK: 辅助

    private static func parseHTTPDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        // HTTP-date 使用 RFC 7231 / RFC 1123 格式，例如：
        // "Wed, 21 Oct 2015 07:28:00 GMT"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: value)
    }

    private static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
}

// MARK: - 工具

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
