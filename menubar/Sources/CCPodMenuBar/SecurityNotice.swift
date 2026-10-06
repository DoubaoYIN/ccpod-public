import AppKit
import Foundation

/// 安装/首次启动时的风险告知 + 密钥卫生自检。
///
/// 为什么要放在 App 里而不只在 install.sh 里打印：发布给别人用时，很多人是拿 .zip 直接拖进
/// /Applications 的，根本不会跑安装脚本。风险告知必须跟着 App 走。
///
/// 文案原则（用户拍板）：**只写可核实的事实**。不编用户数，不把作者自审说成第三方审计。
enum SecurityNotice {
    private static let acceptedKey = "ccpod.securityNoticeAccepted.v1"

    // MARK: - 风险告知（只弹一次）

    static var riskText: String {
        """
        ccpod 会接触到你的线路密钥与终端，请在使用前知道这三件事：

        1. 上游线路密钥集中在网关的数据库里
           (~/.claude-code-router/config.sqlite)。这是用它做统一路由的代价：
           网关被入侵或坏更新 = 全部密钥一起暴露。这一点无法根治，只能减面
           （0600 权限、升级前备份、盲打验证）。

        2. ccpod 会读你的会话记录与进程列表
           用来显示每个对话的标题、在用模型、最后活动时间——只读，不联网、不上报、
           不把对话内容发给任何第三方模型。它也会向终端 TTY 注入命令
           （「关闭会话」「新窗口继承切线」需要）。

        3. 这个项目没有经过第三方独立安全审计
           做过 3 轮对抗性自审、修掉 17+ 项（含作者自己引入的 2 个高危），但那是自审，
           不是机构背书。它是个人项目，不公开用户数——如果你需要"很多人在用所以安全"
           这种保证，这个项目现在给不了。

        密钥现状：钥匙串是唯一权威存放点，配置文件里只有 $exec 引用；含密钥的文件
        一律 600、目录 700；落盘与回显前自动脱敏。

        随时自查（都只读）：ccdoctor ／ ccpod-key doctor ／ ccpod-key list
        """
    }

    /// 首次启动弹一次风险告知。用户点「我已了解」后记进 UserDefaults，不再打扰。
    static func presentRiskDisclosureIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: acceptedKey) else { return }
        let alert = NSAlert()
        alert.messageText = "使用 ccpod 前，请知道这三件事"
        alert.informativeText = riskText
        alert.alertStyle = .informational
        alert.addButton(withTitle: "我已了解")
        // 仓库在的话给一条通往完整威胁模型的路；发布版没有仓库就只留按钮
        let doc = Self.securityDocURL()
        if doc != nil { alert.addButton(withTitle: "打开完整安全说明") }
        alert.addButton(withTitle: "退出 ccpod")
        // 按钮序号随 doc 是否存在而变：不能写死 Third/Second，否则没有 SECURITY.md 的包里
        // 「退出 ccpod」是第二个按钮，点它会被当成"打开文档"→ 绑定失败 → 落到"已接受"，
        // 想拒绝的用户反而被记成同意了
        let quitResponse: NSApplication.ModalResponse = doc != nil ? .alertThirdButtonReturn : .alertSecondButtonReturn
        let docResponse: NSApplication.ModalResponse? = doc != nil ? .alertSecondButtonReturn : nil
        // 异步弹：runModal 会阻塞主线程直到用户点击，放在 didFinishLaunching 里同步跑
        // 会让启动卡住（菜单栏图标都不出来）。异步之后 App 正常起来、后台轮询照常，
        // 只有弹窗本身在等人点——这是一次性的告知，可以接受。
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
        let response = alert.runModal()
        if response == quitResponse {
            NSApp.terminate(nil)
            return
        }
        if let docResponse, response == docResponse, let doc {
            NSWorkspace.shared.open(doc)
        }
        UserDefaults.standard.set(true, forKey: acceptedKey)
        }
    }

    /// 完整安全说明的位置：由 build.sh 把 docs/SECURITY.md 复制进 App bundle，
    /// 所以发布版（拖进 /Applications 的 .zip）也找得到。
    /// 不写死任何人的仓库路径——那是开发机才有的东西。
    static func securityDocURL() -> URL? {
        Bundle.main.url(forResource: "SECURITY", withExtension: "md")
    }

    // MARK: - 密钥卫生自检

    struct Finding {
        let path: String
        let problem: String
    }

    /// 扫描已知会存放凭证的位置：含明文密钥的文件必须 600/400，凭证目录必须 700。
    /// 判据与 `scripts/ccdoctor.sh` 的「密钥卫生」节、`ccpod-key doctor` 完全一致，
    /// 免得三处说法不同。纯只读，不做任何修改。
    static func checkSecretHygiene() -> [Finding] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var findings: [Finding] = []
        var filesWithSecrets = 0

        let roots = ["\(home)/.claude/providers", "\(home)/.ccpod"]
        var files: [String] = []
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names {
                let path = "\(root)/\(name)"
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let lower = name.lowercased()
                guard lower.hasSuffix(".json") || lower.hasSuffix(".log") || lower.hasSuffix(".jsonl")
                        || lower.hasSuffix(".tmp") || lower.contains(".bak") else { continue }
                files.append(path)
            }
        }
        files.append("\(home)/.claude-code-router/config.sqlite")

        for path in files {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { continue }
            guard containsSecret(data) else { continue }
            filesWithSecrets += 1
            // CCR 的数据库是网关自己的库，权限对了就不算问题
            let perm = permissions(of: path)
            if perm != "600" && perm != "400" {
                findings.append(Finding(path: path, problem: "含明文密钥但权限是 \(perm)（应为 600）"))
            }
        }
        for dir in roots {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
            let perm = permissions(of: dir)
            if perm != "700" {
                findings.append(Finding(path: dir, problem: "凭证目录权限是 \(perm)（应为 700）"))
            }
        }
        if findings.isEmpty && filesWithSecrets > 0 {
            NSLog("ccpod 密钥卫生自检通过：\(filesWithSecrets) 个含密钥文件权限均合规")
        }
        return findings
    }

    private static func permissions(of path: String) -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let num = attrs[.posixPermissions] as? NSNumber else { return "?" }
        return String(format: "%o", num.intValue & 0o777)
    }

    /// 与 SecretRedactor 同一套模式：只判断"有没有"，不做替换。
    /// 用**容错解码**而不是 String(data:encoding:)：CCR 的 config.sqlite 是二进制，
    /// 严格 UTF-8 解码会整块返回 nil → 那个最该被检查的文件反而被跳过（静默失效）。
    /// 密钥本身是 ASCII，容错解码不会影响命中。只扫前 4MB，免得启动时读整个大库。
    private static func containsSecret(_ data: Data) -> Bool {
        let slice = data.count > 4_000_000 ? data.prefix(4_000_000) : data.prefix(data.count)
        let text = String(decoding: slice, as: UTF8.self)
        // 三种已知前缀。正则只能覆盖已知形状（实测漏过 cr_ 前缀，导致"0 明文"是假结论），
        // 所以字段级判据由 ccpod-key doctor 负责，这里做快速筛查
        let pattern = "sk-[A-Za-z0-9_\\-]{12,}|ark-[a-f0-9\\-]{16,}|cr_[A-Za-z0-9]{16,}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// 启动后在后台跑一次自检；有问题才打扰用户（干净时一声不响）
    static func runStartupHygieneCheck() {
        DispatchQueue.global(qos: .utility).async {
            let findings = checkSecretHygiene()
            guard !findings.isEmpty else { return }
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "ccpod 发现 \(findings.count) 处密钥卫生问题"
                alert.informativeText = findings.prefix(8).map { "· \($0.problem)\n  \($0.path)" }
                    .joined(separator: "\n")
                    + "\n\n本机其他用户或任意进程可能读得到这些密钥。\n"
                    + "一键修复：ccpod-key doctor 查看详情；chmod 600 <文件> / chmod 700 <目录> 可手工收紧。"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "知道了")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }
}
