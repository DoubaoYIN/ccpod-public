import Foundation
import CryptoKit
import SQLite3

struct ProviderImportCandidate: Identifiable {
    let id: String
    let providerID: String
    let displayName: String
    let sourceLabel: String
    let endpoint: String
    let model: String
    let json: [String: Any]
    let originalURL: URL?
    let originalData: Data?
    var gatewayStatus: String = ""
    var unavailableReason: String?
}

/// 导入扫描只读源配置；只有用户选中的条目才允许写 provider 文件。
enum ProviderImportService {
    private static let writeLock = NSLock()
    static let providersDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/providers", isDirectory: true)

    struct ScanResult {
        var candidates: [ProviderImportCandidate]
        var notices: [String]
    }

    static func scan() -> ScanResult {
        var candidates: [ProviderImportCandidate] = []
        var notices: [String] = []
        let fm = FileManager.default
        let visible = Set(ProviderService().availableProviders())
        if let files = try? fm.contentsOfDirectory(at: providersDir, includingPropertiesForKeys: nil) {
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "json", !name.contains(".example"),
                      isValidProviderID(name), !visible.contains(name) else { continue }
                guard let data = try? Data(contentsOf: file),
                      let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      json["env"] is [String: Any] else {
                    notices.append("旧线路 \(gatewayVisibleText(name)) 无法读取，已跳过")
                    continue
                }
                if ["gateway", "gateway-alias"].contains(json["source"] as? String ?? "") { continue }
                if ["ccr", "ccr-bailian", "ccr-dear"].contains(name), isLocalGatewayConfiguration(json) { continue }
                candidates.append(candidate(id: "legacy:\(name)", providerID: name,
                    name: providerDisplayName(name), source: "旧 CCPod 配置", json: json,
                    originalURL: file, originalData: data))
            }
        }

        let home = fm.homeDirectoryForCurrentUser
        let databases: [(URL, String)] = [
            (home.appendingPathComponent(".cc-switch/cc-switch.db"), "CC Switch"),
            (home.appendingPathComponent("projects/model-gateway/.local/backups/cc-switch-final-sample/cc-switch.db"),
             "CC Switch 备份 · 2026-09-25")
        ]
        var seen = Set<String>()
        for (url, label) in databases where fm.fileExists(atPath: url.path) {
            do {
                for item in try readCCSwitch(url: url, label: label) where seen.insert(item.id).inserted {
                    candidates.append(item)
                }
            } catch {
                notices.append("\(label) 无法读取：\(gatewayVisibleText(error.localizedDescription))")
            }
        }

        // 重复判断只在内存比对真实凭据和端点；网络失败不能表示“网关没有”。
        let gatewayProviders: [[String: Any]]?
        if let state = CCRConfigService.serviceState(),
           let config = try? CCRConfigService.fetchConfig(state: state),
           let providers = config["Providers"] as? [[String: Any]] {
            gatewayProviders = providers
        } else {
            gatewayProviders = nil
            if !candidates.isEmpty { notices.append("网关暂不可读，重复状态未核验；仍可选择导入") }
        }
        for index in candidates.indices {
            let env = candidates[index].json["env"] as? [String: Any] ?? [:]
            guard let gatewayProviders else {
                candidates[index].gatewayStatus = "网关状态未核验"
                continue
            }
            let base = normalizedEndpoint(SecretResolver.value(from: env["ANTHROPIC_BASE_URL"]) ?? "")
            let key = SecretResolver.value(from: env["ANTHROPIC_AUTH_TOKEN"])
                ?? SecretResolver.value(from: env["ANTHROPIC_API_KEY"])
                ?? SecretResolver.value(from: env["ANTHROPIC_API_TOKEN"])
            guard !base.isEmpty, let key, !key.isEmpty else {
                candidates[index].gatewayStatus = "凭据不可比对"
                continue
            }
            let exists = gatewayProviders.contains {
                normalizedEndpoint($0["api_base_url"] as? String ?? "") == base
                    && SecretResolver.value(from: $0["api_key"]) == key
            }
            candidates[index].gatewayStatus = exists ? "网关已有" : "未发现相同服务与凭据"
        }
        return ScanResult(candidates: candidates, notices: notices)
    }

    static func importSelected(_ candidates: [ProviderImportCandidate], directory: URL = providersDir) -> (imported: [String], errors: [String]) {
        var imported: [String] = []
        var errors: [String] = []
        for item in candidates {
            do {
                if let reason = item.unavailableReason { throw failure(reason) }
                let destination = directory.appendingPathComponent(item.providerID).appendingPathExtension("json")
                if let original = item.originalURL, let originalData = item.originalData {
                    guard original == destination, try Data(contentsOf: original) == originalData else {
                        throw failure("源配置已变化，请刷新后重新选择")
                    }
                } else if FileManager.default.fileExists(atPath: destination.path) {
                    throw failure("目标线路已存在，未覆盖")
                }
                var json = item.json
                json["source"] = "imported"
                json["import_origin"] = item.id
                if json["display_name"] == nil { json["display_name"] = item.displayName }
                try write(json, line: item.providerID, allowOverwrite: item.originalURL != nil,
                          expectedData: item.originalData, directory: directory)
                imported.append(item.providerID)
            } catch {
                errors.append("\(item.displayName)：\(gatewayVisibleText(error.localizedDescription))")
            }
        }
        return (imported, errors)
    }

    /// 新增、编辑、导入共用：密钥先入钥匙串并回读成功，再落盘引用。
    static func write(_ json: [String: Any], line name: String, allowOverwrite: Bool = true,
                      expectedData: Data? = nil, directory: URL = providersDir) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard isValidProviderID(name) else { throw failure("线路名称不合法") }
        let destination = directory.appendingPathComponent(name).appendingPathExtension("json")
        if let expectedData {
            guard try Data(contentsOf: destination) == expectedData else {
                throw failure("源配置已变化，请刷新后重新选择")
            }
        } else if !allowOverwrite, FileManager.default.fileExists(atPath: destination.path) {
            throw failure("目标线路已存在，未覆盖")
        }
        let safeJSON = try externalizeSecrets(json, line: name)
        let data = try JSONSerialization.data(withJSONObject: safeJSON, options: [.prettyPrinted, .sortedKeys])
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try data.write(to: destination, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        SecretResolver.invalidateCache()
    }

    static func externalizeSecrets(_ json: [String: Any], line name: String) throws -> [String: Any] {
        guard isValidProviderID(name) else { throw failure("线路名称不合法") }
        var credentials: [String: String] = [:]
        let env = json["env"] as? [String: Any] ?? [:]
        let primaryField = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_API_TOKEN"].first {
            if let value = env[$0] as? String { return !value.isEmpty }
            return (env[$0] as? [String: Any])?["$exec"] != nil
        }
        // 已有引用占用的服务名不能被另一字段的新值覆盖。
        let existingCommands = env.values.compactMap { ($0 as? [String: Any])?["$exec"] as? String }
        func transform(_ value: Any, path: String = "") throws -> Any {
            if let object = value as? [String: Any] {
                if object["$exec"] != nil { return object }
                var result: [String: Any] = [:]
                for (field, child) in object {
                    let childPath = path.isEmpty ? field : "\(path).\(field)"
                    if let secret = child as? String, !secret.isEmpty,
                       field.range(of: "api[_-]?(key|token)|auth[_-]?token|access[_-]?token|secret|password",
                                   options: [.regularExpression, .caseInsensitive]) != nil {
                        let suffix: String
                        switch childPath {
                        case "env.ANTHROPIC_API_KEY", "env.ANTHROPIC_AUTH_TOKEN", "env.ANTHROPIC_API_TOKEN":
                            let baseCommand = SecretResolver.keychainCommand(service: "ccpod-line-\(name)")
                            suffix = field == primaryField && !existingCommands.contains(baseCommand)
                                ? "" : "-" + field.lowercased().replacingOccurrences(of: "anthropic_", with: "").replacingOccurrences(of: "_", with: "-")
                        case "env.MANAGEMENT_API_KEY": suffix = "-mgmt"
                        default: suffix = "-" + digest(childPath)
                        }
                        var service = "ccpod-line-\(name)\(suffix)"
                        var disambiguator = 0
                        while existingCommands.contains(SecretResolver.keychainCommand(service: service)) {
                            disambiguator += 1
                            service = "ccpod-line-\(name)\(suffix)-\(digest(childPath))-\(disambiguator)"
                        }
                        if let previous = credentials[service], previous != secret {
                            throw failure("API Key 与 Auth Token 不一致，请先明确线路使用的凭据")
                        }
                        credentials[service] = secret
                        result[field] = ["$exec": SecretResolver.keychainCommand(service: service)]
                    } else {
                        result[field] = try transform(child, path: childPath)
                    }
                }
                return result
            }
            if let array = value as? [Any] {
                return try array.enumerated().map { try transform($0.element, path: "\(path).\($0.offset)") }
            }
            return value
        }
        let result = try transform(json) as! [String: Any]
        for (service, secret) in credentials {
            try SecretResolver.storeKeychain(service: service, secret: secret)
            guard SecretResolver.readKeychain(service: service) == secret else {
                throw failure("钥匙串回读校验失败，配置未写入")
            }
        }
        return result
    }

    private static func candidate(id: String, providerID: String, name: String, source: String,
                                  json: [String: Any], originalURL: URL? = nil,
                                  originalData: Data? = nil) -> ProviderImportCandidate {
        let env = json["env"] as? [String: Any] ?? [:]
        // 列表只显示 host，不回显 URL 的用户名、密码、查询参数或凭据路径。
        let rawURL = env["ANTHROPIC_BASE_URL"] as? String ?? ""
        let endpoint = URLComponents(string: rawURL)?.host ?? "未设置端点"
        let args = json["claude_args"] as? [String] ?? []
        let modelIndex = args.firstIndex(of: "--model")
        let model = modelIndex.flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
            ?? (env["ANTHROPIC_MODEL"] as? String ?? "默认模型")
        var item = ProviderImportCandidate(id: id, providerID: providerID,
            displayName: gatewayVisibleText(name), sourceLabel: source,
            endpoint: gatewayVisibleText(endpoint), model: gatewayVisibleText(model), json: json,
            originalURL: originalURL, originalData: originalData)
        if originalURL == nil {
            let target = providersDir.appendingPathComponent(providerID).appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: target.path) { item.unavailableReason = "已存在，保留原线路" }
        }
        return item
    }

    private static func readCCSwitch(url: URL, label: String) throws -> [ProviderImportCandidate] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw failure("数据库不可打开")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1500)
        var statement: OpaquePointer?
        let query = "SELECT id, name, settings_config FROM providers WHERE app_type = 'claude' ORDER BY name"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK else {
            throw failure("数据库不含支持的 Claude 配置结构")
        }
        defer { sqlite3_finalize(statement) }
        var result: [ProviderImportCandidate] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure("数据库读取未完成") }
            func column(_ index: Int32) -> String? {
                sqlite3_column_text(statement, index).map { String(cString: $0) }
            }
            guard let id = column(0), let name = column(1), let raw = column(2),
                  let data = raw.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let env = json["env"] as? [String: Any] else { continue }
            let providerID = "ccswitch-" + (isValidProviderID(id) ? id : digest(id))
            var providerJSON: [String: Any] = ["env": env]
            if let args = json["claude_args"] as? [String] { providerJSON["claude_args"] = args }
            result.append(candidate(id: "cc-switch:\(id)", providerID: providerID, name: name,
                                    source: label, json: providerJSON))
        }
    }

    private static func normalizedEndpoint(_ value: String) -> String {
        guard let parts = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased() else { return "" }
        let port = parts.port ?? (scheme == "https" ? 443 : 80)
        // 网关存的是完整 /v1/messages，直连存 API 根；同源 + 同凭据才标记已有。
        return "\(scheme)://\(host):\(port)"
    }

    private static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "provider-import", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
