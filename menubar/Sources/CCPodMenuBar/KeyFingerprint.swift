import Foundation
import CryptoKit

/// 密钥指纹：同一厂商可能有多个账号、多把 key（2026-10-08 百炼事故：网关、直连线路、新加线路
/// 三把 sk-sp- key 分属不同账号，前缀全一样，肉眼分不清哪条线路用的是哪把）。
/// 指纹 = SHA256 前 6 位十六进制：同一把 key 在钥匙串和网关里算出来一样，可以对号入座；
/// 不可逆，不泄露 key 本身（AGENTS.md：密钥不进 UI 回显）。
enum KeyFingerprint {
    struct Entry {
        let line: String        // 线路 ID（直连）或网关上游名
        let displayName: String
        let host: String
        let fingerprint: String
    }

    static func of(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return SHA256.hash(data: Data(trimmed.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    static func host(_ url: String) -> String {
        URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() ?? ""
    }

    /// 收集所有已配置 key 的指纹：直连线路（~/.claude/providers，读钥匙串）+ 网关上游（CCR getConfig）。
    /// 会调 security / RPC，必须在后台线程调用。
    static func loadAll(providersDir: URL) -> [Entry] {
        var entries: [Entry] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: providersDir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let env = obj["env"] as? [String: Any] else { continue }
            let baseURL = SecretResolver.value(from: env["ANTHROPIC_BASE_URL"]) ?? ""
            let h = host(baseURL)
            // 经本机网关的线路，key 是网关入站 key，不是上游 key——上游的由下面 CCR 部分覆盖
            guard !h.isEmpty, h != "127.0.0.1", h != "localhost" else { continue }
            let keyField = ["ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_API_TOKEN"].first { env[$0] != nil }
            guard let keyField, let key = SecretResolver.value(from: env[keyField]), !key.isEmpty else { continue }
            let line = file.deletingPathExtension().lastPathComponent
            entries.append(Entry(line: line, displayName: providerDisplayName(line), host: h, fingerprint: of(key)))
        }
        if let state = CCRConfigService.serviceState(),
           let config = try? CCRConfigService.fetchConfig(state: state),
           let providers = config["Providers"] as? [[String: Any]] {
            for p in providers {
                guard let name = p["name"] as? String,
                      let key = SecretResolver.value(from: p["api_key"]), !key.isEmpty else { continue }
                let url = (p["api_base_url"] as? String) ?? ""
                entries.append(Entry(line: name, displayName: gatewayProviderGroupDisplayName(name) + "（网关）",
                                     host: host(url), fingerprint: of(key)))
            }
        }
        return entries
    }

    /// 添加线路时对照已有 key：同一把 → 提示已用在哪；同厂商不同 key → 提示可能是另一个账号。
    /// 只提示不拦截：同一把 key 配不同计费端点是合法的（火山 key 账号级，端点决定计费）。
    static func notice(newKey: String, baseURL: String, existing: [Entry]) -> String? {
        let fp = of(newKey)
        guard !fp.isEmpty else { return nil }
        let same = existing.filter { $0.fingerprint == fp }
        if !same.isEmpty {
            return "ℹ️ 这把 key（指纹 \(fp)）已用在：\(same.map(\.displayName).joined(separator: "、"))"
        }
        let h = host(baseURL)
        let siblings = existing.filter { !$0.host.isEmpty && $0.host == h }
        if !siblings.isEmpty {
            let list = siblings.map { "\($0.displayName)［\($0.fingerprint)］" }.joined(separator: "、")
            return "ℹ️ 同厂商已有别的 key：\(list)。新 key 指纹 \(fp)——如果是另一个账号，名称里写上账号备注（如「百炼-工作号」）方便区分"
        }
        return nil
    }
}
