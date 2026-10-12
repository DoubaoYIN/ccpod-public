import Foundation

/// 「弹窗外点击」与「切线结果」两处的纯判定。只放纯函数，单测见 scripts/tests/popover_click.swift。

/// 外点判定（2026-10-10 修正 #265 兜底的误关）。
///
/// 第一性原理：外点 = 点击目标**不属于弹窗自己的界面树**。界面树是结构事实（窗口父子链），
/// 几何（落没落在弹窗矩形里）和层级数值都只是它的代理量，而且这两个代理量在本机实测都是错的：
///   · 线路下拉是 SwiftUI `.popover`，是挂在主弹窗下面的**独立子窗口**，矩形在主弹窗之外；
///   · 状态栏弹窗的窗口层级是 25，不是 popUpMenu 的 101。
/// 旧实现用「矩形 + 层级==101」判定，于是点线路下拉里的一行就被当成外点，0.4s 后关掉主弹窗。
///
/// 失效方向：判不准一律算「不是外点」。漏关还有系统 transient 监视器和下一次点击兜着，
/// 误关则是直接打断用户正在做的事。
enum PopoverClickClassifier {
    /// NSWindow.Level.popUpMenu.rawValue。菜单窗口没有父窗口可循，只能认层级；用 >= 兼容更高的系统浮层。
    static let menuWindowLevel = 101

    enum Source {
        case otherApp   // 全局监视器：点击落在别的 App，本 App 收不到窗口
        case ownApp     // 本地监视器：点击落在本 App 的某个窗口
    }

    static func isOutside(source: Source, hasWindow: Bool, inPopoverFamily: Bool, windowLevel: Int) -> Bool {
        switch source {
        case .otherApp:
            return true
        case .ownApp:
            guard hasWindow else { return false }                      // 认不出目标：不算外点
            if inPopoverFamily { return false }                        // 弹窗自己、它的子窗口、它的宿主
            if windowLevel >= menuWindowLevel { return false }         // 菜单：这一下归菜单
            return true                                                // 本 App 的其他普通窗口
        }
    }

    /// `window` 是不是 `popover` 的一家人：本身、后代（嵌套弹窗）、或祖先（状态栏图标窗口，
    /// 图标点击由 togglePopover 自己处理）。`parent` 注入便于单测；深度封顶防环。
    static func inFamily<W: AnyObject>(_ window: W, of popover: W, parent: (W) -> W?) -> Bool {
        if window === popover { return true }
        var cur = parent(window), depth = 0
        while let w = cur, depth < 32 { if w === popover { return true }; cur = parent(w); depth += 1 }
        cur = parent(popover); depth = 0
        while let w = cur, depth < 32 { if w === window { return true }; cur = parent(w); depth += 1 }
        return false
    }
}

/// 切线结果判定（2026-10-10）。
///
/// 切线是「写请求 → 杀旧 claude → 包装脚本读请求 → 重启」的接力，第一步就不可逆，
/// 而发起方（菜单栏）以前发完信号就不管了：中间任何一棒掉了都没有任何提示，
/// 用户只看到会话没了。发起者必须自己确认结果。
enum SwitchOutcome: Equatable {
    case succeeded              // 请求已被消费，且该终端里跑着一个新的 claude
    case pending                // 还在路上，继续等
    case oldSessionStillRunning // 超时：旧 claude 没退出
    case wrapperDidNotRestart   // 超时：旧 claude 退了，但请求文件没人读
    case restartDidNotComeUp    // 超时：请求被读走了，但新 claude 没起来

    static func judge(requestFileExists: Bool, oldClaudeAlive: Bool, newClaudeOnTTY: Bool,
                      timedOut: Bool) -> SwitchOutcome {
        if !requestFileExists && newClaudeOnTTY { return .succeeded }
        guard timedOut else { return .pending }
        if oldClaudeAlive { return .oldSessionStillRunning }
        if requestFileExists { return .wrapperDidNotRestart }
        return .restartDidNotComeUp
    }

    var failureText: String? {
        switch self {
        case .succeeded, .pending: return nil
        case .oldSessionStillRunning: return "旧会话 25 秒内没有退出，切换请求已撤销。它若稍后自己退出，不会自动重启。"
        case .wrapperDidNotRestart: return "旧会话已退出，但启动脚本没有接手重启。"
        case .restartDidNotComeUp: return "已开始重启，但新会话没有起来，请看该终端窗口里的报错。"
        }
    }
}
