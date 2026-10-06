import AppKit

// 程序坞图标：平时是纯菜单栏 App（accessory，不占程序坞）；
// 只要开着带标题栏的窗口（管线管理、项目管理、测速……）就切到 regular——程序坞里能看到、⌘Tab 能切回，
// 窗口全关再退回 accessory。集中监听窗口通知，不用每个 show*Window 各写一遍。
enum DockPresence {
    static func install() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { _ in
            update(closing: nil)
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            // willClose 时窗口还算可见，要显式排除它
            update(closing: note.object as? NSWindow)
        }
    }

    /// 弹窗面板（NSPopover 的私有窗口）、提示框（NSPanel）、菜单栏按钮窗口都不算
    static func isAppWindow(_ window: NSWindow) -> Bool {
        (window.isVisible || window.isMiniaturized)
            && window.styleMask.contains(.titled)
            && !(window is NSPanel)
            && !String(describing: type(of: window)).contains("Popover")
    }

    private static func update(closing: NSWindow?) {
        let hasWindow = NSApp.windows.contains { $0 !== closing && isAppWindow($0) }
        let wanted: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        NSApp.setActivationPolicy(wanted)
        // 切到 regular 会把 App 打成非激活，窗口沉到后面；补一次激活
        if hasWindow { NSApp.activate(ignoringOtherApps: true) }
    }
}
