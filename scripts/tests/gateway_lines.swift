import Foundation

// No network, user keychain or real provider directory is touched by this harness.
enum SecretResolver {
    static var secrets: [String: String] = [:]
    static func value(from value: Any?) -> String? { value as? String }
    static func keychainCommand(service: String) -> String { "security find-generic-password -s \(service) -w 2>/dev/null" }
    static func storeKeychain(service: String, secret: String) throws { secrets[service] = secret }
    static func readKeychain(service: String) -> String? { secrets[service] }
    static func invalidateCache() {}
}
enum SecretRedactor { static func redact(_ text: String) -> String { text } }
enum CCRConfigService {
    struct State { let origin: String }
    static func serviceState() -> State? { nil }
    static func fetchConfig(state: State) throws -> [String: Any] { [:] }
}

@main struct GatewayTests {
    static func check(_ value: Bool, _ message: String = "assertion failed") { precondition(value, message) }
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("providers")
        check(try GatewayLineService.inferenceOrigin(config: ["HOST": "127.0.0.1", "PORT": 3456]) == "http://127.0.0.1:3456")
        do {
            _ = try GatewayLineService.inferenceOrigin(config: [:])
            fatalError("missing inference port fell back to management server")
        } catch { check(error.localizedDescription.contains("转发端口无效")) }
        let config: [String: Any] = ["Providers": [
            ["name": "dragon-grok", "api_key": "synthetic-upstream-secret", "models": ["grok-4.6", "grok-4.7"]],
            ["name": "zenmux", "models": ["x-ai/grok-4.7", "x-ai-grok-4.7"]]
        ]]
        let lines = try GatewayLineService.makeLines(config: config, origin: "http://127.0.0.1:3456")
        check(lines.count == 2, "models leaked into the pipeline picker")
        let grok = lines.values.first { $0["gateway_provider"] as? String == "dragon-grok" }!
        check(grok["display_name"] as? String == "Dragon Code Grok")
        check(grok["claude_args"] as? [String] == ["--model", "dragon-grok/grok-4.7"])
        let bytes = try JSONSerialization.data(withJSONObject: lines)
        check(!String(decoding: bytes, as: UTF8.self).contains("synthetic-upstream-secret"))
        check((grok["env"] as! [String: Any]).count == 2)
        check((lines.values.first { $0["gateway_provider"] as? String == "zenmux" }!["gateway_models"] as? [String])?.count == 2)
        print("PASS: one entry per pipeline, exact default model route, full namespaced model list, no upstream credentials")

        try GatewayLineService.synchronize(lines, directory: directory)
        let fm = FileManager.default
        check((try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as! Int) == 0o700)
        for id in lines.keys {
            let file = directory.appendingPathComponent(id + ".json")
            check((try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as! Int) == 0o600)
        }
        let manual = directory.appendingPathComponent("manual.json")
        try Data("{\"source\":\"manual\",\"env\":{}}".utf8).write(to: manual)
        let retained = [lines.keys.sorted()[0]: lines[lines.keys.sorted()[0]]!]
        try GatewayLineService.synchronize(retained, directory: directory)
        check(try fm.contentsOfDirectory(atPath: directory.path).count == 2)
        check(fm.fileExists(atPath: manual.path))
        do {
            try GatewayLineService.synchronize(["manual": grok], directory: directory)
            fatalError("manual file collision was accepted")
        } catch { check(error.localizedDescription.contains("文件名冲突")) }
        do {
            _ = try GatewayLineService.makeLines(config: ["Providers": "broken"], origin: "http://127.0.0.1:3456")
            fatalError("malformed config was accepted")
        } catch { check(error.localizedDescription.contains("配置结构异常")) }
        check(try fm.contentsOfDirectory(atPath: directory.path).count == 2)
        print("PASS: 700/600 permissions, only stale generated files removed, collision/error preserves files")

        let defaults = [
            ["claude-sonnet-5", "claude-opus-4-8", "claude-opus-5-5", "claude-fable-5-1"],
            ["grok-4.6", "grok-4.7"], ["glm-5.2", "glm-5.3", "glm-5.3-flash"],
            ["qwen3.8-max", "qwen3.8-flash"], ["kimi-for-coding", "k3", "kimi-for-coding-highspeed"]
        ]
        let expected = ["claude-opus-5-5", "grok-4.7", "glm-5.3", "qwen3.8-max", "k3"]
        for (models, selected) in zip(defaults, expected) { check(GatewayLineService.suggestedModel(models) == selected) }
        let migrationState = directory.deletingLastPathComponent().appendingPathComponent("migration")
        let migrationDir = migrationState.appendingPathComponent("providers")
        try fm.createDirectory(at: migrationDir, withIntermediateDirectories: true)
        var old = grok
        old.removeValue(forKey: "gateway_models")
        old["display_name"] = "Dragon Code Grok 4.7"
        old["env"] = ["ANTHROPIC_BASE_URL": "http://127.0.0.1:3458", "ANTHROPIC_MODEL": "dragon-grok/grok-4.7"]
        let oldFile = migrationDir.appendingPathComponent("old-model-entry.json")
        try JSONSerialization.data(withJSONObject: old).write(to: oldFile)
        try Data("old-model-entry".utf8).write(to: migrationState.appendingPathComponent("current-provider"))
        for id in ["ccr", "ccr-dear", "ccr-bailian"] {
            try JSONSerialization.data(withJSONObject: ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:3456"]])
                .write(to: migrationDir.appendingPathComponent(id + ".json"))
        }
        try GatewayLineService.synchronize(lines, directory: migrationDir)
        let alias = providerConfiguration("old-model-entry", directory: migrationDir)!
        check(alias["source"] as? String == "gateway-alias")
        check((alias["env"] as? [String: Any])?["ANTHROPIC_BASE_URL"] as? String == "http://127.0.0.1:3456")
        check(alias["claude_args"] as? [String] == old["claude_args"] as? [String])
        let service = ProviderService(claudeDir: migrationState)
        let visible = service.availableProviders()
        let grokID = GatewayLineService.pipelineID("dragon-grok")
        check(visible.count == 2 && !visible.contains("old-model-entry") && !visible.contains("ccr-dear"))
        check(service.preferredLaunchProvider(from: visible) == grokID)
        try GatewayLineService.saveDefaultModel(providerID: grokID, model: "grok-4.6", directory: migrationDir)
        let savedModel = try Data(contentsOf: migrationDir.appendingPathComponent(grokID + ".json"))
        let refreshed = try GatewayLineService.makeLines(config: config, origin: "http://127.0.0.1:3456", existing: GatewayLineService.readLines(migrationDir))
        check(refreshed[grokID]?["gateway_model"] as? String == "grok-4.6")
        check(refreshed[grokID]?["claude_args"] as? [String] == ["--model", "dragon-grok/grok-4.6"])
        do {
            try GatewayLineService.saveDefaultModel(providerID: grokID, model: "other-provider/opus", directory: migrationDir)
            fatalError("unsupported model was accepted")
        } catch { check(error.localizedDescription.contains("不支持此模型")) }
        check(try Data(contentsOf: migrationDir.appendingPathComponent(grokID + ".json")) == savedModel)
        check(providerConfiguration("old-model-entry", directory: migrationDir)?["claude_args"] as? [String] == ["--model", "dragon-grok/grok-4.7"])
        // 思考强度：走完整刷新（makeLines + synchronize）不丢；非法值、别名都拒绝且不动文件；清除后刷新不复活
        let grokFile = migrationDir.appendingPathComponent(grokID + ".json")
        try GatewayLineService.saveDefaultEffort(providerID: grokID, effort: "max", directory: migrationDir)
        check(providerConfiguration(grokID, directory: migrationDir)?["effort"] as? String == "max")
        check((try fm.attributesOfItem(atPath: grokFile.path)[.posixPermissions] as! Int) == 0o600)
        try GatewayLineService.synchronize(try GatewayLineService.makeLines(config: config, origin: "http://127.0.0.1:3456",
            existing: GatewayLineService.readLines(migrationDir)), directory: migrationDir)
        let afterRefresh = providerConfiguration(grokID, directory: migrationDir)
        check(afterRefresh?["effort"] as? String == "max", "refresh dropped the effort setting")
        check(afterRefresh?["gateway_model"] as? String == "grok-4.6" && afterRefresh?["claude_args"] as? [String] == ["--model", "dragon-grok/grok-4.6"])
        let savedEffort = try Data(contentsOf: grokFile)
        do {
            try GatewayLineService.saveDefaultEffort(providerID: grokID, effort: "ultra", directory: migrationDir)
            fatalError("invalid effort was accepted")
        } catch { check(error.localizedDescription.contains("思考强度无效")) }
        do {
            try GatewayLineService.saveDefaultEffort(providerID: "old-model-entry", effort: "max", directory: migrationDir)
            fatalError("effort was saved on a hidden alias")
        } catch { check(error.localizedDescription.contains("不支持设置思考强度")) }
        check(try Data(contentsOf: grokFile) == savedEffort)
        check(providerConfiguration("old-model-entry", directory: migrationDir)?["effort"] == nil)
        var tampered = afterRefresh!
        tampered["effort"] = "ultra"
        let notInherited = try GatewayLineService.makeLines(config: config, origin: "http://127.0.0.1:3456", existing: [grokID: tampered])
        check(notInherited[grokID]?["effort"] == nil, "invalid effort leaked through refresh")
        try GatewayLineService.saveDefaultEffort(providerID: grokID, effort: nil, directory: migrationDir)
        check(providerConfiguration(grokID, directory: migrationDir)?["effort"] == nil)
        let cleared = try GatewayLineService.makeLines(config: config, origin: "http://127.0.0.1:3456", existing: GatewayLineService.readLines(migrationDir))
        check(cleared[grokID]?["effort"] == nil)
        print("PASS: effort saved 0600, survives full refresh, invalid value / alias rejected without writes, cleared stays cleared")
        // 优惠页 URL：与 effort 完全同一套不变量。
        // 这里测的不是「能不能存」，而是「整份重建之后还在不在」——
        // makeLines 会重建整个 lines 字典，漏带字段不会报错，只会让用户填的东西某天消失。
        let promoURL = "https://help.aliyun.com/zh/model-studio/billing-for-model-studio"
        try GatewayLineService.savePromoURL(providerID: grokID, url: promoURL, directory: migrationDir)
        check(providerConfiguration(grokID, directory: migrationDir)?["promo_url"] as? String == promoURL)
        check((try fm.attributesOfItem(atPath: grokFile.path)[.posixPermissions] as! Int) == 0o600,
              "promo_url 写盘后权限必须是 600（线路文件里有 $exec 密钥引用）")
        try GatewayLineService.synchronize(try GatewayLineService.makeLines(config: config,
            origin: "http://127.0.0.1:3456", existing: GatewayLineService.readLines(migrationDir)),
            directory: migrationDir)
        let afterPromoRefresh = providerConfiguration(grokID, directory: migrationDir)
        check(afterPromoRefresh?["promo_url"] as? String == promoURL,
              "🔴 网关刷新把用户填的优惠页 URL 抹掉了 —— makeLines 里漏了显式带过来")
        check(afterPromoRefresh?["effort"] as? String == nil, "effort 之前已被清除，不该复活")
        check(afterPromoRefresh?["gateway_model"] as? String == "grok-4.6", "刷新没有顺手弄坏别的字段")

        // 非法值：拒绝且**不动文件**（不能先写坏再回滚）
        let savedPromo = try Data(contentsOf: grokFile)
        for bad in ["不是 URL", "", "   ", "file:///etc/passwd", "ftp://example.com/x",
                    "https://", "javascript:alert(1)"] {
            do {
                try GatewayLineService.savePromoURL(providerID: grokID, url: bad, directory: migrationDir)
                fatalError("非法优惠页 URL 被接受了：\(bad)")
            } catch { check(error.localizedDescription.contains("优惠页地址无效"), "拒绝 \(bad)") }
        }
        check(try Data(contentsOf: grokFile) == savedPromo, "拒绝非法值时文件一字节都不该动")

        // file:// 必须被拒：它会让本地文件内容被当成「优惠情报」显示到面板上
        do {
            try GatewayLineService.savePromoURL(providerID: grokID, url: "file:///etc/passwd",
                                                directory: migrationDir)
            fatalError("file:// 被接受了 —— 本地文件内容会进情报面板")
        } catch { check(error.localizedDescription.contains("只支持 http")) }

        // 隐藏别名（非 gateway source）上不许设置，与 effort 同规则
        do {
            try GatewayLineService.savePromoURL(providerID: "old-model-entry", url: promoURL,
                                                directory: migrationDir)
            fatalError("在隐藏别名上存了优惠页 URL")
        } catch { check(error.localizedDescription.contains("不支持设置优惠页")) }
        check(providerConfiguration("old-model-entry", directory: migrationDir)?["promo_url"] == nil)

        // 被手改坏的旧值不能透过刷新继承（与 effort 的 notInherited 同一条）
        var tamperedPromo = afterPromoRefresh!
        tamperedPromo["promo_url"] = "file:///etc/passwd"
        let notInheritedPromo = try GatewayLineService.makeLines(config: config,
            origin: "http://127.0.0.1:3456", existing: [grokID: tamperedPromo])
        check(notInheritedPromo[grokID]?["promo_url"] == nil, "非法 promo_url 透过刷新漏了进来")

        // 清除后刷新不复活
        try GatewayLineService.savePromoURL(providerID: grokID, url: nil, directory: migrationDir)
        check(providerConfiguration(grokID, directory: migrationDir)?["promo_url"] == nil)
        let clearedPromo = try GatewayLineService.makeLines(config: config,
            origin: "http://127.0.0.1:3456", existing: GatewayLineService.readLines(migrationDir))
        check(clearedPromo[grokID]?["promo_url"] == nil, "清除掉的 promo_url 刷新后复活了")

        // providersDirectory：PromotionService 靠它读线路清单（Task 7）。
        // 断言路径尾巴而不是整串，避免把 $HOME 写死进测试。
        check(GatewayLineService.providersDirectory.path.hasSuffix("/.claude/providers"),
              "providersDirectory 指错地方了：\(GatewayLineService.providersDirectory.path)")
        print("PASS: promo_url saved 0600, survives full refresh, file://+非法值+别名全拒且不动文件, cleared stays cleared")
        // 压缩窗口（524 冷读安全网）：刷新不丢合法值（整数与 "off"），非法值不带过来
        var windowSet = afterRefresh!
        windowSet["auto_compact_window"] = 100000
        let keptWindow = try GatewayLineService.makeLines(config: config, origin: "http://127.0.0.1:3456", existing: [grokID: windowSet])
        check(keptWindow[grokID]?["auto_compact_window"] as? Int == 100000, "refresh dropped auto_compact_window")
        var windowOff = afterRefresh!
        windowOff["auto_compact_window"] = "off"
        let keptOff = try GatewayLineService.makeLines(config: config, origin: "http://127.0.0.1:3456", existing: [grokID: windowOff])
        check(keptOff[grokID]?["auto_compact_window"] as? String == "off", "refresh dropped auto_compact_window=off")
        var windowBad = afterRefresh!
        windowBad["auto_compact_window"] = 42
        let droppedBad = try GatewayLineService.makeLines(config: config, origin: "http://127.0.0.1:3456", existing: [grokID: windowBad])
        check(droppedBad[grokID]?["auto_compact_window"] == nil, "invalid auto_compact_window leaked through refresh")
        var windowBool = afterRefresh!
        windowBool["auto_compact_window"] = true
        let droppedBool = try GatewayLineService.makeLines(config: config, origin: "http://127.0.0.1:3456", existing: [grokID: windowBool])
        check(droppedBool[grokID]?["auto_compact_window"] == nil, "bool auto_compact_window leaked through refresh")
        print("PASS: auto_compact_window survives refresh (int + off), invalid and bool dropped")
        let limitedConfig: [String: Any] = ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:3456",
            "ANTHROPIC_AUTH_TOKEN": ["$exec": "security find-generic-password -s existing-limit -w 2>/dev/null"]]]
        let limited = try GatewayLineService.makeLines(config: ["Providers": [["name": "dragoncode", "models": defaults[0]]]],
            origin: "http://127.0.0.1:3456", existing: ["ccr-dear": limitedConfig,
                GatewayLineService.pipelineID("dragoncode"): ["env": ["ANTHROPIC_BASE_URL": "http://127.0.0.1:3458"]]])
        check((limited.values.first?["env"] as? [String: Any])?["ANTHROPIC_AUTH_TOKEN"] is [String: Any])
        print("PASS: Opus/flagship defaults, hidden alias migration, remembered model, invalid model rejection, original quota reference retained")

        let imported = try ProviderImportService.externalizeSecrets([
            "env": ["ANTHROPIC_API_TOKEN": "fake-token-for-unit-test", "MANAGEMENT_API_KEY": "fake-management-key"],
            "extra": ["password": "fake-password"]
        ], line: "test-line")
        let env = imported["env"] as! [String: Any]
        for key in ["ANTHROPIC_API_TOKEN", "MANAGEMENT_API_KEY"] {
            check((env[key] as? [String: String])?["$exec"]?.contains(" -w 2>/dev/null") == true)
        }
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: imported), as: UTF8.self)
        check(!encoded.contains("fake-token-for-unit-test") && !encoded.contains("fake-password"))
        check(SecretResolver.secrets.count == 3)
        print("PASS: API_TOKEN, management key and nested password externalized using in-memory keychain")
        let selected = ProviderImportCandidate(id: "selected", providerID: "selected", displayName: "Selected",
            sourceLabel: "fixture", endpoint: "localhost", model: "grok-4.7",
            json: ["env": ["ANTHROPIC_API_TOKEN": "fake-import-secret"]], originalURL: nil, originalData: nil)
        let result = ProviderImportService.importSelected([selected], directory: directory)
        check(result.imported == ["selected"] && result.errors.isEmpty)
        let selectedFile = directory.appendingPathComponent("selected.json")
        let savedData = try Data(contentsOf: selectedFile)
        let saved = try JSONSerialization.jsonObject(with: savedData) as! [String: Any]
        check(saved["source"] as? String == "imported")
        check(!String(decoding: savedData, as: UTF8.self).contains("fake-import-secret"))
        check((try fm.attributesOfItem(atPath: selectedFile.path)[.posixPermissions] as! Int) == 0o600)
        let again = ProviderImportService.importSelected([selected], directory: directory)
        check(again.imported.isEmpty && again.errors.first?.contains("已存在") == true)
        check(try Data(contentsOf: selectedFile) == savedData)
        let empty = ProviderImportService.importSelected([], directory: directory)
        check(empty.imported.isEmpty && empty.errors.isEmpty)
        check(try fm.contentsOfDirectory(atPath: directory.path).count == 3)
        print("PASS: selected-only import, empty selection writes nothing, duplicate import preserves existing file")
        check(gatewayModelDisplayName("zenmux/x-ai/grok-4.7") == "ZenMux Grok 4.7")
        check(gatewayProviderGroupDisplayName("dragon-grok") != gatewayProviderGroupDisplayName("dragoncode"))
        print("PASS: grouped providers remain distinguishable")
    }
}
