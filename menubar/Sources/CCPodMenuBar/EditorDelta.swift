import Foundation

/// 编辑窗口保存时的差量合并（纯函数，scripts/tests/test_editor_delta.sh 脱离 App 单测）。
///
/// 背景：线路编辑器和档位编辑器原来把「窗口打开时的快照」整份写回网关。窗口开着期间
/// 别处（自动上架、网关控制台、另一个窗口）的改动会在保存时被静默回滚：新加的模型被抹掉、
/// 删掉的被复活、轮换过的 key 被改回旧的。现在只把**用户在本窗口里实际改动的部分**
/// 叠加到保存那一刻新鲜读到的配置上，其余一律以新鲜配置为准；什么都没改就不写网关
/// （每次写网关都可能让正在跑的会话吃一次 502）。
enum EditorDelta {

    struct ModelsResult: Equatable {
        let write: [String]     // 要写进网关的清单
        let removed: [String]   // 本次真正删掉的（用户取消勾选、且新鲜配置里还在）
        let added: [String]     // 本次真正新增的（用户新加、且新鲜配置里还没有）
        let keptElsewhere: [String]  // 打开后别处新增、本窗口没见过、照样保留的
        var changed: Bool { !removed.isEmpty || !added.isEmpty }
    }

    /// opened = 打开时的清单；kept = 用户最终勾选保留的（含本窗口新增）；fresh = 保存时新鲜读到的。
    /// 本窗口拉取后没勾选的新行既不在 opened 也不在 kept，所以不算删除也不算新增。
    static func models(opened: [String], kept: [String], fresh: [String]) -> ModelsResult {
        let openedSet = Set(opened), keptSet = Set(kept), freshSet = Set(fresh)
        let removedByUser = openedSet.subtracting(keptSet)
        var seen = Set<String>()
        let addedByUser = kept.filter { !openedSet.contains($0) && seen.insert($0).inserted }
        var write = fresh.filter { !removedByUser.contains($0) }
        let added = addedByUser.filter { !freshSet.contains($0) }
        write.append(contentsOf: added)
        return ModelsResult(write: write,
                            removed: fresh.filter { removedByUser.contains($0) },
                            added: added,
                            keptElsewhere: fresh.filter { !openedSet.contains($0) && !keptSet.contains($0) })
    }

    /// 单值字段（地址、key）：用户改了就写用户的，没改就以新鲜配置为准。
    /// 返回 nil = 用户没改（调用方不要动这个字段）。
    static func field(opened: String, edited: String) -> String? {
        let value = edited.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == opened.trimmingCharacters(in: .whitespacesAndNewlines) ? nil : value
    }

    /// 档位：opened[key] == nil 表示打开时配置里**没有**这个值（界面上显示的只是默认的第一项）。
    /// touched = 用户在本窗口主动选过的档位。
    /// 规则：用户没碰过 → 不写（即使界面显示了默认值）；碰过且与打开时的真实值不同 → 写。
    /// 所以「未设置 → 主动选成恰好是默认显示的那一项」能写进去，「没碰」写不进去。
    static func tiers(opened: [String: String?], selected: [String: String],
                      touched: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for key in touched {
            guard let value = selected[key], !value.isEmpty else { continue }
            let original = opened[key] ?? nil
            if original != value { result[key] = value }
        }
        return result
    }

    /// 要写进档位的模型里，保存时新鲜配置已经没有的（写进去网关会静默转给别家，PITFALLS #43）。
    static func missing(_ changed: [String: String], options: Set<String>) -> [String] {
        changed.values.filter { !options.contains($0) }.sorted()
    }
}
