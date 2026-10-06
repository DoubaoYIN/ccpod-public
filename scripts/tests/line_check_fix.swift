import Foundation

// LineCheckFixPolicy 单测：输入是 ~/.claude/bin/line-check.py 各检查项产出的消息原文（f-string 已代入样例值）。

@main struct LineCheckFixTests {
    static var failures: [String] = []

    static func expect(_ condition: Bool, _ label: String, _ what: String) {
        if condition {
            print("  ok   \(label)")
        } else {
            failures.append(label)
            print("  FAIL \(label) —— \(what)")
        }
    }

    static func main() {
        typealias P = LineCheckFixPolicy
        let settings = "/Users/demo/.claude/settings.json"
        func advice(_ block: String, _ msg: String) -> LineCheckFixAdvice {
            P.advice(block: block, rawMessage: msg, settingsPath: settings)
        }

        // —— 网关不在：复制的命令必须是原文，不能被展示用的「CCR→网关」替换改坏 ——
        let down = "网关不在（http://127.0.0.1:3456）：launchctl kickstart gui/$(id -u)/com.matthew.ccr-gateway 或 ccr start --daemon (<urlopen error [Errno 61] Connection refu)"
        let downAdvice = advice(P.gatewayBlock, down)
        if case .copyCommand(let command) = downAdvice.fix {
            expect(command.contains("com.matthew.ccr-gateway"), "网关不在→命令含服务名原文 com.matthew.ccr-gateway", command)
            expect(command.contains("ccr start --daemon"), "网关不在→命令含 ccr start --daemon 原文", command)
            expect(command == "launchctl kickstart gui/$(id -u)/com.matthew.ccr-gateway || ccr start --daemon",
                   "网关不在→整条命令逐字相符（先 launchctl，失败再 ccr）", command)
            expect(!command.contains("网关"), "网关不在→命令里没有被替换进去的「网关」二字", command)
        } else {
            expect(false, "网关不在→动作是复制命令", "\(downAdvice.fix)")
        }
        let shown = P.messageWithoutCommand(down)
        expect(shown == "网关不在（http://127.0.0.1:3456） (<urlopen error [Errno 61] Connection refu)",
               "网关不在→给界面看的消息去掉了命令段", shown)
        expect(P.messageWithoutCommand("requestLogs=true：会把全部对话正文写盘") == "requestLogs=true：会把全部对话正文写盘",
               "没有命令的消息→原样不动", "")
        let downNoCommand = advice(P.gatewayBlock, "网关不在（http://127.0.0.1:3456）：请手动启动")
        expect(downNoCommand.fix == .none, "网关不在但取不出命令→不给按钮（宁可没有也不给错的）", "\(downNoCommand.fix)")

        // —— 有真落点的 ——
        expect(advice(P.gatewayBlock, "无 key 盲打 /v1/messages 竟然 200 —— 入站鉴权失效，网页可盲打扣费！").fix == .openGatewayConsole,
               "盲打 200→打开网关控制台", "")
        expect(advice(P.gatewayBlock, "requestLogs=true：会把全部对话正文写盘（pitfalls），立即关闭").fix == .openGatewayConsole,
               "requestLogs=true→打开网关控制台", "")
        expect(advice(P.settingsBlock, "settings.json 仍指向已退役的 15721").fix == .revealFile(settings),
               "settings 指向 15721→在访达显示 settings.json", "")
        let missing = advice(P.settingsBlock, "settings.json 缺 ['hooks', 'apiKeyHelper']")
        expect(missing.fix == .revealFile(settings), "settings 缺字段→在访达显示 settings.json", "\(missing.fix)")
        let defaultPath = P.advice(block: P.settingsBlock, rawMessage: "settings.json 仍指向已退役的 15721")
        if case .revealFile(let path) = defaultPath.fix {
            expect(path.hasPrefix("/") && path.hasSuffix("/.claude/settings.json"), "默认路径是绝对路径且以 /.claude/settings.json 结尾", path)
        } else {
            expect(false, "默认路径→显示文件", "\(defaultPath.fix)")
        }

        // —— 确实没有落点的：不给按钮，但说明不能为空 ——
        let noTarget = [
            ("盲打返回非 401", "无 key 盲打返回 403（预期 401）"),
            ("盲打网络异常", "盲打测试网络异常 timed out"),
            ("LaunchAgent 不存在", "LaunchAgent 不存在：重启电脑后网关不在"),
            ("取不到入站 key", "取不到入站 key（钥匙串 ccr-key-daily / claude-code-apikey-fun），--probe 将跳过"),
            ("未知新消息", "某个以后才会加的检查没过"),
        ]
        var hints = Set<String>()
        for (label, msg) in noTarget {
            let a = advice(P.gatewayBlock, msg)
            expect(a.fix == .none, "\(label)→不给按钮", "\(a.fix)")
            expect(!a.hint.isEmpty, "\(label)→有说明文字", "")
            hints.insert(a.hint)
        }
        expect(hints.count == noTarget.count, "五种无落点情况的说明各不相同（没有串到别人的说明上）", "\(hints.count)")
        expect(advice(P.gatewayBlock, "LaunchAgent 不存在：重启电脑后网关不在").hint.contains("开机自启"),
               "LaunchAgent 那条含「网关不在」四个字，但没被当成网关不在", "")
        expect(advice("check:other", down).fix == .none, "不认识的检查块→不给按钮", "")
        expect(advice(P.settingsBlock, down).fix == .none, "网关的消息出现在 settings 块→不给按钮", "")

        // —— 演示数据入口：变量不存在就等于没有这个入口 ——
        expect(LineCheckFixture.path(in: [:]) == nil, "没有 CCPOD_LINECHECK_FIXTURE→nil（走真实体检）", "")
        expect(LineCheckFixture.path(in: ["CCPOD_LINECHECK_FIXTURE": ""]) == nil, "变量为空串→nil", "")
        expect(LineCheckFixture.path(in: ["CCPOD_LINECHECK_FIXTURE": "  \n"]) == nil, "变量只有空白→nil", "")
        expect(LineCheckFixture.path(in: ["OTHER": "/tmp/x.json"]) == nil, "别的变量→nil", "")
        expect(LineCheckFixture.path(in: ["CCPOD_LINECHECK_FIXTURE": "/tmp/x.json"]) == "/tmp/x.json", "变量有值→就是那个路径", "")
        expect(LineCheckFixture.label("网关本体") == "网关本体（演示数据）", "演示数据的行名带标记", "")

        // —— 防漂移：识别用的短语必须还在体检脚本里（脚本改了措辞要在这里红，而不是界面上悄悄没按钮）——
        let scriptPath = ProcessInfo.processInfo.environment["LINE_CHECK_PY"]
            ?? NSString(string: "~/.claude/bin/line-check.py").expandingTildeInPath
        if let script = try? String(contentsOfFile: scriptPath, encoding: .utf8) {
            print("  （防漂移对照：\(scriptPath)，\(script.count) 字符）")
            for phrase in P.Phrase.all {
                expect(script.contains(phrase), "脚本里还有短语「\(phrase)」", "在 \(scriptPath) 里找不到")
            }
            expect(P.startCommand(from: script) == "launchctl kickstart gui/$(id -u)/com.matthew.ccr-gateway || ccr start --daemon",
                   "脚本里的启动命令还是这个形态", "\(P.startCommand(from: script) ?? "取不出")")
        } else {
            expect(false, "读得到体检脚本", "\(scriptPath) 不存在或读不了——防漂移没法做，不能当通过")
        }

        if failures.isEmpty {
            print("line_check_fix: 全部通过")
        } else {
            print("line_check_fix: \(failures.count) 项失败")
            exit(1)
        }
    }
}
