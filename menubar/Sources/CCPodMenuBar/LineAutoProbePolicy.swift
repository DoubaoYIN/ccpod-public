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
