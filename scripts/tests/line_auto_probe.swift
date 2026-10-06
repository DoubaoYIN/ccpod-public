import Foundation

// LineAutoProbePolicy 单测：判定输入用 2026-10-05 实测的 line-check.py --probe --json 原样消息。

@main struct LineAutoProbeTests {
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
        typealias P = LineAutoProbePolicy
        let r403 = (level: "R", msg: #"probe yescode/claude-fable-5 → 403 {"error":{"message":"All target providers failed. [upstream_response|403] error""#)
        let y503 = (level: "Y", msg: #"probe yescode/claude-opus-5-5 → 503 {"error":{"message":"All target providers failed. [upstream_response|503] error""#)
        let yNet = (level: "Y", msg: "probe glm/glm-5 → 网络异常 <urlopen error [Errno 61] Connection refused>")
        let ySkip = (level: "Y", msg: "probe 跳过：取不到入站 key")
        let y1M = (level: "Y", msg: "['kimi-k3[1M]'] 带 [1M] 后缀 → 客户端按 1,000,000 规划上下文；服务端是否支持未验证")
        let rNoKey = (level: "R", msg: "缺 api_key（上游凭证）")

        // 判定
        expect(P.verdict(msgs: []) == .pass, "全部200=通", "glm 实测 msgs 为空")
        expect(P.verdict(msgs: [y1M]) == .pass, "静态黄提示不算失败", "[1M] 提示不应把全部 200 判成失败")
        expect(P.verdict(msgs: [r403, y503]) == .hardFail, "有4xx=确定失败", "yescode 实测 403+503 混合")
        expect(P.verdict(msgs: [y503]) == .unsure, "只有5xx=拿不准", "上游抖动不能当确定失败")
        expect(P.verdict(msgs: [yNet]) == .unsure, "网络异常=拿不准", "网关没起/断网")
        expect(P.verdict(msgs: [ySkip]) == .unsure, "取不到入站key=拿不准", "没发请求不能判")
        expect(P.verdict(msgs: [rNoKey]) == .hardFail, "静态缺key=确定失败", "没 key 的线路不能判通")

        // 提醒：只在通→确定失败
        expect(P.shouldAlert(previous: .pass, current: .hardFail), "通→断 提醒", "")
        expect(!P.shouldAlert(previous: nil, current: .hardFail), "首测就断 不提醒", "aigocode/yescode 首轮必 403，不能一装机就报")
        expect(!P.shouldAlert(previous: .hardFail, current: .hardFail), "一直断 不重复提醒", "每 6 小时报同一件事")
        expect(!P.shouldAlert(previous: .pass, current: .unsure), "通→拿不准 不提醒", "断网不报")

        // 基线：拿不准不改
        expect(P.nextBaseline(previous: .pass, current: .unsure) == .pass, "拿不准保留基线", "")
        let afterBlip = P.nextBaseline(previous: .pass, current: .unsure)
        expect(P.shouldAlert(previous: afterBlip, current: .hardFail), "通→抖→断 仍提醒", "拿不准不能吃掉后续的确定失败")
        expect(P.nextBaseline(previous: .hardFail, current: .pass) == .pass, "断→通 恢复基线", "恢复后再断要能提醒")
        expect(P.nextBaseline(previous: nil, current: .unsure) == nil, "首测拿不准 不建基线", "")

        // 合并通知
        expect(P.alert(newlyFailed: [], previouslyPassing: 3) == nil, "没新失败不发", "")
        let one = P.alert(newlyFailed: ["智谱"], previouslyPassing: 4)
        expect(one?.title.contains("智谱") == true && one?.body.contains("网关") == false, "单条失败点名线路", "实际：\(String(describing: one))")
        let all = P.alert(newlyFailed: ["智谱", "Kimi", "百炼"], previouslyPassing: 3)
        expect(all?.body.contains("网关") == true, "全部同时断指向网关", "实际：\(String(describing: all))")
        let some = P.alert(newlyFailed: ["智谱", "Kimi"], previouslyPassing: 4)
        expect(some?.body.contains("网关") == false && some?.title.contains("Kimi") == true, "部分断仍按线路报", "实际：\(String(describing: some))")

        if failures.isEmpty {
            print("PASS line_auto_probe")
        } else {
            print("FAIL line_auto_probe: \(failures.joined(separator: ", "))")
            exit(1)
        }
    }
}
