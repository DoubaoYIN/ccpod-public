import Foundation

/// Display labels never change the IDs used by launch scripts or gateway routing.
func gatewayVisibleText(_ text: String) -> String {
    SecretRedactor.redact(text).replacingOccurrences(of: "CCR", with: "网关", options: .caseInsensitive)
        .replacingOccurrences(of: "贵线", with: "限额线路")
}

func gatewayProviderDisplayName(_ id: String) -> String {
    let names = ["dragoncode": "Dragon Code", "dragon-grok": "Dragon Code",
                 "glm": "智谱", "bailian": "百炼", "kimi": "Kimi",
                 "yescode": "Yescode", "zenmux": "ZenMux", "aigocode": "AIGoCode"]
    return names[id.lowercased()] ?? gatewayVisibleText(id)
}

func gatewayProviderGroupDisplayName(_ id: String) -> String {
    switch id.lowercased() {
    case "dragoncode": return "Dragon Code Claude"
    case "dragon-grok": return "Dragon Code Grok"
    default: return gatewayProviderDisplayName(id)
    }
}

func gatewayModelDisplayName(_ route: String) -> String {
    let parts = route.split(separator: route.contains(",") ? "," : "/", maxSplits: 1).map(String.init)
    if parts.count == 2 {
        return gatewayProviderDisplayName(parts[0]) + " " + modelDisplayName(parts[1])
    }
    return modelDisplayName(route)
}

func modelDisplayName(_ model: String) -> String {
    var name = model
    if name.hasPrefix("x-ai/") { name.removeFirst(5) }
    if name.hasPrefix("claude-") { name.removeFirst(7) }
    if name.hasPrefix("kimi-") { name.removeFirst(5) }
    name = name.replacingOccurrences(of: "-[0-9]{8}$", with: "", options: .regularExpression)
    name = name.replacingOccurrences(of: "(?<=[0-9])-(?=[0-9])", with: ".", options: .regularExpression)
    let words = name.split(separator: "-").map { word -> String in
        let value = String(word)
        if value.lowercased() == "glm" { return "GLM" }
        if value.lowercased().hasPrefix("qwen") { return "Qwen" + value.dropFirst(4) }
        return value.prefix(1).uppercased() + value.dropFirst()
    }
    return gatewayVisibleText(words.joined(separator: " "))
}

func providerConfiguration(_ id: String, directory: URL? = nil) -> [String: Any]? {
    guard isValidProviderID(id) else { return nil }
    let root = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/providers")
    guard let data = try? Data(contentsOf: root.appendingPathComponent(id + ".json")) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func isLocalGatewayConfiguration(_ config: [String: Any]) -> Bool {
    guard let env = config["env"] as? [String: Any],
          let base = env["ANTHROPIC_BASE_URL"] as? String,
          let url = URL(string: base), let host = url.host else { return false }
    return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host.lowercased())
}

func providerDisplayName(_ id: String) -> String {
    if let config = providerConfiguration(id) {
        if let provider = config["gateway_provider"] as? String { return gatewayProviderGroupDisplayName(provider) }
        if let name = config["display_name"] as? String, !name.isEmpty { return gatewayVisibleText(name) }
        if isLocalGatewayConfiguration(config), let env = config["env"] as? [String: Any],
           let model = env["ANTHROPIC_MODEL"] as? String,
           let provider = model.split(separator: "/", maxSplits: 1).first, model.contains("/") {
            return gatewayProviderGroupDisplayName(String(provider))
        }
    }
    switch id.lowercased() {
    case "ccr": return "网关默认管线"
    case "ccr-dear": return "Dragon Code Claude"
    case "ccr-bailian": return "百炼"
    case "official": return "官方账号"
    default: return gatewayProviderDisplayName(id)
    }
}

final class ProviderService {
    var onChange: ((String?) -> Void)?

    private let claudeDir: URL
    private let currentProviderURL: URL
    private let providersDirURL: URL
    private var fileSource: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1

    init(claudeDir: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.claudeDir = claudeDir ?? home.appendingPathComponent(".claude", isDirectory: true)
        self.currentProviderURL = self.claudeDir.appendingPathComponent("current-provider")
        self.providersDirURL = self.claudeDir.appendingPathComponent("providers", isDirectory: true)
    }

    func currentProvider() -> String? {
        guard let data = try? String(contentsOf: currentProviderURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func availableProviders() -> [String] {
        let configs = GatewayLineService.readLines(providersDirURL)
        let hasPipelines = configs.values.contains { $0["source"] as? String == "gateway" && $0["gateway_models"] is [String] }
        return configs.keys.filter { id in
            guard !id.contains(".example"), let config = configs[id] else { return false }
            let source = config["source"] as? String ?? ""
            if source == "gateway-alias" { return false }
            if source == "gateway" { return !hasPipelines || config["gateway_models"] is [String] }
            if ["imported", "manual"].contains(source) { return true }
            return !hasPipelines && ["ccr", "ccr-bailian", "ccr-dear"].contains(id) && isLocalGatewayConfiguration(config)
        }.sorted { providerDisplayName($0).localizedStandardCompare(providerDisplayName($1)) == .orderedAscending }
    }

    func resolvedPipeline(_ id: String, from providers: [String]) -> String? {
        if providers.contains(id) { return id }
        let config = providerConfiguration(id, directory: providersDirURL)
        if let target = config?["pipeline_id"] as? String, providers.contains(target) { return target }
        var vendor = config?["gateway_provider"] as? String
        if vendor == nil {
            switch id {
            case "ccr-dear": vendor = "dragoncode"
            case "ccr-bailian": vendor = "bailian"
            case "ccr":
                let settings = claudeDir.appendingPathComponent("settings.json")
                if let data = try? Data(contentsOf: settings),
                   let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let env = json["env"] as? [String: Any], let route = env["ANTHROPIC_MODEL"] as? String {
                    vendor = route.components(separatedBy: CharacterSet(charactersIn: "/,")).first
                }
            default: break
            }
        }
        guard let vendor else { return nil }
        return providers.first { providerConfiguration($0, directory: providersDirURL)?["gateway_provider"] as? String == vendor }
    }

    func preferredLaunchProvider(from providers: [String]) -> String {
        if let current = currentProvider(), let pipeline = resolvedPipeline(current, from: providers) { return pipeline }
        if let opusPipeline = providers.first(where: { providerConfiguration($0, directory: providersDirURL)?["gateway_provider"] as? String == "dragoncode" }) { return opusPipeline }
        return providers.first ?? ""
    }

    func effectiveDefaultProvider(from providers: [String]) -> String {
        preferredLaunchProvider(from: providers)
    }

    func start() {
        watchCurrentProvider()
        GatewayLineService.shared.refresh { [weak self] in self?.onChange?(self?.currentProvider()) }
    }

    func stop() {
        fileSource?.cancel()
        fileSource = nil
        fd = -1 // The cancelled source owns and closes its captured descriptor.
    }

    private func watchCurrentProvider() {
        stop()
        let path = currentProviderURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            watchClaudeDir()
            return
        }
        fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let watchedFD = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFD,
            eventMask: [.write, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self = self, let source else { return }
            self.onChange?(self.currentProvider())
            if source.data.contains(.delete) || source.data.contains(.rename) {
                self.watchCurrentProvider()
            }
        }
        source.setCancelHandler { close(watchedFD) }
        source.resume()
        fileSource = source
    }

    private func watchClaudeDir() {
        let dirPath = claudeDir.path
        let dirFD = open(dirPath, O_EVTONLY)
        guard dirFD >= 0 else { return }
        fd = dirFD
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            if FileManager.default.fileExists(atPath: self.currentProviderURL.path) {
                self.watchCurrentProvider()
                self.onChange?(self.currentProvider())
            }
        }
        source.setCancelHandler { close(dirFD) }
        source.resume()
        fileSource = source
    }
}
