import Foundation

struct ErrorDiagnosisConfig {
    let providerName: String
    let baseURL: String
    let apiKey: String
    let model: String
    let timeout: TimeInterval
}

struct ErrorDiagnosisResult {
    let summary: String
    let providerLabel: String
    let problemLabel: String
    let action: String
    let detail: String
    let model: String
    let elapsed: TimeInterval
    let isPreview: Bool
}

enum ErrorDiagnosisError: LocalizedError {
    case noConfig
    case emptyInput
    case httpError(Int, String)
    case decodingFailed(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .noConfig:
            return "未找到错误诊断配置。请先在 ~/.ccpod/error-diagnosis.json 配置 primary（通义千问）。"
        case .emptyInput:
            return "请输入要解读的错误内容。"
        case .httpError(let code, let body):
            return "调用模型失败 (HTTP \(code))：\(body)"
        case .decodingFailed(let msg):
            return "返回内容解析失败：\(msg)"
        case .transport(let msg):
            return "网络错误：\(msg)"
        }
    }
}

final class ErrorDiagnosisService {
    static let shared = ErrorDiagnosisService()
    private let configURL: URL
    private let legacyApprovalURL: URL

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configURL = home.appendingPathComponent(".ccpod/error-diagnosis.json")
        legacyApprovalURL = home.appendingPathComponent(".ccpod/approval-config.json")
    }

    func loadPrimaryConfig() -> ErrorDiagnosisConfig? {
        if let cfg = loadFromDedicatedFile(slot: "primary") { return cfg }
        return loadFromLegacyApprovalConfig()
    }

    func loadFastPreviewConfig() -> ErrorDiagnosisConfig? {
        return loadFromDedicatedFile(slot: "fast_preview")
    }

    private func loadFromDedicatedFile(slot: String) -> ErrorDiagnosisConfig? {
        guard let data = try? Data(contentsOf: configURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = obj[slot] as? [String: Any] else {
            return nil
        }
        // 用 SecretResolver：api_key 允许写成 {"$exec": "security find-generic-password …"}，
        // 这样密钥只存钥匙串、配置文件里不留明文
        let baseURL = SecretResolver.value(from: entry["base_url"]) ?? ""
        let apiKey = SecretResolver.value(from: entry["api_key"]) ?? ""
        let model = (entry["model"] as? String) ?? ""
        let name = (entry["name"] as? String) ?? slot
        let timeout = TimeInterval((entry["timeout"] as? Int) ?? 30)
        guard !baseURL.isEmpty, !apiKey.isEmpty, !model.isEmpty else { return nil }
        return ErrorDiagnosisConfig(
            providerName: name,
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            timeout: max(timeout, 5)
        )
    }

    private func loadFromLegacyApprovalConfig() -> ErrorDiagnosisConfig? {
        guard let data = try? Data(contentsOf: legacyApprovalURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let judge = obj["judge"] as? [String: Any] else {
            return nil
        }
        let pool = judge["providers"] as? [[String: Any]] ?? []
        guard let bailian = pool.first(where: {
            let name = ($0["name"] as? String) ?? ""
            return name == "Bailian" || name.lowercased().contains("bailian") || name.contains("通义")
        }) else { return nil }
        let baseURL = SecretResolver.value(from: bailian["base_url"]) ?? ""
        let apiKey = SecretResolver.value(from: bailian["api_key"]) ?? ""
        let model = (bailian["model"] as? String) ?? "qwen3-max"
        let timeout = TimeInterval((bailian["timeout"] as? Int) ?? 30)
        guard !baseURL.isEmpty, !apiKey.isEmpty else { return nil }
        return ErrorDiagnosisConfig(
            providerName: "Bailian",
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            timeout: max(timeout, 30)
        )
    }

    func diagnose(
        errorText: String,
        onPreview: @escaping (ErrorDiagnosisResult) -> Void,
        onFinal: @escaping (Result<ErrorDiagnosisResult, Error>) -> Void
    ) {
        let trimmed = errorText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onFinal(.failure(ErrorDiagnosisError.emptyInput))
            return
        }
        guard let primary = loadPrimaryConfig() else {
            onFinal(.failure(ErrorDiagnosisError.noConfig))
            return
        }
        let preview = loadFastPreviewConfig()

        let finalLatch = NSLock()
        var finalDelivered = false
        let deliverFinal: (Result<ErrorDiagnosisResult, Error>) -> Void = { result in
            finalLatch.lock()
            let firstTime = !finalDelivered
            finalDelivered = true
            finalLatch.unlock()
            if firstTime { onFinal(result) }
        }

        let previewLatch = NSLock()
        var primaryArrived = false
        var previewDeliveredOrSkipped = false

        if let preview {
            DispatchQueue.global(qos: .userInitiated).async {
                let started = Date()
                do {
                    let answer = try Self.callAnthropic(config: preview, errorText: trimmed)
                    let elapsed = Date().timeIntervalSince(started)
                    let parsed = try Self.parseResult(
                        answer,
                        model: preview.model,
                        elapsed: elapsed,
                        isPreview: true
                    )
                    previewLatch.lock()
                    let shouldShow = !primaryArrived && !previewDeliveredOrSkipped
                    previewDeliveredOrSkipped = true
                    previewLatch.unlock()
                    if shouldShow { onPreview(parsed) }
                } catch {
                    previewLatch.lock()
                    previewDeliveredOrSkipped = true
                    previewLatch.unlock()
                }
            }
        } else {
            previewLatch.lock()
            previewDeliveredOrSkipped = true
            previewLatch.unlock()
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let started = Date()
            do {
                let answer = try Self.callAnthropic(config: primary, errorText: trimmed)
                let elapsed = Date().timeIntervalSince(started)
                let parsed = try Self.parseResult(
                    answer,
                    model: primary.model,
                    elapsed: elapsed,
                    isPreview: false
                )
                previewLatch.lock()
                primaryArrived = true
                previewLatch.unlock()
                deliverFinal(.success(parsed))
            } catch {
                deliverFinal(.failure(error))
            }
        }
    }

    private static let systemPrompt = """
    你是 API 错误诊断助手。用户会粘贴调用大模型 API 的错误返回。你必须只输出一段 JSON（从 { 到 }，不要 markdown 代码块、不要任何前后说明），结构：

    {
      "summary": "一句话结论，15-35 字。像跟非技术朋友解释。不要用'源站/代理/网关/超时窗口/鉴权'等术语。要说清楚『谁出问题了 + 大概是什么状况』。例：'中转站那头响应太慢，2 分钟没回话被自动断开了'；'你的 API 密钥被拒绝了，可能填错或过期'。",
      "provider_label": "识别问题发生在哪个服务（看 zone/host/url 字段）。简短名：easyclaude / aigocode / dragoncode / yescode / 阿里云 / 火山 / Claude 官方 / OpenAI；识别不出写'未识别'。",
      "problem_label": "≤8 字问题分类。例：524 超时 / 401 鉴权失败 / 429 限流 / 余额不足 / 模型不存在 / 网络断开。",
      "action": "≤15 字一句话建议。例：等 2 分钟再试 / 换一条线路 / 检查 API key。",
      "detail": "markdown 详细分析。1-2 句白话原因（可以用术语但要解释），再编号列出 3-5 条处理步骤。不要重复 summary。"
    }

    规则：
    - 严格只输出 JSON
    - summary 必须像在跟妈妈解释
    - 不知道就说不知道，别编错误码
    - 区分代码 bug 还是服务端问题
    """

    private static func parseResult(
        _ text: String,
        model: String,
        elapsed: TimeInterval,
        isPreview: Bool
    ) throws -> ErrorDiagnosisResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped: String = {
            if trimmed.hasPrefix("```") {
                var s = trimmed
                if let firstNL = s.firstIndex(of: "\n") {
                    s = String(s[s.index(after: firstNL)...])
                }
                if s.hasSuffix("```") {
                    s = String(s.dropLast(3))
                }
                return s.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }()
        guard let firstBrace = stripped.firstIndex(of: "{"),
              let lastBrace = stripped.lastIndex(of: "}") else {
            throw ErrorDiagnosisError.decodingFailed("返回不是 JSON：\(stripped.prefix(200))")
        }
        let jsonString = String(stripped[firstBrace...lastBrace])
        guard let data = jsonString.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ErrorDiagnosisError.decodingFailed("JSON 解析失败：\(jsonString.prefix(200))")
        }
        let summary = (obj["summary"] as? String) ?? ""
        let providerLabel = (obj["provider_label"] as? String) ?? "未识别"
        let problemLabel = (obj["problem_label"] as? String) ?? ""
        let action = (obj["action"] as? String) ?? ""
        let detail = (obj["detail"] as? String) ?? ""
        if summary.isEmpty {
            throw ErrorDiagnosisError.decodingFailed("缺少 summary 字段")
        }
        return ErrorDiagnosisResult(
            summary: summary,
            providerLabel: providerLabel,
            problemLabel: problemLabel,
            action: action,
            detail: detail,
            model: model,
            elapsed: elapsed,
            isPreview: isPreview
        )
    }

    private static func callAnthropic(config: ErrorDiagnosisConfig, errorText: String) throws -> String {
        let url = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/v1/messages")!

        let body: [String: Any] = [
            "model": config.model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": "请帮我诊断以下错误：\n\n\(errorText)"]
            ]
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = config.timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("claude-code/2.1.112", forHTTPHeaderField: "User-Agent")
        req.httpBody = bodyData

        let sem = DispatchSemaphore(value: 0)
        var resultData: Data?
        var resultResp: URLResponse?
        var resultErr: Error?

        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            resultData = data
            resultResp = resp
            resultErr = err
            sem.signal()
        }
        task.resume()
        sem.wait()

        if let err = resultErr {
            throw ErrorDiagnosisError.transport(err.localizedDescription)
        }
        guard let http = resultResp as? HTTPURLResponse, let data = resultData else {
            throw ErrorDiagnosisError.transport("无响应")
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ErrorDiagnosisError.httpError(http.statusCode, body.prefix(500).description)
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ErrorDiagnosisError.decodingFailed("响应不是 JSON")
        }
        guard let content = obj["content"] as? [[String: Any]] else {
            throw ErrorDiagnosisError.decodingFailed("缺少 content 字段：\(obj)")
        }
        let text = content.compactMap { block -> String? in
            guard (block["type"] as? String) == "text" else { return nil }
            return block["text"] as? String
        }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw ErrorDiagnosisError.decodingFailed("返回的 content 中没有 text 块")
        }
        return text
    }
}
