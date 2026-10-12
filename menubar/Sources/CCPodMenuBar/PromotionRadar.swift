import Foundation
import CryptoKit

// 优惠雷达 P0 的 Swift 侧地基（计划 Task 5）：
// 1) 与 scripts/promo-fetch.py stdout 一一对应的数据模型 + 解码；
// 2) 情报快照 / 提醒层状态的落盘（600 权限、落盘前脱敏）；
// 3) 读盘后按「今天」重算条目三态。
// 只 import Foundation 与 CryptoKit（都是系统框架、无第三方依赖），可脱离 App
// 与 SecretResolver.swift 一起走 swiftc 测试通道。
// 🔴 2026-10-10 加 CryptoKit 时**实测过**这条通道，不是只看「编过了」：裸 swiftc
//   （不带 -sdk、不带 Package.swift）能解析 CryptoKit，且 SHA256("abc") 与公认值
//   逐字符相符、摘要长度 64。编过但算错的话，指纹键会静默变成另一种东西——
//   而 `test_promotion_store.sh:7-8` 原先只声明过「SecretResolver.swift 只 import
//   Foundation，实测可独立编译」，CryptoKit 是这次新验的。

// MARK: - 枚举

/// 情报类别。**分级对待是硬约束**（spec §0.2）：
/// A 类 `peakValley` 有官方页逐字依据 → 可以弹通知；
/// B 类 `limitedTime` 常见于第三方转述、资格受限 → 只进面板 + ⚠️，**永不弹通知**。
///
/// 🔴 B 类的线上值是 "promotion"，不是 "limited_time"（2026-10-10 逐处取证）：
/// promo-fetch.py 的 load_rules 白名单是 ("peak_valley", "promotion")，parse_page
/// 漏写 class 的默认值也是 "promotion"，Task 4 测试 test_promo_fetch.py 已把它钉死。
/// 实现计划原稿此处曾写 `limitedTime = "limited_time"`，与 Python 契约不符——
/// 照抄会让任何 B 类条目令**整个**解码失败（Codable 枚举遇未知 raw value 直接 throw，
/// 一条坏条目连坐全部页）。Swift 侧保留计划里的语义命名 `limitedTime`，
/// raw value 以 Python 真会吐出的形状为准。若将来契约迁移（文档改成 limited_time），
/// 这里必须与 promo-fetch.py 白名单**同笔**改，两侧任何一侧单独改都会在解码层炸出
/// 可见失败——那是设计行为，别改成静默兼容。
enum PromotionKind: String, Codable {
    case peakValley = "peak_valley"
    case limitedTime = "promotion"
}

/// 条目级三态。与页级四态是**两层不同的东西**，不要混用一个字段（spec §4.2）。
enum PromotionStatus: String, Codable {
    case active
    case upcoming
    case expired
}

/// 页级四态。核心不变量：每一种「空」都有自己的名字。
enum PromotionPageStatus: String, Codable {
    case ok
    case fetchFailed = "fetch-failed"
    case unsupportedJSPage = "unsupported-js-page"
    case parseFailed = "parse-failed"
}

// MARK: - 模型（字段与 scripts/promo-fetch.py 的输出一一对应）

// ══════════════════════════════════════════════════════════════════════════
// 字段来源表（2026-10-10 逐字段对照 promo-fetch.py 取证；脱敏边界的唯一依据）
//
// 「页面派生」= 值（或其成分）来自被抓页面的正文 / 正则捕获 / 服务端响应文本
//              → 解码边界（PromotionScriptRunner.decode）必须脱敏；
// 「我们自己的」= 值只来自 manifest / 规则文件 / 脚本内固定字面量 → 不脱敏。
// 所有结构体字段都是 let（status 等重算字段除外），脱敏只能**重建**（redacted()）。
//
// ─ 页级（PromotionPageResult / PromotionPage，线上 12 键）─────────────────
//  line                        我们自己的：manifest
//  url                        🔴 用户输入派生：manifest 只是**转述**用户在 Task 9
//                             「管线管理」输入框手填的值，可能带 ?api_key=sk-…
//                             → 解码边界脱敏 + save() 二遍脱敏。2026-10-10 复审
//                             改判（原判「我们自己的：manifest 配置」错在把用户
//                             手填当成我们的；依据 spec §3.2 + 计划 :5571 的用户
//                             文案。本表自称「脱敏边界的唯一依据」，错一条即整个
//                             边界错一条，改判留痕，不许悄悄改）
//  status                     我们自己的：page_status 的四个字面量（枚举）
//  error                      🔴 页面派生：exc.reason + 错误页 body 摘要 + 异常
//                             消息，服务端可控文本（反爬/网关可把 Authorization
//                             回显进去）→ 解码边界脱敏 + save() 二层脱敏
//  note                       我们自己的：仅两个字面量（"no-rule-matched-url" /
//                             "rule-matched-no-hit"，status_note）。⚠️ 今天安全
//                             不等于将来安全：写进本表就是为了让「没提到」≠「没看过」。
//  fingerprint                我们自己的：sha256: + 64 hex（脚本自算）。unchanged
//                             判定靠它逐字比对，脱敏会弄坏去重 → **保留原样**
//  http_status / bytes / visible_chars / truncated / unchanged
//                             非字符串，脚本自算
//
// ─ 条目级（Promotion，线上 16 键）────────────────────────────────────────
//  id                         混合：rule_id（我们的规则文件）+ "-" + family
//                             （🔴 页面派生：页面 model 名按 [-.] 切的第一段，
//                             family_labels 兜底时整段进 title）→ 脱敏
//  line                       我们自己的：manifest
//  class(kind)                我们自己的：规则文件（枚举）
//  title                      🔴 含页面派生成分：window start/end（页面正则捕获）
//                             + family 回退标签 + short → 脱敏
//  vendor / eligibility       我们自己的：规则文件
//  models                     🔴 页面派生：每个 model 名都是页面正则捕获 → 逐个脱敏
//  window.tz / window.days    我们自己的：规则 spec 默认值 → 不脱敏
//  window.start / window.end  🔴 页面派生：正则捕获后过 normalize_hhmm → 脱敏
//  window.ends_next_day       我们自己的：规则 spec（bool）
//  discount.text / .short     我们自己的模板 + 页面派生**数字**（%g 渲染）；
//                             无页面自由文本通路 → 不脱敏（ratio 本身是 Double，
//                             数字无从脱敏，只脱它的字符串渲染没有意义）
//  valid_from / valid_until   🔴 页面派生：正则捕获的日期（valid_until 当前恒
//                             null，按契约一并脱敏，防将来接上时漏）
//  source.url                 🔴 用户输入派生：同页级 url（用户手填，spec §3.2
//                             点名字段）→ 脱敏（2026-10-10 复审改判，同页级 url 条）
//  source.fetched_at          我们自己的：脚本生成的时间戳
//  source.official / verified / status   我们算的（bool / 枚举三字面量）
//  evidence                   🔴 页面派生：正文**逐字子串**（EVIDENCE_MAX_CHARS=200
//                             只做前缀截短，仍是逐字）。⚠️ 脱敏会破坏「逐字」性质，
//                             但只有密钥形状的串会被替换——公开定价页里不该出现密钥，
//                             出现即是泄漏，宁可破坏逐字也要 mask（过度脱敏的代价，
//                             已知情接受，别让后人再纠结一遍）。
//  extractor                  我们自己的："rule:" + 规则 id
// ══════════════════════════════════════════════════════════════════════════

struct PromotionWindow: Codable, Equatable {
    let tz: String
    let start: String
    let end: String
    let days: [String]
    /// 窗口跨午夜（22:00–次日 08:00）。倒计时算错通常就是漏了这条。
    let endsNextDay: Bool

    enum CodingKeys: String, CodingKey {
        case tz, start, end, days
        case endsNextDay = "ends_next_day"
    }

    /// 解码边界脱敏：start / end 是页面正则捕获（normalize_hhmm 后的钟点串）；
    /// tz / days / endsNextDay 来自我们的规则 spec，原样保留。
    func redacted() -> PromotionWindow {
        PromotionWindow(tz: tz,
                        start: SecretRedactor.redact(start),
                        end: SecretRedactor.redact(end),
                        days: days,
                        endsNextDay: endsNextDay)
    }
}

struct PromotionDiscount: Codable, Equatable {
    /// 折扣不统一时为 nil。**宁可少说一句，也不说一个错的数字。**
    let ratio: Double?
    let text: String
    let short: String?
    // 无 redacted()：text / short 是我们的模板 + 页面派生数字（见字段来源表），
    // 没有页面自由文本通路；ratio 是 Double 更无从脱敏。
}

struct PromotionSource: Codable, Equatable {
    /// 🔴 用户输入派生：manifest 里的 url 是用户在「管线管理」输入框（Task 9）手填的，
    /// 可能带 `?api_key=sk-…`（spec §3.2；计划 :5571 的用户文案也承诺了落盘前脱敏）。
    /// 曾经的注释说「三个字段全部来自我们的 manifest」——那句是错的：manifest 只是
    /// 转述，不是来源。2026-10-10 复审改判，见文件头字段来源表。
    let url: String
    /// 脚本生成的时间戳，无用户/页面自由文本通路 → 原样。
    let fetchedAt: String
    /// 我们算的 bool → 原样。
    let official: Bool

    enum CodingKeys: String, CodingKey {
        case url, official
        case fetchedAt = "fetched_at"
    }

    /// url 过 SecretRedactor；fetchedAt / official 无泄漏通路，原样保留。
    func redacted() -> PromotionSource {
        PromotionSource(url: SecretRedactor.redact(url),
                        fetchedAt: fetchedAt,
                        official: official)
    }
}

/// ⚠️ **故意不 conform `Identifiable`**：`id` 在数组里不唯一（见下），
/// 一旦 conform 了，`ForEach(promotions)` 就能编译通过、然后在运行时打
/// "Multiple children have the same identity" 且渲染行为未定义。
/// 去掉 conformance 把它变成**编译错误**，逼每个 `ForEach` 显式写 `id: \.rowID`。
struct Promotion: Codable, Equatable {
    /// **情报身份**，与线路无关：`bailian-peakvalley-deepseek`。
    /// 通知节流按它去重——同一个客观事实配在两条线路上，不该弹两次。
    /// ⚠️ 所以它在数组里**不唯一**，不能拿来做 SwiftUI 的行标识（见 `rowID`）。
    /// 来源是混合的（规则 id + 页面派生 family，见字段来源表），
    /// 脱敏是确定性的 → 同一页面每次脱敏结果一致，通知节流键跨次稳定。
    let id: String
    let line: String
    /// **面板行身份**。同一个 URL 被两条线路配置时，Python 侧只对抓取去重，
    /// 情报条目仍按线路各出一份（buildManifest），于是数组里会出现两条 `id` 相同
    /// 的记录。`ForEach` 拿到重复 `Identifiable.id` 会打
    /// "Multiple children have the same identity" 并且渲染行为未定义（行不刷新）。
    /// 计算属性，Codable / Equatable 的合成都会自动跳过它。
    var rowID: String { id + "|" + line }
    let title: String
    let vendor: String?
    let models: [String]
    let window: PromotionWindow?
    let discount: PromotionDiscount?
    let eligibility: String?
    let source: PromotionSource
    let evidence: [String]
    let extractor: String?
    let verified: Bool
    /// var：读盘后由 `PromotionStore.recomputeStatus` 按今天重算。
    /// 不重算的话，昨天抓的限时活动今天还会显示「生效中」，用户照着买贵价。
    var status: PromotionStatus
    var kind: PromotionKind
    var validFrom: String?
    var validUntil: String?

    enum CodingKeys: String, CodingKey {
        case id, line, title, vendor, models, window, discount, eligibility
        case source, evidence, extractor, verified, status
        /// ⚠️ `class` 是 Swift 关键字，JSON 键却叫 "class"（Python 侧的自然写法）。
        /// 改名要两边一起改，别只改一边。
        case kind = "class"
        case validFrom = "valid_from"
        case validUntil = "valid_until"
    }

    /// 解码边界脱敏：页面派生字段见字段来源表（id/title/models/window.start/end/
    /// valid_from/valid_until/evidence）；source.url 是用户输入派生（走 source.redacted()）。
    /// line/vendor/eligibility/extractor/discount 是我们自己的，原样保留——尤其 `id`
    /// 是通知节流键、`rowID` 是面板行标识，只脱页面派生/用户输入成分，
    /// 且脱敏确定性保证跨次稳定。
    func redacted() -> Promotion {
        Promotion(id: SecretRedactor.redact(id),
                  line: line,
                  title: SecretRedactor.redact(title),
                  vendor: vendor,
                  models: models.map { SecretRedactor.redact($0) },
                  window: window?.redacted(),
                  discount: discount,
                  eligibility: eligibility,
                  source: source.redacted(),
                  evidence: evidence.map { SecretRedactor.redact($0) },
                  extractor: extractor,
                  verified: verified,
                  status: status,
                  kind: kind,
                  validFrom: validFrom.map { SecretRedactor.redact($0) },
                  validUntil: validUntil.map { SecretRedactor.redact($0) })
    }
}

struct PromotionPage: Codable, Equatable, Identifiable {
    var id: String { line + "|" + url }
    let line: String
    let url: String
    let status: PromotionPageStatus
    let httpStatus: Int?
    let bytes: Int
    let visibleChars: Int
    let fingerprint: String?
    let error: String?
    let note: String?
    /// 抓到了但正文超过体积上限被截断（T4-R1）。失败可见性的一部分：
    /// 丢了它，截断页会被当成完整页显示给用户——「把降质的成功折叠成干净的成功」
    /// 是本项目最忌讳的失效形态。线上页记录 12 键之一，实现计划曾漏声明：
    /// JSON 多一个键而结构体不声明时 Codable **静默通过、值永久丢失**。
    let truncated: Bool
    let unchanged: Bool

    enum CodingKeys: String, CodingKey {
        case line, url, status, bytes, fingerprint, error, note, truncated, unchanged
        case httpStatus = "http_status"
        case visibleChars = "visible_chars"
    }

    /// 第二层脱敏（save() 用；第一层在 decode）。error 是页面派生；url 是用户输入
    /// 派生（手填，可能带 ?api_key=…，spec §3.2）；fingerprint/note/line 按字段
    /// 来源表保留原样。
    func redacted() -> PromotionPage {
        PromotionPage(line: line, url: SecretRedactor.redact(url), status: status,
                      httpStatus: httpStatus, bytes: bytes, visibleChars: visibleChars,
                      fingerprint: fingerprint,
                      error: error.map { SecretRedactor.redact($0) },
                      note: note, truncated: truncated, unchanged: unchanged)
    }
}

/// promo-fetch.py 的 stdout 整体。
struct PromotionFetchResult: Codable {
    let schema: Int
    let fetchedAt: String?
    let today: String?
    let pages: [PromotionPageResult]

    enum CodingKeys: String, CodingKey {
        case schema, today, pages
        case fetchedAt = "fetched_at"
    }

    /// 解码边界脱敏的入口：整棵树按字段来源表重建一遍干净的。
    func redacted() -> PromotionFetchResult {
        PromotionFetchResult(schema: schema, fetchedAt: fetchedAt, today: today,
                             pages: pages.map { $0.redacted() })
    }
}

/// 脚本输出里的页，promotions 内嵌；落盘时拆成 promotions / pages 两份。
struct PromotionPageResult: Codable {
    let line: String
    let url: String
    let status: PromotionPageStatus
    let httpStatus: Int?
    let bytes: Int
    let visibleChars: Int
    let fingerprint: String?
    let error: String?
    let note: String?
    /// 见 `PromotionPage.truncated`。Task 7 的编排器直接取 `pageResult.promotions`
    /// （不经 asPage()），所以条目级脱敏必须做在 redacted() 里、由 decode() 统一触发，
    /// 不能指望「只在 asPage() 里脱敏」——那覆盖不到条目字段。
    let truncated: Bool
    let unchanged: Bool
    let promotions: [Promotion]

    enum CodingKeys: String, CodingKey {
        case line, url, status, bytes, fingerprint, error, note, truncated, unchanged
        case httpStatus = "http_status"
        case visibleChars = "visible_chars"
        case promotions
    }

    func asPage() -> PromotionPage {
        PromotionPage(line: line, url: url, status: status, httpStatus: httpStatus,
                      bytes: bytes, visibleChars: visibleChars, fingerprint: fingerprint,
                      error: error, note: note, truncated: truncated, unchanged: unchanged)
    }

    /// 解码边界脱敏：页级 error + url（用户输入派生）+ 内嵌 promotions 全量
    /// （含其中 source.url，见字段来源表）。
    func redacted() -> PromotionPageResult {
        PromotionPageResult(line: line, url: SecretRedactor.redact(url), status: status,
                            httpStatus: httpStatus, bytes: bytes, visibleChars: visibleChars,
                            fingerprint: fingerprint,
                            error: error.map { SecretRedactor.redact($0) },
                            note: note, truncated: truncated, unchanged: unchanged,
                            promotions: promotions.map { $0.redacted() })
    }
}

/// 落盘快照。
struct PromotionSnapshot: Codable {
    let schema: Int
    let updatedAt: String
    let promotions: [Promotion]
    let pages: [PromotionPage]

    enum CodingKeys: String, CodingKey {
        case schema, promotions, pages
        case updatedAt = "updated_at"
    }
}

// ══════════════════════════════════════════════════════════════════════════
// 🔴 同一份配置 url 在两条边界上的处理（2026-10-10 复审补的契约）：
//
//   出网边界（构造清单喂 promo-fetch.py）：**原始 url，原样**。
//     脚本必须拿到带 key 的原始 url 才真的抓得到页。把脱敏加到这一侧，
//     整个功能会**静默失效**（去抓一个不存在的地址）且不报错——脱敏只发生在
//     解码边界（decode 输出）与落盘/回显边界（save / saveState / 指纹键）。
//
//   存储边界（state.json 的 fingerprints 键）：**sha256( redact 一遍 )**。
//     🔴 2026-10-10 质量复审 Issue 1：这里原先只是「redact 一遍」，而一遍**不保证**
//     洗干净（两把紧邻密钥形状下残留第二把原文，见 PromotionState.fingerprints
//     的契约注释）；又因为 `saveState` 只有 decode 那一层脱敏，「一遍产物」就是
//     state.json 的磁盘字节 → 原文落盘。摘要单向，键不再需要「洗干净」这个前提，
//     spec §3.2 的第二条泄漏通路由此**结构性关闭**，而不是靠「相信 pattern 覆盖得全」。
//     ⚠️ 摘要**只**关掉安全失效模式，没有关掉功能失效模式：两端仍必须各自恰好一遍，
//     否则摘要不同 → 永久 miss（下面 `fromRaw` / `fromDecoded` 的分工就是为此）。
//
// Task 6/7 的清单构造与指纹存查都必须走这些函数，不许各自手写——
// 契约两端各自手写就是漂移的温床（本项目已为此付出 4 次代价）。
// ══════════════════════════════════════════════════════════════════════════
enum PromotionURLContract {
    /// 出网边界：原样返回。清单里的 url 必须是用户配置的原始值（含 key）。
    /// 恒等不是废话：它是「脱敏绝不出现在出网侧」的可测锚点——
    /// promotion_store.swift 断言了 outbound 的返回值仍含 key 原文，
    /// 谁往这里加 redact，测试当场红。
    static func outbound(_ rawURL: String) -> String { rawURL }

    /// 存储键 · **查端**用（Task 7 的 `buildManifest`，手上是配置里的原始 url）。
    ///
    /// 🔴 **为什么形状是 `sha256(redact(raw))` 而不是 `sha256(raw)`**（防「好心简化」）：
    ///   这不是纵深防御的取舍，而是**存端根本算不出 `sha256(raw)`**。存端在
    ///   `for p in pages`（计划 `:3746`）里，`p` 来自 `decoded.pages` —— decode 已经把
    ///   url 洗过一遍，**原始值在这一侧不存在**。两端要同键，就只能都摘要「洗过一遍」
    ///   这个形态。把 redact 从这里删掉 = 查端与存端永久不同键 = `unchanged` 永不成立
    ///   = 用户每天被重复通知同一个活动，且全程无报错。
    /// 🔴 **这里的 `redact` 是「归一」，不是「保密」**（ccpod-a2 2026-10-10 补全，我核对为真）：
    ///   查端先 `redact(raw)`，是为了让摘要的**输入**与存端手上的 `p.url`
    ///   （decode 时洗过一遍的产物）**逐字相同**，两端摘要才会相等。
    ///   摘要本身是单向的，**不需要**输入先脱敏——`sha256(raw)` 一样不泄 key。
    ///   → 所以别把这里的 `redact` 误读成保密措施，进而问「为什么摘要还要脱敏」；
    ///   也**别**因为「摘要不泄」就把 `redact` 删掉（删了就是不同键，见上）。
    ///   保密由**摘要**负责，一致性由**这一遍 redact** 负责，两者不可互换。
    ///   ⚠️ 另有一个说法是「截短摘要做显示时，redact 过的输入才不泄 key 形态」——那条**不成立**：
    ///   截短密码学摘要得到的是十六进制，与输入形状无关，两种形状一样不泄。别拿它当依据。
    /// 🔴 **喂进来的字符串必须与写进 manifest 的 `url` 逐字相同**（我自己对抗性复核时抓到的坑）：
    ///   计划 `:3527` 的查端是 `let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)`，
    ///   manifest 里发的是**修剪后**的 `url`；脚本 `promo-fetch.py:596` 读 `entry.get("url")`、
    ///   `:532` 原样回显（实测全文件 `url` 只在 `:596` 被赋值一次，无任何规范化/改写）。
    ///   → 所以必须写 `storageKey(fromRaw: url)`（**修剪后**），不是 `storageKey(fromRaw: raw)`。
    ///   配置里只要有一个尾随空格，写错这一处就是永久 miss，且**全程无报错**。
    static func storageKey(fromRaw rawURL: String) -> String {
        digest(SecretRedactor.redact(rawURL))
    }

    /// 存储键 · **存端**用（Task 7 的指纹写入，手上是 decode 出来的 `p.url`）。
    /// 参数**已经洗过一遍**，所以只补摘要、**绝不再洗**——再洗就是两遍，
    /// 与 `fromRaw` 那端不同键。参数标签本身就是契约：调用点写出来即可自查喂的是哪种形态。
    static func storageKey(fromDecoded decodedURL: String) -> String {
        digest(decodedURL)
    }

    /// 64 位小写十六进制，**不截短**。房子风格见 `KeyFingerprint.swift:6-7`
    /// （「SHA256 前 6 位…不可还原出 key」）；那里截短是要给人眼对号入座，
    /// 这里做字典键不需要人读，不截短就省掉整类碰撞推理。
    /// 仓内已有三个同款助手，**都是 private，无法复用**，故此处自带一个。
    /// ⚠️ 截短情况**逐个实测**（18:25，`grep -n 'prefix('` + 逐行读），不是三个都一样：
    ///   `KeyFingerprint.of`（`:19` `.prefix(3)` → 6 hex，截短）
    ///   `ProviderImportService.digest`（`:282` `.prefix(8)` → 16 hex，截短）
    ///   `ACS3Signer.hex`（`:104` 全量 64 hex，**不截短**）
    /// → 所以「无法复用」的唯一真因是 **private**；我原先写「都是 private 且截短」三分错一
    ///   （delta 复审抓出）。这种「三个 X 都 Y」的合并陈述最容易夹带一个没核过的成员。
    /// 🔴 裸 swiftc 测试通道下 CryptoKit 可用性与算法正确性都已实测（见文件头注释）。
    private static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// 提醒层状态。与情报分开存：情报是「世界是什么样」，state 是「我做过什么」。
struct PromotionState: Codable {
    var lastRunAt: String?
    var lastSummaryAt: String?
    /// 🔴 **fingerprints 的键契约（存与查两端都必须守；用法层在 Task 7）：**
    /// 不变量一句话：**键 = sha256( 对「原始配置 url」恰好施加一遍 `redact` )**。
    /// 两层理由：
    /// 1) 这个字典整体落进 state.json，而 `saveState` **只有一层脱敏**（decode 那层；
    ///    `save()` 的第二层不经它）。用原始 url 做键，带 `?api_key=sk-…` 的 url 就以
    ///    字典键身份落盘（spec §3.2 的第二条通路，只脱 source.url 堵不住它）。
    /// 2) 只脱存储端不脱查表端会造成功能回归：键是脱敏 url、查的是原始 url →
    ///    **永久 miss** → `unchanged` 永远不成立 → 用户每天被重复通知同一个活动。
    ///
    /// 🔴 **为什么必须过摘要**（2026-10-10 质量复审 Issue 1；残留本身我早先已实测）：
    ///   `redact` 一遍**不保证**洗干净。url 里有两把紧邻的密钥形状时，P0 的
    ///   `(?<![A-Za-z0-9])` 被前一把的尾部 alnum 挡住，一遍产物**仍含第二把 key 原文**
    ///   （钉住它的断言见 promotion_store.swift 第 9 节 C2）。结合理由 1，「一遍产物」
    ///   就是 state.json 的磁盘字节 → 原文落盘。摘要单向：键不再需要「洗干净」这个前提，
    ///   这条通路**结构性关闭**，而不是靠「相信 pattern 覆盖得全」。
    ///   ⚠️ 摘要**只**关掉安全失效模式：存端拿不到原始 url，两端仍须各洗恰好一遍，
    ///   否则摘要不同 → 永久 miss。所以第 9 节的 A / B / C 三组断言一个都不能删。
    ///
    /// 🔴 **五种拼法，只有两种合法**（2026-10-10 复审要求点名：本注释同时出现过
    ///   「存端用 `p.url`」与「两端共用 `storageKey`」两种说法，而最危险的混写
    ///   恰好长得最像前两者的合体）：
    ///
    ///     ✅ 合法  存端 `fingerprints[storageKey(fromDecoded: p.url)] = fp`
    ///     ✅ 合法  查端 `fingerprints[storageKey(fromRaw: raw)]`   raw 是配置里的原始 url
    ///     🔴 禁止  `storageKey(fromRaw: p.url)`       **两遍** → 不同摘要 → 永久 miss
    ///     🔴 禁止  `storageKey(fromDecoded: raw)`     **零遍** → 不同摘要 → 永久 miss
    ///     🔴 禁止  `fingerprints[p.url]` / `fingerprints[raw]`  不经摘要 → 键里可能有 key 原文
    ///
    ///   记忆法：`fromRaw` 吃**没洗过**的、`fromDecoded` 吃**洗过一遍**的；两个标签就是
    ///   「你手上这一份是哪种形态」的自述，喂错标签 = 遍数错 = 静默的永久 miss。
    ///   🔴 计划原文两处都是第 5 种禁止拼法：`:3534` 写 `state.fingerprints[url]`、
    ///   `:3746` 写 `state.fingerprints[p.url]`（`storageKey` 在整份计划里命中 **0**，
    ///   这个契约是实现侧补的）。**Task 7 派单必须覆盖计划原文**，不许照抄。
    /// ⚠️ 本注释原先写「存端直接用 `p.url`、**或**再过一遍 storageKey，与查端都是同一个键」
    ///   ——那个「或」是**错的**，2026-10-10 在 Swift 侧实测推翻（不是推理，也不是引
    ///   Python 侧结论）：`redact(redact(u)) == redact(u)` 只对**单把密钥**的 url 成立。
    ///   url 里若有**两把紧邻的密钥形状**（用户粘一个带签名的链接就可能），P0 的
    ///   `(?<![A-Za-z0-9])` lookbehind 会挡住第一遍的 sk- 段（它前面是 alnum），
    ///   P1 先把 ark 段 mask 成 `***REDACTED***` 后 sk- 前面变成 `*` → **第二遍才 mask**。
    ///   实测一遍产物与二遍产物不同（配方与断言见 promotion_store.swift 第 9 节）。
    ///   后果：存端多洗一遍 → 键与查端不同 → 指纹**永久 miss** → `unchanged` 永不成立
    ///   → 用户每天被重复通知同一个活动，且**全程无报错**（静默失效）。
    /// 🔴 同理，**不要**在 `saveState` 里给字典键「补一道脱敏」以求纵深防御——
    ///   那正是把一遍变成两遍，会亲手造出上面这个回归。要纵深就加在**摘要**上
    ///   （它已经在契约里、且单向不可逆），别加在**遍数**上。
    ///   state.json 的键干净靠的是「键是摘要」这一条，不是靠在写盘处再洗。
    ///   （`save()` 的第二层为什么可以洗而这里不行：`save()` 洗的是**值**，
    ///   洗两遍对单密钥形状是不动点、对相邻形状也只是"更严"，不影响任何查表；
    ///   而字典**键**是要被精确匹配的，多洗一遍就等于换了一把钥匙。）
    /// 不动点断言与相邻形状反例断言都在 Swift 侧自测（不许引用 Python 侧修正 26 的
    /// 结论——两侧 pattern 是两份独立拷贝，本项目已发生 4 次静默漂移）。
    var fingerprints: [String: String]
    /// 情报 id → 上次弹通知的时刻（ISO）。24h 内同一条不重复弹。
    var lastAlertedAt: [String: String]

    enum CodingKeys: String, CodingKey {
        case fingerprints
        case lastRunAt = "last_run_at"
        case lastSummaryAt = "last_summary_at"
        case lastAlertedAt = "last_alerted_at"
    }

    static let empty = PromotionState(lastRunAt: nil, lastSummaryAt: nil,
                                      fingerprints: [:], lastAlertedAt: [:])
}

// MARK: - 脚本输出解码

/// 只负责「把 promo-fetch.py 的 stdout 变成 Swift 值」。
/// 单独拆出来是因为解码失败是**最常见的失效模式**（脚本改了字段、Swift 没跟上），
/// 必须能脱离 App 单测。
///
/// 🔴 脱敏在解码边界，而不是只在落盘时：编排器（Task 7）把解出的 pages/promotions
/// 直接发布给 UI（通知与面板逐字回显 error / evidence / title），若只靠 save()
/// 里那层，**内存里流转的就是原文**——error 里的 exc.reason 是服务端可控文本。
/// save() 里的 PromotionStore.redacted() 保留为第二层（纵深防御），别当冗余删。
struct PromotionScriptRunner {
    func decode(raw: String) -> PromotionFetchResult? {
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(PromotionFetchResult.self, from: data)
        else { return nil }
        // 解码成功即脱敏：返回的值从这一刻起就是干净的，后面谁消费都安全。
        return result.redacted()
    }
}

// MARK: - 存储

enum PromotionStore {
    static let schemaVersion = 1

    static var defaultDirectory: URL {
        // 计划原稿此处是 `NSString(...).expandingTildeInPath.flatMap { URL(...) } ?? …`：
        // expandingTildeInPath 返回非可选 String，String 上没有返回 URL 的 flatMap
        // 重载（按 Character 序列走需要 URL: Sequence，不存在）→ 编译不过。此处为
        // 2026-10-10 实测后重写：展开为空（几乎不可能）时退回家目录。
        let expanded = NSString(string: "~/.claude").expandingTildeInPath
        return URL(fileURLWithPath: expanded.isEmpty ? NSHomeDirectory() : expanded)
    }

    static func promotionsURL(in dir: URL? = nil) -> URL {
        (dir ?? defaultDirectory).appendingPathComponent("ccpod-promotions.json")
    }

    static func stateURL(in dir: URL? = nil) -> URL {
        (dir ?? defaultDirectory).appendingPathComponent("ccpod-promotions-state.json")
    }

    // MARK: 读

    static func load(from dir: URL? = nil) -> PromotionSnapshot? {
        let url = promotionsURL(in: dir)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let snap = try? JSONDecoder().decode(PromotionSnapshot.self, from: data) else {
            // 坏文件返回 nil：面板显示「还没抓到情报」，比崩掉整个菜单栏好。
            return nil
        }
        return snap
    }

    static func loadState(from dir: URL? = nil) -> PromotionState {
        let url = stateURL(in: dir)
        guard let data = try? Data(contentsOf: url),
              let st = try? JSONDecoder().decode(PromotionState.self, from: data) else {
            return .empty
        }
        return st
    }

    // MARK: 写

    static func save(_ snapshot: PromotionSnapshot, in dir: URL? = nil) throws {
        try write(encode(redacted(snapshot)), to: promotionsURL(in: dir), in: dir)
    }

    static func saveState(_ state: PromotionState, in dir: URL? = nil) throws {
        try write(encode(state), to: stateURL(in: dir), in: dir)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try enc.encode(value)
    }

    /// ⚠️ `.atomic` 会按 umask 建成 **644**，所以写完必须显式 setAttributes 到 600。
    /// 这两个文件会进备份、iCloud、截图，权限不能靠 umask。
    /// 🔴 Swift 里 `0o600 == 384`；写成十进制 `600` 会把权限设成八进制 1130。
    /// 目录 0o700（`0o700 == 448`，同理别写十进制 700）。
    ///
    /// 🔴 目录 700 **只加在本次由 ccpod 创建的目录上**（2026-10-10 质量复审 Issue 2）：
    ///   生产默认路径（`dir == nil`）下 `target` 就是 `~/.claude` —— 那是 Claude Code
    ///   自己的目录，本机实测 `drwxr-xr-x`（755），ccpod **不拥有**它。一个「只提醒」
    ///   的功能不该顺带改它的权限（spec §0.3 产品硬边界），而原写法的 `try?` 还会把
    ///   失败吞成静默。spec 的落盘表只要求这两个 json 是 **600**，700 目录是实现计划
    ///   `:2553-2556` 自己加的、spec 里没有。
    ///   先例（都是当场读原文核过的）：`~/.claude/ccpod-session-counter` 是文件 600、
    ///   目录没被动过；`ProviderImportService.swift:149-151` 与 `GatewayLineService.swift:170-171`
    ///   的无条件 700 加在 ccpod **自己创建**的子目录上 —— 与这里「自己创建才收紧」同判据。
    ///   创建失败现在会 `throw` 真错误（原来 `try?` 吞掉后要等到 `data.write` 才炸，
    ///   报的是写失败的错，指不到真因）。
    private static func write(_ data: Data, to url: URL, in dir: URL?) throws {
        let target = dir ?? url.deletingLastPathComponent()
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.path) {
            try fm.createDirectory(at: target, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
        }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: 脱敏（第二层，纵深防御；第一层在 PromotionScriptRunner.decode）

    /// 落盘前再过一遍：正常路径下 decode 已经脱过（对**单把密钥**形状此处是幂等的
    /// no-op；对两把紧邻密钥形状它会掩得更严——无害，因为这一层洗的是**值**、
    /// 值不参与精确匹配。⚠️ 别把这个「无害」推广到字典**键**：键多洗一遍等于换钥匙，
    /// 见 `PromotionState.fingerprints` 的契约注释），但快照
    /// 也可能由**未经 decode 的值**直接构造（如手工构建、别的来源），这一层保证
    /// 「凡落盘必干净」不依赖调用方自觉。与第一层共用同一套 per-类型 redacted()，
    /// 字段来源表只有一份，两层不会漂移。
    static func redacted(_ snapshot: PromotionSnapshot) -> PromotionSnapshot {
        PromotionSnapshot(schema: snapshot.schema, updatedAt: snapshot.updatedAt,
                          promotions: snapshot.promotions.map { $0.redacted() },
                          pages: snapshot.pages.map { $0.redacted() })
    }

    // MARK: 状态重算

    /// 按今天重算三态。ISO 日期串可以直接按字典序比。
    /// 边界都算 active：今天开始 = 已经能用；今天结束 = 今天还能用。
    static func recomputeStatus(_ promotions: [Promotion], today: String) -> [Promotion] {
        promotions.map { p in
            var q = p
            if let from = p.validFrom, from > today {
                q.status = .upcoming
            } else if let until = p.validUntil, until < today {
                q.status = .expired
            } else {
                q.status = .active
            }
            return q
        }
    }
}
