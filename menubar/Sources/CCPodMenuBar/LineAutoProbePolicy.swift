import Foundation

// 存量线路周期实测（第 3 层防线：防「添加时健康、中途上游挂掉」）的判定规则。
// 纯函数、无依赖，scripts/tests/test_line_auto_probe.sh 脱离 App 单测。
//
// 只在「上次实测通过 → 这次确定失败」时提醒，原因都是实测出来的：
//  - 只认 Claude Code 客户端的网关（aigocode、yescode）探测必然 403，余额耗尽的线路也必然失败——
//    从没通过过的线路一律不提醒，否则每 6 小时报一遍已知问题，提醒就没人看了；
//  - 5xx / 429 / 网络异常 / 取不到入站 key 算「拿不准」：网关重启、断网、上游抖动都长这样，
//    既不提醒也不改基线（2026-10-05 实测 yescode 某模型探测 503，同一时刻经它的真实会话正常）。
enum LineProbeVerdict: String {
    case pass, hardFail, unsure
}

enum LineAutoProbePolicy {
    /// msgs = line-check.py --probe <名称> --json 里该 provider 的消息（脚本只输出非绿消息）。
    /// 探测消息以 "probe " 开头；R = 400/401/403/404（确定性失败），Y = 其余（拿不准）。
    static func verdict(msgs: [(level: String, msg: String)]) -> LineProbeVerdict {
        let probeMsgs = msgs.filter { $0.msg.hasPrefix("probe ") }
        if probeMsgs.contains(where: { $0.level == "R" }) { return .hardFail }
        if !probeMsgs.isEmpty { return .unsure }
        // 没有探测消息：要么全部 200（绿消息被脚本滤掉），要么静态就挂了（缺 key / models 为空）没发请求。
        // 非探测的黄消息（如 [1M] 后缀提示）不影响「通了」。
        return msgs.contains(where: { $0.level == "R" }) ? .hardFail : .pass
    }

    static func shouldAlert(previous: LineProbeVerdict?, current: LineProbeVerdict) -> Bool {
        previous == .pass && current == .hardFail
    }

    /// 拿不准的结果不改基线：pass → unsure → hardFail 仍要提醒。
    static func nextBaseline(previous: LineProbeVerdict?, current: LineProbeVerdict) -> LineProbeVerdict? {
        current == .unsure ? previous : current
    }

    /// 周期实测对行内已有测通结论的处理（新结论盖旧结论，2026-10-09 线路状态审查）：
    /// - 本轮开始后用户手动测出的结论更新，不碰；
    /// - 由通转断：挂上失败（收起时的 ⚠️ 就是它）；
    /// - 已有结论的刷新成本轮结果：通了旧失败作废（原来只撤自动挂的，手动测出的旧失败会一直挂着 ⚠️），
    ///   还没通就更新时间（否则「多久以前测」停在第一次失败）；拿不准的不盖确定结论；
    /// - 没有结论的不新挂：从没通过的线路（只认 Claude Code 客户端的中转站，探测必 403）不制造 ⚠️。
    enum ResultUpdate: Equatable { case keep, showFailure, showPass }

    static func resultUpdate(alert: Bool, current: LineProbeVerdict, hasExisting: Bool, existingIsNewer: Bool) -> ResultUpdate {
        if existingIsNewer { return .keep }
        if alert { return .showFailure }
        guard hasExisting else { return .keep }
        switch current {
        case .pass: return .showPass
        case .hardFail: return .showFailure
        case .unsure: return .keep
        }
    }

    /// 一轮实测的一行总结。原来只有「5/7 通」，没通的是哪几条要逐行点开猜（2026-10-09 线路状态审查）。
    /// failed / unsure = 确定失败 / 结果不确定的线路显示名，按实测顺序。
    static func summary(passed: Int, total: Int, failed: [String], unsure: [String]) -> String {
        var parts = ["自动实测 \(passed)/\(total) 通"]
        if !failed.isEmpty { parts.append("没通：" + failed.joined(separator: "、")) }
        if !unsure.isEmpty { parts.append("结果不确定：" + unsure.joined(separator: "、")) }
        return parts.joined(separator: "，")
    }

    /// 一轮合并成一条通知。上次通过的线路「全部」同时断（≥2 条）= 多半是网关或入站 key，不是各家上游。
    static func alert(newlyFailed: [String], previouslyPassing: Int) -> (title: String, body: String)? {
        guard !newlyFailed.isEmpty else { return nil }
        let names = newlyFailed.joined(separator: "、")
        if newlyFailed.count >= 2 && newlyFailed.count == previouslyPassing {
            return ("线路全部实测失败", "\(names) 上次都通、这次同时失败——多半是本机网关或入站 key 出了问题，不是各家上游。打开 ccpod「管线」点「重新体检」看网关本体")
        }
        return ("线路实测失败：\(names)", "上次实测还通，这次确定失败（4xx）。打开 ccpod「管线」看原因，换线前别往这条线上开会话")
    }
}
