import Foundation

// LinePreflight.translate 单测：覆盖 2026-09-29 DeepSeek/百炼事故的全部死法。
// 用真实上游返回的字节构造输入（非模拟对象），断言翻译文案的正向特征。

@main struct PreflightTests {
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ label: String, _ what: String) {
        if condition {
            print("  ok   \(label)")
        } else {
            failures.append(label)
            print("  FAIL \(label) —— \(what)")
        }
    }

    static func resp(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://unit.test/v1/messages")!,
                        statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    static func main() {
        // 1. DeepSeek 事故原样：404 空 body（OpenAI 端点不认识 /v1/messages）
        let a = LinePreflight.translate(error: nil, response: resp(404), data: Data("".utf8),
                                        model: "claude-opus-5", apiKey: "sk-unit-test-key")
        expect(!a.ok, "404拦截", "空 body 404 必须被拦")
        expect(a.message.contains("不说 Anthropic 协议"), "404文案指向协议", "实际：\(a.message)")
        expect(!a.message.contains("模型"), "404不误诊为模型名", "DeepSeek 事故核心：404 被 Claude Code 翻译成模型问题，preflight 必须指向端点。实际：\(a.message)")

        // 2. 百炼事故原样：401 invalid_api_key（国内 key 配国际端点）
        let b = LinePreflight.translate(error: nil, response: resp(401),
                                        data: Data(#"{"error":{"code":"invalid_api_key","message":"invalid access token or token expired"}}"#.utf8),
                                        model: "qwen3.8-max", apiKey: "sk-sp-unit1234")
        expect(!b.ok, "401拦截", "401 必须被拦")
        expect(b.message.contains("拒绝了这把 key"), "401文案指向key", "实际：\(b.message)")
        expect(b.message.contains("不配套"), "401提示端点配套", "百炼事故核心提示。实际：\(b.message)")

        // 3. 模型名不存在：400 "Model not exist."（token-plan 实测文案）
        let c = LinePreflight.translate(error: nil, response: resp(400),
                                        data: Data(#"{"code":"InvalidParameter","message":"Model not exist."}"#.utf8),
                                        model: "claude-opus-5", apiKey: "sk-sp-unit1234")
        expect(!c.ok, "模型错拦截", "400 Model not exist 必须被拦")
        expect(c.message.contains("不认识模型"), "模型错文案", "实际：\(c.message)")

        // 4. 404 变体带模型错误文案的网关
        let c2 = LinePreflight.translate(error: nil, response: resp(404),
                                         data: Data(#"{"error":{"message":"Model Not Exist"}}"#.utf8),
                                         model: "x", apiKey: "sk-unit1234")
        expect(!c2.ok && c2.message.contains("不认识模型"), "404模型文案归模型", "实际：\(c2.message)")

        // 5. 余额不足：403 INSUFFICIENT_BALANCE（dragoncode 实测文案）
        let d = LinePreflight.translate(error: nil, response: resp(403),
                                        data: Data(#"{"code":"INSUFFICIENT_BALANCE","message":"Insufficient account balance"}"#.utf8),
                                        model: "m", apiKey: "sk-unit1234")
        expect(!d.ok && d.message.contains("余额"), "余额文案", "实际：\(d.message)")

        // 6. 正常通过 + 模型名一致
        let e = LinePreflight.translate(error: nil, response: resp(200),
                                        data: Data(#"{"id":"m1","type":"message","model":"deepseek-chat","content":[]}"#.utf8),
                                        model: "deepseek-chat", apiKey: "sk-unit1234")
        expect(e.ok, "200放行", "正常线路必须放行")
        expect(e.actualModel == "deepseek-chat", "200提取实际模型", "实际：\(String(describing: e.actualModel))")

        // 7. 200 但隐式映射（DeepSeek 把 claude 名映射到别的模型）
        let f = LinePreflight.translate(error: nil, response: resp(200),
                                        data: Data(#"{"id":"m2","type":"message","model":"deepseek-flash","content":[]}"#.utf8),
                                        model: "claude-sonnet-5", apiKey: "sk-unit1234")
        expect(f.ok, "映射也放行", "映射线路可用，应放行")
        expect(f.message.contains("实际路由到了"), "映射要明示", "隐式映射必须告知用户。实际：\(f.message)")

        // 8. 假端点：200 但返回 HTML
        let g = LinePreflight.translate(error: nil, response: resp(200),
                                        data: Data(#"<html><body>Welcome</body></html>"#.utf8),
                                        model: "m", apiKey: "sk-unit1234")
        expect(!g.ok && g.message.contains("不是 API 响应"), "假端点拦截", "实际：\(g.message)")

        // 9. 网络错误：超时
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                              userInfo: [NSLocalizedDescriptionKey: "timed out"])
        let h = LinePreflight.translate(error: timeout, response: nil, data: nil,
                                        model: "m", apiKey: "sk-unit1234")
        expect(!h.ok && h.message.contains("连不上"), "超时文案", "实际：\(h.message)")

        // 10. 脱敏：错误 body 里绝不能回显 key
        let leak = LinePreflight.translate(error: nil, response: resp(401),
                                           data: Data(#"{"error":{"message":"key sk-unit-test-key rejected"}}"#.utf8),
                                           model: "m", apiKey: "sk-unit-test-key")
        expect(!leak.message.contains("sk-unit-test-key"), "key不回显", "实际：\(leak.message)")

        print("")
        if failures.isEmpty {
            print("全部通过：LinePreflight.translate 10 组")
        } else {
            print("失败 \(failures.count) 项：\(failures.joined(separator: ", "))")
            exit(1)
        }
    }
}
