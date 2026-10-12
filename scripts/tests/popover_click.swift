import Foundation

final class Win { var parent: Win?; init(_ p: Win? = nil) { parent = p } }

@main struct PopoverClickTests {
    static var n = 0
    static func check(_ v: Bool, _ m: String) { n += 1; precondition(v, m) }
    static func main() {
        // 实测拓扑：状态栏窗口 ← 主弹窗 ← 线路下拉（嵌套弹窗）；另有无父窗口的菜单和普通窗口
        let statusBar = Win(), main = Win(statusBar), dropdown = Win(main), nested2 = Win(dropdown)
        let menu = Win(), other = Win()
        let fam = { (w: Win) in PopoverClickClassifier.inFamily(w, of: main) { $0.parent } }
        check(fam(main), "弹窗自己")
        check(fam(dropdown), "线路下拉是一家")
        check(fam(nested2), "两层嵌套也是一家")
        check(fam(statusBar), "宿主（图标窗口）是一家")
        check(!fam(menu) && !fam(other), "无关窗口不是一家")
        let loop = Win(); loop.parent = loop
        check(!PopoverClickClassifier.inFamily(loop, of: main) { $0.parent }, "父链成环不死循环")

        let out = PopoverClickClassifier.isOutside
        // 回归：这次事故。层级 25、不在主弹窗矩形内的子窗口，不得判外点
        check(!out(.ownApp, true, true, 25), "点线路下拉里的一行不是外点")
        check(!out(.ownApp, true, false, 101), "点菜单项不是外点")
        check(!out(.ownApp, true, false, 102), "更高的系统浮层不是外点")
        check(!out(.ownApp, false, false, 0), "认不出窗口时不算外点")
        check(out(.ownApp, true, false, 0), "本 App 其他普通窗口是外点")
        check(out(.ownApp, true, false, 25), "非一家的 25 层窗口是外点")
        check(out(.otherApp, false, false, 0), "别的 App 是外点")

        let j = SwitchOutcome.judge
        check(j(false, false, true, false) == .succeeded, "请求已消费且新 claude 在跑=成功")
        check(j(false, false, true, true) == .succeeded, "踩着超时线成功仍算成功")
        check(j(true, true, false, false) == .pending, "未超时继续等")
        check(j(true, false, true, false) == .pending, "请求没消费时，终端里有 claude 不算成功")
        check(j(true, true, false, true) == .oldSessionStillRunning, "旧会话没退")
        check(j(true, false, false, true) == .wrapperDidNotRestart, "10-10 18:59 的现场：会话没了、请求没人读")
        check(j(false, false, false, true) == .restartDidNotComeUp, "读走了但没起来")
        for o in [SwitchOutcome.oldSessionStillRunning, .wrapperDidNotRestart, .restartDidNotComeUp] {
            check(o.failureText != nil, "失败必须有话说")
        }
        check(SwitchOutcome.succeeded.failureText == nil && SwitchOutcome.pending.failureText == nil, "成功/等待不报错")
        print("popover_click: \(n) checks passed")
    }
}
