import Foundation

// LineCheckFixPolicy — 体检合成行（网关本体 / settings.json）的「去哪修」。
// 纯逻辑、只依赖 Foundation，方便 scripts/tests/test_line_check_fix.sh 单独编译。
//
// 输入必须是 line-check.py 的**原始消息**：展示用的 gatewayVisibleText 会把 "CCR" 不分大小写换成「网关」，
// 连命令里的 com.matthew.ccr-gateway / ccr start 也一起换掉，照抄必失败。
//
// 做不到真跳转的问题一律给 .none（只有说明），不做假按钮；认不出的新消息同样给 .none。

enum LineCheckFix: Equatable {
    /// 把这条命令放进剪贴板，由用户自己到终端执行（CCPod 不代为执行系统级操作）
    case copyCommand(String)
    case openGatewayConsole
    /// 在访达里选中这个文件（绝对路径）。CCPod 不替用户改：settings.json 只许网关 daemon 写
    case revealFile(String)
    case none
}

struct LineCheckFixAdvice: Equatable {
    let fix: LineCheckFix
    /// 大白话说明：这是什么问题、按钮会干什么（或者为什么没有按钮）
    let hint: String
}

enum LineCheckFixPolicy {
    static let gatewayBlock = "check:gateway"
    static let settingsBlock = "check:settings"

    /// 用来认问题类型的短语，全部是 line-check.py 消息里的原文。
    /// 单测会断言每一条都还在脚本里出现（脚本改措辞 → 测试失败，而不是界面上悄悄没了按钮）。
    enum Phrase {
        static let gatewayDown = "网关不在（"   // 带括号：「LaunchAgent 不存在：重启电脑后网关不在」也含"网关不在"
        static let blindOpen = "竟然 200"
        static let requestLogs = "requestLogs=true"
        static let blindOtherCode = "（预期 401）"
        static let blindNetwork = "盲打测试网络异常"
        static let noLaunchAgent = "LaunchAgent 不存在"
        static let noInboundKey = "取不到入站 key"
        static let settingsOldProxy = "仍指向已退役的 15721"
        static let settingsMissing = "settings.json 缺 "
        static let all = [gatewayDown, blindOpen, requestLogs, blindOtherCode, blindNetwork,
                          noLaunchAgent, noInboundKey, settingsOldProxy, settingsMissing]
    }

    /// 「网关不在」消息里自带的两条启动命令的原文形态；单测同样断言它还在脚本里。
    /// 第一条命令里有空格（gui/$(id -u)/…），不能用 \S+ 取。
    static let startCommandPattern = #"：(launchctl kickstart .+?) 或 (ccr start --daemon)"#

    static func advice(block: String, rawMessage msg: String,
                       settingsPath: String = NSString(string: "~/.claude/settings.json").expandingTildeInPath)
        -> LineCheckFixAdvice {
        switch block {
        case gatewayBlock:
            if msg.contains(Phrase.gatewayDown) {
                guard let command = startCommand(from: msg) else {
                    return LineCheckFixAdvice(fix: .none, hint: "网关没在运行。体检没给出可用的启动命令，CCPod 这里没有对应的修复入口。")
                }
                return LineCheckFixAdvice(fix: .copyCommand(command),
                                          hint: "网关没在运行。把下面这条命令粘到终端里执行，再点「重新体检」。")
            }
            if msg.contains(Phrase.blindOpen) {
                return LineCheckFixAdvice(fix: .openGatewayConsole,
                                          hint: "网关没有拦住不带钥匙的请求，等于谁都能用你的额度。到网关控制台把入站鉴权打开。")
            }
            if msg.contains(Phrase.requestLogs) {
                return LineCheckFixAdvice(fix: .openGatewayConsole,
                                          hint: "网关正在把对话全文写进磁盘。到网关控制台把请求日志关掉。")
            }
            if msg.contains(Phrase.blindOtherCode) {
                return LineCheckFixAdvice(fix: .none,
                                          hint: "网关拒绝了不带钥匙的请求，只是返回码不是预期的 401。这里没有可调的设置，过一会儿重新体检看看还在不在。")
            }
            if msg.contains(Phrase.blindNetwork) {
                return LineCheckFixAdvice(fix: .none, hint: "这一项这次没测成（网络异常），不代表有问题。重新体检一次。")
            }
            if msg.contains(Phrase.noLaunchAgent) {
                return LineCheckFixAdvice(fix: .none,
                                          hint: "开机自启没装，重启电脑后网关不会自己起来。它由网关那边的安装流程负责，CCPod 里没有安装入口。")
            }
            if msg.contains(Phrase.noInboundKey) {
                return LineCheckFixAdvice(fix: .none,
                                          hint: "体检取不到网关的入站钥匙，所以没法做真实探测。CCPod 里没有对应的修复入口。")
            }
        case settingsBlock:
            if msg.contains(Phrase.settingsOldProxy) {
                return LineCheckFixAdvice(fix: .revealFile(settingsPath),
                                          hint: "settings.json 还指着已经停用的旧代理。这个文件只由网关改写，CCPod 不替你改；先打开确认一下内容。")
            }
            if msg.contains(Phrase.settingsMissing) {
                return LineCheckFixAdvice(fix: .revealFile(settingsPath),
                                          hint: "settings.json 里少了共用的配置项，多半是被别的工具覆盖了。CCPod 不替你改；先打开确认一下内容。")
            }
        default:
            break
        }
        return LineCheckFixAdvice(fix: .none, hint: "这是 CCPod 还不认识的检查项，暂时没有对应的修复入口。")
    }

    /// 给界面看的消息：把启动命令那一段拿掉（命令由复制按钮原样提供，不经过展示用的文字替换）。
    static func messageWithoutCommand(_ msg: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: startCommandPattern) else { return msg }
        return regex.stringByReplacingMatches(in: msg, range: NSRange(msg.startIndex..., in: msg), withTemplate: "")
    }

    /// 从原始消息里取启动命令：先试 launchctl，失败再试 ccr 自己的启动。取不出来返回 nil（宁可没按钮，不给错命令）。
    static func startCommand(from msg: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: startCommandPattern),
              let match = regex.firstMatch(in: msg, range: NSRange(msg.startIndex..., in: msg)),
              match.numberOfRanges == 3,
              let first = Range(match.range(at: 1), in: msg),
              let second = Range(match.range(at: 2), in: msg) else { return nil }
        return "\(msg[first]) || \(msg[second])"
    }
}

// 演示数据入口：只给实机走查用。真实条件（停网关、删自启、改 settings.json）会伤到正在跑的会话。
enum LineCheckFixture {
    static let envKey = "CCPOD_LINECHECK_FIXTURE"

    /// 变量不存在或为空 → nil（走真实体检，行为与没有这个入口时完全一样）。
    static func path(in env: [String: String]) -> String? {
        guard let value = env[envKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return NSString(string: value).expandingTildeInPath
    }

    static func label(_ name: String) -> String { "\(name)（演示数据）" }
}
