import Foundation
import CryptoKit
import Combine

/// Materializes routing metadata only. Upstream credentials stay in the gateway.
final class GatewayLineService: ObservableObject {
    static let shared = GatewayLineService()
    @Published private(set) var lastError: String?
    @Published private(set) var refreshing = false
    private let queue = DispatchQueue(label: "ccpod.gateway-lines", qos: .utility)
    private var completions: [() -> Void] = []

    func refresh(completion: @escaping () -> Void = {}) {
        // All callers are UI entry points; coalesce concurrent refresh requests.
        completions.append(completion)
        guard !refreshing else { return }
        refreshing = true
        queue.async {
            let error: String?
            do {
                guard let state = CCRConfigService.serviceState() else {
                    throw Self.failure("网关未运行，保留上次同步的线路")
                }
                let config = try CCRConfigService.fetchConfig(state: state)
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/providers")
                let origin = try Self.inferenceOrigin(config: config)
                let lines = try Self.makeLines(config: config, origin: origin, existing: Self.readLines(directory))
                try Self.synchronize(lines, directory: directory)
                error = nil
            } catch let failure {
                error = gatewayVisibleText(failure.localizedDescription)
            }
            DispatchQueue.main.async {
                self.lastError = error
                self.refreshing = false
                let callbacks = self.completions
                self.completions.removeAll()
                callbacks.forEach { $0() }
            }
        }
    }

    func setDefaultModel(providerID: String, model: String, completion: @escaping (String?) -> Void) {
        queue.async {
            let error: String?
            do {
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/providers")
                try Self.saveDefaultModel(providerID: providerID, model: model, directory: directory)
                error = nil
            } catch let failure { error = gatewayVisibleText(failure.localizedDescription) }
            DispatchQueue.main.async { completion(error) }
        }
    }

    func setDefaultEffort(providerID: String, effort: String?, completion: @escaping (String?) -> Void) {
        queue.async {
            let error: String?
            do {
                let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/providers")
                try Self.saveDefaultEffort(providerID: providerID, effort: effort, directory: directory)
                error = nil
            } catch let failure { error = gatewayVisibleText(failure.localizedDescription) }
            DispatchQueue.main.async { completion(error) }
        }
    }

    func setPromoURL(providerID: String, url: String?, completion: @escaping (String?) -> Void) {
        queue.async {
            let error: String?
            do {
                try Self.savePromoURL(providerID: providerID, url: url, directory: Self.providersDirectory)
                error = nil
            } catch let failure { error = gatewayVisibleText(failure.localizedDescription) }
            DispatchQueue.main.async { completion(error) }
        }
    }

    static func pipelineID(_ provider: String) -> String {
        let digest = SHA256.hash(data: Data(provider.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
        return "gw-" + String(provider.prefix(100)) + "-" + digest
    }

    static func inferenceOrigin(config: [String: Any]) throws -> String {
        // service.json points at the management server; it can use a different port.
        guard let port = (config["PORT"] as? Int) ?? (config["PORT"] as? String).flatMap(Int.init),
              (1...65535).contains(port) else { throw failure("网关转发端口无效，未修改已有管线") }
        let host = config["HOST"] as? String ?? "127.0.0.1"
        guard ["127.0.0.1", "localhost", "::1", "[::1]", "0.0.0.0", "::"].contains(host) else {
            throw failure("网关转发地址不是本机，未修改已有管线")
        }
        let target = ["::1", "[::1]", "::"].contains(host) ? "[::1]" : (host == "0.0.0.0" ? "127.0.0.1" : host)
        return "http://\(target):\(port)"
    }

    /// A product default, not a benchmark ranking: prefer Opus, then full models over fast variants.
    static func suggestedModel(_ models: [String]) -> String? {
        func rank(_ model: String) -> Int {
            let name = model.lowercased()
            if name.contains("opus") { return 100 }
            if name.contains("fable") { return 90 }
            if name.contains("sonnet") { return 80 }
            if name.contains("haiku") { return 10 }
            if ["flash", "fast", "mini", "lite", "highspeed"].contains(where: name.contains) { return 20 }
            return name.contains("max") ? 70 : 60
        }
        func version(_ model: String) -> [Int] {
            let regex = try! NSRegularExpression(pattern: "[0-9]+")
            return regex.matches(in: model, range: NSRange(model.startIndex..., in: model)).compactMap {
                Range($0.range, in: model).flatMap { Int(model[$0]) }
            }
        }
        return models.sorted { lhs, rhs in
            if rank(lhs) != rank(rhs) { return rank(lhs) > rank(rhs) }
            let left = version(lhs), right = version(rhs)
            for index in 0..<max(left.count, right.count) {
                let a = index < left.count ? left[index] : 0
                let b = index < right.count ? right[index] : 0
                if a != b { return a > b }
            }
            return lhs.localizedStandardCompare(rhs) == .orderedDescending
        }.first
    }

    static func makeLines(config: [String: Any], origin: String,
                          existing: [String: [String: Any]] = [:]) throws -> [String: [String: Any]] {
        guard let url = URL(string: origin), ["http", "https"].contains(url.scheme ?? ""),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? ""),
              let providers = config["Providers"] as? [[String: Any]] else {
            throw failure("网关配置结构异常，未修改已有线路")
        }
        var lines: [String: [String: Any]] = [:]
        for provider in providers {
            guard let name = provider["name"] as? String, isValidProviderID(name),
                  let models = provider["models"] as? [String],
                  models.allSatisfy({ !$0.isEmpty && !$0.contains("\n") && !$0.contains("\0") }) else {
                throw failure("网关厂商或模型列表异常，未修改已有线路")
            }
            guard let suggested = suggestedModel(models) else { continue }
            let id = pipelineID(name)
            guard lines[id] == nil else { throw failure("网关厂商名称重复，未修改已有管线") }
            let previous = existing[id]
            let selected = previous?["gateway_model"] as? String
            let manual = previous?["model_selection"] as? String == "manual" && models.contains(selected ?? "")
            let model = manual ? selected! : suggested
            let route = name + "/" + model
            var env: [String: Any] = ["ANTHROPIC_BASE_URL": origin, "ANTHROPIC_MODEL": route]
            // Grouping must not silently discard the old Dragon Code quota credential.
            let previousEnv = previous?["env"] as? [String: Any] ?? [:]
            let ownAuth = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_API_TOKEN"].contains { previousEnv[$0] != nil }
            let authConfig = ownAuth ? previous : (name == "dragoncode" ? existing["ccr-dear"] : nil)
            if let authEnv = authConfig?["env"] as? [String: Any],
               authEnv["ANTHROPIC_BASE_URL"] as? String == origin {
                for field in ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_API_TOKEN"] {
                    if let reference = authEnv[field] as? [String: Any],
                       reference.count == 1, reference["$exec"] is String { env[field] = reference }
                }
            }
            lines[id] = [
                "source": "gateway", "display_name": gatewayProviderGroupDisplayName(name),
                "gateway_provider": name, "gateway_model": model,
                "gateway_models": Array(Set(models)).sorted { $0.localizedStandardCompare($1) == .orderedAscending },
                "model_selection": manual ? "manual" : "automatic",
                "env": env,
                "claude_args": ["--model", route]
            ]
            if previous?["model_selection"] as? String == "manual", !manual, let selected {
                lines[id]?["model_notice"] = "原默认模型 \(modelDisplayName(selected)) 已不在管线中，改用 \(modelDisplayName(model))"
            } else if !manual, let notice = previous?["model_notice"] as? String {
                lines[id]?["model_notice"] = notice
            }
            // 思考强度是用户设置，上面整份重建会丢掉它，必须显式带过来
            if let effort = previous?["effort"] as? String, effortLevels.contains(effort) {
                lines[id]?["effort"] = effort
            }
            // 优惠页 URL 也是用户设置，同样会被上面整份重建丢掉，必须显式带过来。
            // 与 effort 同一个坑：漏了不会报错，只会让用户填的 URL 某天悄悄消失。
            if let promoURL = previous?["promo_url"] as? String, isValidPromoURL(promoURL) {
                lines[id]?["promo_url"] = promoURL
            }
            // 压缩窗口同理（524 冷读安全网，2026-10-10）：整份重建会丢掉它，必须显式带过来。
            // 校验口径与 scripts/lib/line_models.py 一致：100000–1000000 的整数或 "off"。
            if let window = previous?["auto_compact_window"] {
                if let value = window as? Int, (100000...1000000).contains(value) {
                    lines[id]?["auto_compact_window"] = value
                } else if let off = window as? String, off == "off" {
                    lines[id]?["auto_compact_window"] = off
                }
            }
        }
        return lines
    }

    static func synchronize(_ lines: [String: [String: Any]], directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        // Preflight all names before any writes; never overwrite manually owned files.
        for id in lines.keys {
            let file = directory.appendingPathComponent(id + ".json")
            if fm.fileExists(atPath: file.path), providerConfiguration(id, directory: directory)?["source"] as? String != "gateway" {
                throw failure("线路文件名冲突，已保留原文件")
            }
        }
        for (id, line) in lines {
            let file = directory.appendingPathComponent(id + ".json")
            let data = try JSONSerialization.data(withJSONObject: line, options: [.prettyPrinted, .sortedKeys])
            if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            if lines[id] == nil, var old = providerConfiguration(id, directory: directory),
               ["gateway", "gateway-alias"].contains(old["source"] as? String ?? "") {
                if let name = old["gateway_provider"] as? String, let pipeline = lines[pipelineID(name)] {
                    // Keep old commands and running-session references usable, but out of all pickers.
                    old["source"] = "gateway-alias"
                    old["pipeline_id"] = pipelineID(name)
                    old["display_name"] = gatewayProviderGroupDisplayName(name)
                    if var env = old["env"] as? [String: Any], let target = pipeline["env"] as? [String: Any] {
                        env["ANTHROPIC_BASE_URL"] = target["ANTHROPIC_BASE_URL"]
                        old["env"] = env
                    }
                    try writeLine(old, to: file)
                } else if old["source"] as? String == "gateway" { try fm.removeItem(at: file) }
            }
        }
    }

    static func readLines(_ directory: URL) -> [String: [String: Any]] {
        var result: [String: [String: Any]] = [:]
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            result[id] = providerConfiguration(id, directory: directory)
        }
        return result
    }

    static func saveDefaultModel(providerID: String, model: String, directory: URL) throws {
        guard var line = providerConfiguration(providerID, directory: directory), line["source"] as? String == "gateway",
              let provider = line["gateway_provider"] as? String,
              let models = line["gateway_models"] as? [String], models.contains(model),
              var env = line["env"] as? [String: Any] else {
            throw failure("该管线不支持此模型，请刷新后重选")
        }
        let route = provider + "/" + model
        env["ANTHROPIC_MODEL"] = route
        line["env"] = env
        line["gateway_model"] = model
        line["model_selection"] = "manual"
        line.removeValue(forKey: "model_notice")
        line["claude_args"] = ["--model", route]
        try writeLine(line, to: directory.appendingPathComponent(providerID + ".json"))
    }

    /// Claude Code `--effort` 接受的档位，与 scripts/lib/line_models.py 的 EFFORTS 一致。
    static let effortLevels = ["low", "medium", "high", "xhigh", "max"]

    /// nil = 删掉字段：启动不带 --effort，跟随全局 effortLevel。只影响之后启动或重启的会话。
    static func saveDefaultEffort(providerID: String, effort: String?, directory: URL) throws {
        guard var line = providerConfiguration(providerID, directory: directory), line["source"] as? String == "gateway" else {
            throw failure("该管线不支持设置思考强度，请刷新后重试")
        }
        if let effort {
            guard effortLevels.contains(effort) else { throw failure("思考强度无效：\(effort)") }
            line["effort"] = effort
        } else {
            line.removeValue(forKey: "effort")
        }
        try writeLine(line, to: directory.appendingPathComponent(providerID + ".json"))
    }

    /// `~/.claude/providers`。上面三个实例方法（refresh / setDefaultModel / setDefaultEffort）
    /// 各自内联了同一条字面量，这里给外部调用方一个入口，不抄第四遍。
    /// PromotionService 要用它读线路清单（Task 7）。
    static var providersDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/providers")
    }

    /// 优惠页 URL 校验。**只收 http/https**：
    /// `file://` 会让 `/etc/passwd` 之类的本地文件内容被抓进情报面板，
    /// 那是把本地信息搬到 UI 上，不是这个功能该做的事。
    static func isValidPromoURL(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return false }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return false }
        guard let host = url.host, !host.isEmpty, host.contains(".") || host == "localhost" else { return false }
        return true
    }

    /// nil = 删掉字段（这条线路不再收优惠情报）。
    /// 与 saveDefaultEffort 同一套不变量：只在 gateway 管线上生效、拒绝时不动文件、写盘 600。
    static func savePromoURL(providerID: String, url: String?, directory: URL) throws {
        guard var line = providerConfiguration(providerID, directory: directory),
              line["source"] as? String == "gateway" else {
            throw failure("该管线不支持设置优惠页，请刷新后重试")
        }
        if let url {
            guard isValidPromoURL(url) else {
                let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, let scheme = URL(string: trimmed)?.scheme?.lowercased(),
                   scheme != "http" && scheme != "https" {
                    throw failure("优惠页地址无效：只支持 http / https（收到 \(scheme)://）")
                }
                throw failure("优惠页地址无效：请填一个公开的定价或活动页完整网址")
            }
            line["promo_url"] = url.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            line.removeValue(forKey: "promo_url")
        }
        try writeLine(line, to: directory.appendingPathComponent(providerID + ".json"))
    }

    private static func writeLine(_ line: [String: Any], to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: line, options: [.prettyPrinted, .sortedKeys])
        if (try? Data(contentsOf: file)) != data { try data.write(to: file, options: .atomic) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "gateway-lines", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
