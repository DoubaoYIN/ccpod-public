import Foundation

// EditorDelta 单测：编辑窗口保存时的差量合并（窗口开着期间别处的改动不能被回滚）。
// 夹具里的 key 全是假值。

@main
struct EditorDeltaTests {
    static var failures = 0
    static var groups = 0
    static func expect(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String) {
        groups += 1
        if !cond { failures += 1; print("✗ \(name)：\(detail())") }
    }

    static func main() {
        typealias D = EditorDelta

        // 1. 别处新增 W：用户只删了 A → W 必须保留
        let r1 = D.models(opened: ["A", "B"], kept: ["B"], fresh: ["A", "B", "W"])
        expect(r1.write == ["B", "W"], "别处新增 W 被抹掉", "实际 write=\(r1.write)")
        expect(r1.removed == ["A"] && r1.added.isEmpty && r1.keptElsewhere == ["W"] && r1.changed,
               "删除/别处新增记账", "实际 \(r1)")

        // 2. 打开时有 Z、别处已删、用户没动 → 不复活
        let r2 = D.models(opened: ["A", "Z"], kept: ["A", "Z"], fresh: ["A"])
        expect(!r2.write.contains("Z"), "Z 被复活", "实际 write=\(r2.write)")
        expect(!r2.changed, "Z 别处删了用户没动 = 无改动", "实际 \(r2)")

        // 3. 用户删 X、别处也删了 X → no-op
        let r3 = D.models(opened: ["A", "X"], kept: ["A"], fresh: ["A"])
        expect(r3.write == ["A"] && r3.removed.isEmpty && !r3.changed, "双方都删 X", "实际 \(r3)")

        // 4. 用户加 Y、别处也加了 Y → 不重复
        let r4 = D.models(opened: ["A"], kept: ["A", "Y"], fresh: ["A", "Y"])
        expect(r4.write == ["A", "Y"] && r4.added.isEmpty && !r4.changed, "双方都加 Y", "实际 \(r4)")

        // 5. 用户新增 N（别处没有）→ 追加到末尾，保持新鲜顺序
        let r5 = D.models(opened: ["A", "B"], kept: ["B", "A", "N"], fresh: ["B", "A"])
        expect(r5.write == ["B", "A", "N"] && r5.added == ["N"] && r5.changed, "新增追加且保序", "实际 \(r5)")

        // 6. 本窗口拉取后没勾选的新行既不在 opened 也不在 kept → 不算删除
        let r6 = D.models(opened: ["A"], kept: ["A"], fresh: ["A"])
        expect(r6.removed.isEmpty && !r6.changed, "未勾选新行不算删除", "实际 \(r6)")

        // 7. 全删 → write 为空（调用方据此拒绝保存）
        let r7 = D.models(opened: ["A"], kept: [], fresh: ["A"])
        expect(r7.write.isEmpty && r7.removed == ["A"], "全删得空清单", "实际 \(r7)")

        // 8. field：没改 → nil（以新鲜配置为准）；改了 → 新值（去首尾空白）
        expect(D.field(opened: "sk-fake-old", edited: " sk-fake-old ") == nil, "key 没改不写", "应为 nil")
        expect(D.field(opened: "sk-fake-old", edited: "sk-fake-new") == "sk-fake-new", "key 改了写新值", "应为新值")
        expect(D.field(opened: "https://a.example", edited: "https://b.example/") == "https://b.example/", "地址改了写新值", "应为新值")

        // 9. tiers：没碰 → 不写，即使界面显示了默认第一项（opened 为 nil = 配置里没设置）
        let opened: [String: String?] = ["model": "yescode/claude-opus-5-5", "haikuModel": String?.none]
        let shown = ["model": "yescode/claude-opus-5-5", "haikuModel": "dragoncode/claude-fable-5"]
        expect(D.tiers(opened: opened, selected: shown, touched: []).isEmpty, "未设置档位没碰却被写", "应为空")
        // 10. 未设置 → 用户主动选了恰好是默认显示的那一项 → 必须能写进去
        let t10 = D.tiers(opened: opened, selected: shown, touched: ["haikuModel"])
        expect(t10 == ["haikuModel": "dragoncode/claude-fable-5"], "主动选默认项写不进", "实际 \(t10)")
        // 11. 碰了但值和打开时一样 → 不写
        expect(D.tiers(opened: opened, selected: shown, touched: ["model"]).isEmpty, "选回原值不写", "应为空")
        // 12. 碰了且改了 → 只写这一档
        let t12 = D.tiers(opened: opened, selected: ["model": "glm/glm-5.3", "haikuModel": "dragoncode/claude-fable-5"],
                          touched: ["model"])
        expect(t12 == ["model": "glm/glm-5.3"], "只写改过的档", "实际 \(t12)")

        // 13. missing：选的模型保存时已不在网关清单 → 点名
        expect(D.missing(["model": "yescode/claude-gone"], options: ["yescode/claude-opus-5-5"]) == ["yescode/claude-gone"],
               "已删模型拦下", "应点名 claude-gone")
        expect(D.missing(["model": "yescode/claude-opus-5-5"], options: ["yescode/claude-opus-5-5"]).isEmpty,
               "仍在清单不拦", "应为空")

        if failures == 0 {
            print("全部通过：EditorDelta \(groups) 组")
        } else {
            print("失败 \(failures) 项"); exit(1)
        }
    }
}
