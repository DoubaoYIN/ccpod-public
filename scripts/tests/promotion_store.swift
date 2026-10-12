import Foundation

// 优惠雷达 Task 5 测试主体：与 routing_leak.swift 同通道（swiftc 独立编译，无 XCTest，
// @main struct 形态也照抄它——多文件编译时顶层表达式只有 main.swift 才允许）。
//
// 🔴 计数判据（.local/count-swift-checks.py 的等式）：源码里 check( 调用数 ==
// 运行时自报的 CHECKS=N。为此每一条 check( 都在**直线代码**里——不在循环、不在
// if/else 分支——解码失败一律走 decodeOrDie 直接 exit(1)，不拿 check 承担。
// 两处 exit(1)（decodeOrDie 与末尾汇总）是基线（run-baseline.sh 判 rc）唯一的
// 失败传导路径，不许弱化。抛错点一律 try!：崩溃即非 0 退出码，同样被基线抓到。

@main struct PromotionStoreTests {

    static var failures = 0
    static var checkCount = 0

    static func check(_ cond: Bool, _ msg: String) {
        checkCount += 1
        if cond { print("  ✅ \(msg)") } else { print("  ❌ \(msg)"); failures += 1 }
    }

    static let runner = PromotionScriptRunner()

    static func decodeOrDie(_ label: String, _ raw: String) -> PromotionFetchResult {
        guard let d = runner.decode(raw: raw) else {
            print("  ❌ [\(label)] 解码失败 —— 模型与脚本输出对不上，后续断言全部跳过")
            exit(1)
        }
        return d
    }

    /// 权限读数助手。**读不到就返回 -1**，不返回 0 也不静默——-1 永远不等于任何
    /// 合法权限值，所以「文件/目录不存在」会让断言变红而不是变绿（候选㉔：
    /// 别让「读不到」伪装成「读到了某个值」）。
    static func permOf(_ url: URL) -> Int {
        let a = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (a?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // 🔴 假 key 样本（数据常量；形状照 Python 侧 RedactIdempotencyTest 的样本表）。
    // 只允许以数据形态出现；断言消息与注释一律不复述原文。
    static let FAKE_SK = "sk-live-DEADBEEFDEADBEEF"
    static let FAKE_SK2 = "sk-live-FEEDFACEFEEDFACE"
    static let FAKE_TOKEN = "sk-live-CAFEBEefCAFEBEef"
    /// 🔴 **拼接构造**，源码行不出现整串（与上面三个既存整串常量的口径不同，
    /// 新增一律按拼接口径：整串会被 export-public.sh 门禁3 命中，而 scripts/tests
    /// 是整目录导出）。用途：与 FAKE_SK **紧邻**时构成「两把相邻密钥」反例样本，
    /// 供第 9 节钉住 fingerprints 键的「两端各洗一遍」规则（见该节注释）。
    static let FAKE_ARK = "ark-" + "abcdef12345678"

    static func main() {

        print("== 0. SecretRedactor 5 类 pattern 的行为覆盖（孤立串，逐形状断言被 mask）==")
        // patterns 是 private 读不到，只能行为测试。样本必须是一个个**孤立串**：两个
        // 不同形状的密钥紧邻时 redact(redact(x)) != redact(x)（Swift 与 Python 的
        // pattern 同形同序，非幂等同样成立），拼在一个串里断言会引入无关变量。
        // 修正 24 §四：Python 侧 6 个 stderr 出口故意不脱敏，Swift 侧 SecretRedactor
        // 是它们唯一的防线（Task 7 的 stderr 消费点与本文件的解码边界共用同一个
        // redactor）——两端 pattern 漂移无人察觉，防线锚点就在这条。
        check(SecretRedactor.redact("token " + FAKE_SK + " here").contains("***REDACTED***"),
              "sk- 前缀形状被 mask（原文见样本常量，不复述）")
        check(SecretRedactor.redact("yessk-abcdefgh12345678").contains("***REDACTED***"),
              "yessk- 变体被 mask")
        check(SecretRedactor.redact("ark-abcdef1234567890").contains("***REDACTED***"),
              "ark- 火山形状被 mask")
        check(SecretRedactor.redact("cr-abcdefg12345678").contains("***REDACTED***"),
              "cr- 形状被 mask")
        check(SecretRedactor.redact("ccr_abcdef12345678").contains("***REDACTED***"),
              "ccr_ 形状被 mask")
        check(SecretRedactor.redact("abcdef01234567890123456789012345.Abcdefghijklmnop").contains("***REDACTED***"),
              "hex.hex 形状被 mask")
        check(SecretRedactor.redact("Authorization: Bearer abcdefghijklmnop12").contains("***REDACTED***"),
              "Bearer 头形状被 mask")

        print("== 1. 解码真实输出（手写 payload，形状照 promo-fetch.py stdout 契约）==")
        // ⚠️ bytes=1964692 / visible_chars=107606 是这份手写解码测试自己的口径（源页
        // 实测数），与 fixture 解析层的 5734/3562 是两个口径，都对，不许互相「纠正」。
        let realPayload = """
        {"schema": 1, "fetched_at": "2026-10-10T00:40:00+08:00", "today": "2026-10-10",
         "pages": [{
           "line": "gw-bailian",
           "url": "https://help.aliyun.com/zh/model-studio/billing-for-model-studio",
           "status": "ok", "http_status": 200, "bytes": 1964692, "visible_chars": 107606,
           "fingerprint": "sha256:abc", "error": null, "note": null,
           "truncated": false, "unchanged": false,
           "promotions": [{
             "id": "bailian-peakvalley-deepseek", "line": "gw-bailian", "class": "peak_valley",
             "title": "阿里云百炼 DeepSeek 系列 闲时 5 折（22:00–次日 08:00 北京时间）",
             "vendor": "阿里云百炼",
             "models": ["deepseek-v4-flash-0731", "deepseek-v4-pro-0813", "deepseek-v4.1-flash"],
             "window": {"tz": "Asia/Shanghai", "start": "22:00", "end": "08:00",
                        "days": ["mon","tue","wed","thu","fri","sat","sun"], "ends_next_day": true},
             "discount": {"ratio": 0.5, "text": "闲时约为忙时的 5 折", "short": "闲时 5 折"},
             "eligibility": "无需报名，闲时时段调用自动按闲时价计费；具体单价与地域以官方页为准",
             "valid_from": "2026-08-17", "valid_until": null,
             "source": {"url": "https://help.aliyun.com/zh/model-studio/billing-for-model-studio",
                        "fetched_at": "2026-10-10T00:40:00+08:00", "official": true},
             "evidence": ["忙时为北京时间 8:00 - 22:00，闲时为北京时间 22:00 - 次日 8:00。"],
             "extractor": "rule:bailian-peakvalley", "verified": true, "status": "active"
           }]}]}
        """
        let decoded = decodeOrDie("真实输出", realPayload)
        let page = decoded.pages[0].asPage()
        let promo = decoded.pages[0].promotions[0]
        check(decoded.schema == 1, "schema == 1")
        check(decoded.pages.count == 1, "pages.count == 1")
        check(page.status == .ok, "页级 status == .ok")
        check(page.httpStatus == 200, "http_status == 200")
        check(page.visibleChars == 107606, "visible_chars == 107606（手写 payload 口径）")
        check(page.unchanged == false, "unchanged == false")
        check(page.error == nil && page.note == nil, "error / note 均为 null")
        check(page.truncated == false, "truncated: false 解出 false（线上 12 键之一，漏声明即静默丢失）")
        check(promo.kind == .peakValley, "JSON 键 class 映射到 kind（class 是 Swift 关键字）")
        check(promo.id == "bailian-peakvalley-deepseek", "id 正确")
        check(promo.title == "阿里云百炼 DeepSeek 系列 闲时 5 折（22:00–次日 08:00 北京时间）", "title 中文未被转义/截断")
        check(promo.models.count == 3, "models 3 个")
        check(promo.window?.endsNextDay == true, "ends_next_day == true（跨午夜，倒计时靠它）")
        check(promo.window?.start == "22:00" && promo.window?.end == "08:00", "窗口 22:00→08:00")
        check(promo.discount?.ratio == 0.5, "ratio == 0.5")
        check(promo.discount?.short == "闲时 5 折", "discount.short 解出")
        check(promo.verified == true, "verified == true")
        check(promo.source.official == true, "source.official == true")
        check(promo.validFrom == "2026-08-17", "valid_from 映射到 validFrom")
        check(promo.status == .active, "status == .active")
        check(promo.id == "bailian-peakvalley-deepseek" && !promo.id.contains("|"), "id 是情报身份，不含线路")
        check(promo.rowID == "bailian-peakvalley-deepseek|gw-bailian", "rowID = id|line")

        print("== 1b. 同情报跨线路：id 重复是设计如此，行标识必须用 rowID ==")
        // 同一个 URL 配在两条线路上：Python 只对抓取去重，情报条目按线路各出一份。
        // SwiftUI 的行标识必须用 rowID，不能用 id——用错会让 ForEach 拿到重复
        // Identifiable.id，打 "Multiple children have the same identity" 且渲染未定义。
        let twinRaw = """
        {"schema":1,"fetched_at":"x","today":"2026-10-10","pages":[
          {"line":"gw-bailian","url":"u","status":"ok","http_status":200,"bytes":1,"visible_chars":9000,
           "fingerprint":"sha256:x","error":null,"note":null,"truncated":false,"unchanged":false,
           "promotions":[{"id":"bailian-peakvalley-deepseek","line":"gw-bailian","class":"peak_valley",
             "title":"t","vendor":null,"models":[],"window":null,"discount":null,"eligibility":null,
             "valid_from":null,"valid_until":null,
             "source":{"url":"u","fetched_at":"x","official":true},
             "evidence":["e"],"extractor":"rule:x","verified":true,"status":"active"}]},
          {"line":"gw-dup","url":"u","status":"ok","http_status":200,"bytes":1,"visible_chars":9000,
           "fingerprint":"sha256:x","error":null,"note":null,"truncated":false,"unchanged":false,
           "promotions":[{"id":"bailian-peakvalley-deepseek","line":"gw-dup","class":"peak_valley",
             "title":"t","vendor":null,"models":[],"window":null,"discount":null,"eligibility":null,
             "valid_from":null,"valid_until":null,
             "source":{"url":"u","fetched_at":"x","official":true},
             "evidence":["e"],"extractor":"rule:x","verified":true,"status":"active"}]}]}
        """
        let twin = decodeOrDie("twin", twinRaw)
        let twinAll = twin.pages.flatMap { $0.promotions }
        check(twinAll.count == 2, "两条线路各出一份情报")
        check(Set(twinAll.map { $0.id }).count == 1,
              "id 相同才对：通知按 id 节流，同一客观事实配两条线路不该弹两次")
        check(Set(twinAll.map { $0.rowID }).count == 2,
              "rowID 必须不同：面板按 rowID 渲染行，重复 id 会让 ForEach 行为未定义")

        print("== 1c. truncated: true 单独构造（只测 false 等于没测：字段恒 false 也能过）==")
        let truncRaw = """
        {"schema":1,"fetched_at":"x","today":"2026-10-10","pages":[
          {"line":"l","url":"u","status":"parse-failed","http_status":200,"bytes":1,"visible_chars":9000,
           "fingerprint":"sha256:x","error":null,"note":"no-rule-matched-url",
           "truncated":true,"unchanged":false,"promotions":[]}]}
        """
        let truncDecoded = decodeOrDie("truncated:true", truncRaw)
        check(truncDecoded.pages[0].truncated == true,
              "truncated: true 解出 true（失败可见性：截断页不能被当完整页）")
        check(truncDecoded.pages[0].note == "no-rule-matched-url",
              "note 原样解出（keep 名单锚：note 值域是我们写的两个字面量，见字段来源表）")

        print("== 2. 失败态也能解码（每一种「空」都有自己的名字，不能整条丢掉）==")
        let dFetchFailed = decodeOrDie("fetch-failed", statusPayload("\"fetch-failed\""))
        check(dFetchFailed.pages[0].status == .fetchFailed, "status fetch-failed 解码为 fetchFailed")
        let dUnsupported = decodeOrDie("unsupported-js-page", statusPayload("\"unsupported-js-page\""))
        check(dUnsupported.pages[0].status == .unsupportedJSPage, "status unsupported-js-page 解码为 unsupportedJSPage")
        let dParseFailed = decodeOrDie("parse-failed", statusPayload("\"parse-failed\""))
        check(dParseFailed.pages[0].status == .parseFailed, "status parse-failed 解码为 parseFailed")
        let dOk = decodeOrDie("ok", statusPayload("\"ok\""))
        check(dOk.pages[0].status == .ok, "status ok 解码为 ok")

        print("== 3. 状态重算：不重新抓也要把过期判出来 ==")
        // 场景：昨天抓的 valid_until=2026-10-09，今天 10-10 打开面板。
        // 不重算的话面板会继续显示「生效中」，用户照着买贵价。
        // class 用线上 B 类真实值 "promotion"（promo-fetch.py 白名单），一并钉住解码契约。
        let expiringRaw = """
        {"schema":1,"fetched_at":"2026-10-09T21:00:00+08:00","today":"2026-10-09","pages":[
          {"line":"l","url":"u","status":"ok","http_status":200,"bytes":1,"visible_chars":9000,
           "fingerprint":"sha256:x","error":null,"note":null,"truncated":false,"unchanged":false,
           "promotions":[{"id":"p","line":"l","class":"promotion","title":"限时活动",
             "vendor":null,"models":[],"window":null,"discount":null,"eligibility":null,
             "valid_from":"2026-09-01","valid_until":"2026-10-09",
             "source":{"url":"u","fetched_at":"2026-10-09T21:00:00+08:00","official":false},
             "evidence":[],"extractor":null,"verified":false,"status":"active"}]}]}
        """
        let expiring = decodeOrDie("expiring", expiringRaw)
        check(expiring.pages[0].promotions[0].kind == .limitedTime,
              "B 类线上值是 promotion（promo-fetch.py 白名单的合法值），kind 解码为 limitedTime")
        check(expiring.pages[0].promotions[0].status == .active, "抓取当天是 active")
        let refreshed = PromotionStore.recomputeStatus(expiring.pages[0].promotions, today: "2026-10-10")
        check(refreshed[0].status == .expired, "隔天打开面板重算为 expired")
        let refreshed2 = PromotionStore.recomputeStatus(expiring.pages[0].promotions, today: "2026-08-01")
        check(refreshed2[0].status == .upcoming, "早于 valid_from 时重算为 upcoming")

        print("== 4. 落盘：文件 600 + 目录权限分两种情形 + 往返一致 ==")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("promo-store-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 🔴 显式把「已存在的目录」设成 755 并读回确认，再保存。
        //   不预置就没法断言「保存后仍是 755」——万一 chmod 在两边都失败，那条断言
        //   也会绿（候选㉔：不变的读数有三种来源，只有一种是通过）。
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp.path)
        let prePerm = permOf(tmp)
        check(prePerm == 0o755, "观测前提：保存前已存在目录确实是 755（实测 \(prePerm)）")

        let snapshot = PromotionSnapshot(schema: 1, updatedAt: "2026-10-10T00:40:00+08:00",
                                         promotions: [promo], pages: [page])
        try! PromotionStore.save(snapshot, in: tmp)
        let fileURL = PromotionStore.promotionsURL(in: tmp)
        check(FileManager.default.fileExists(atPath: fileURL.path), "文件真的写出来了（观测前提）")
        let perm = permOf(fileURL)
        // ⚠️ Swift 里 0o600 == 384。写成十进制 600 会把权限设成八进制 1130（本项目踩过）。
        check(perm == 0o600, "promotions.json 权限 == 600（实测 \(perm)，期望 \(0o600)）")
        // 🔴 Issue 2 守卫（2026-10-10 质量复审）：生产默认路径下这个「已存在的目录」
        //   就是 ~/.claude（本机实测 drwxr-xr-x = 755），ccpod 不拥有它，一个「只提醒」
        //   的功能不该顺带改它的权限。
        //   📐 检出力**已实测**（M2，`/tmp/mut20`、台账第 20.5 节）：把 `write()` 改回
        //   无条件 chmod 700 → **恰好 1 红 = 这条**，下面那条 700 **仍绿**。
        //   所以两条不是互相替代，是各守一种情形；这条也不是连带红。
        check(permOf(tmp) == 0o755,
              "已存在的目录**不被**改权限（生产路径下那是 ~/.claude，ccpod 不拥有它）")

        // 对照用例：ccpod **自己创建**的目录才收紧到 700。先例（当场读过原文）：
        // ProviderImportService.swift:149-151、GatewayLineService.swift:170-171 的
        // 无条件 700 都加在 ccpod 自己创建的子目录上，与此处判据一致。
        let made = tmp.appendingPathComponent("ccpod-created")
        check(!FileManager.default.fileExists(atPath: made.path),
              "观测前提：待创建目录此刻确实不存在（否则下面那条 700 是空转）")
        try! PromotionStore.save(snapshot, in: made)
        check(permOf(made) == 0o700,
              "ccpod 自己创建的目录收紧到 700（实测 \(permOf(made))，期望 \(0o700)）")
        check(permOf(PromotionStore.promotionsURL(in: made)) == 0o600,
              "新建目录里的文件同样是 600")
        let loaded = PromotionStore.load(from: tmp)
        check(loaded?.promotions.count == 1, "读回 1 条情报")
        check(loaded?.promotions[0].id == promo.id, "读回 id 一致")
        check(loaded?.promotions[0].window?.endsNextDay == true, "读回 ends_next_day 一致")
        check(loaded?.pages[0].visibleChars == 107606, "读回页级判据一致（手写 payload 口径）")
        check(loaded?.pages[0].truncated == false, "读回 truncated 一致（快照往返不丢字段）")

        print("== 5. state 文件：600 + 默认值 + 往返 ==")
        let state0 = PromotionStore.loadState(from: tmp)
        check(state0.fingerprints.isEmpty, "没有 state 文件时返回空 state，不是 nil 也不是崩")
        check(state0.lastAlertedAt.isEmpty, "lastAlertedAt 默认空")
        var st = state0
        st.lastRunAt = "2026-10-10T21:00:00+08:00"
        st.fingerprints["https://help.aliyun.com/x"] = "sha256:abc"
        st.lastAlertedAt["bailian-peakvalley-deepseek"] = "2026-10-10T21:30:00+08:00"
        try! PromotionStore.saveState(st, in: tmp)
        let stAttrs = try! FileManager.default.attributesOfItem(atPath: PromotionStore.stateURL(in: tmp).path)
        let stPerm = (stAttrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        check(stPerm == 0o600, "state.json 权限 == 600（实测 \(stPerm)）")
        let st1 = PromotionStore.loadState(from: tmp)
        check(st1.lastRunAt == "2026-10-10T21:00:00+08:00", "state 往返 lastRunAt")
        check(st1.fingerprints["https://help.aliyun.com/x"] == "sha256:abc", "state 往返 fingerprints")
        check(st1.lastAlertedAt["bailian-peakvalley-deepseek"] != nil, "state 往返 lastAlertedAt")

        print("== 6. schema 不认识的版本：不静默当成空 ==")
        let badSchemaRaw = """
        {"schema": 99, "fetched_at":"x","today":"2026-10-10","pages":[]}
        """
        let badSchema = runner.decode(raw: badSchemaRaw)
        check(badSchema == nil || badSchema?.schema == 99, "schema 99 要么拒收要么原样带出，不能悄悄当 schema 1")
        check(PromotionStore.schemaVersion == 1, "本机 schemaVersion == 1")

        print("== 7. 坏文件不炸 App ==")
        try! Data("这不是 JSON".utf8).write(to: PromotionStore.promotionsURL(in: tmp))
        check(PromotionStore.load(from: tmp) == nil, "坏 json → nil（面板显示「还没抓到」而不是崩）")

        print("== 8. 落盘脱敏（第二层）：error / evidence / models / title 落盘前过 SecretRedactor ==")
        // 直接用 memberwise init 构造**未脱敏**的值喂 save()——这一层护的就是
        // 「快照由未经 decode 的值构造」的路径；正常路径 decode 已脱过，此处是 no-op。
        let leakyPromo = Promotion(
            id: "leaky-demo", line: "gw-x", title: "t " + FAKE_SK2, vendor: nil,
            models: [FAKE_SK2], window: nil, discount: nil, eligibility: nil,
            source: PromotionSource(url: "u", fetchedAt: "x", official: false),
            evidence: ["denied: key " + FAKE_SK], extractor: nil, verified: false,
            status: .active, kind: .limitedTime, validFrom: nil, validUntil: nil)
        let leakyPage = PromotionPage(line: "gw-x", url: "u", status: .fetchFailed, httpStatus: 403,
                                      bytes: 0, visibleChars: 0, fingerprint: nil,
                                      error: "HTTP 403 key=" + FAKE_SK,
                                      note: nil, truncated: false, unchanged: false)
        let leaky = PromotionSnapshot(schema: 1, updatedAt: "x",
                                      promotions: [leakyPromo], pages: [leakyPage])
        try! PromotionStore.save(leaky, in: tmp)
        let onDisk = try! String(contentsOf: PromotionStore.promotionsURL(in: tmp), encoding: .utf8)
        check(!onDisk.contains(FAKE_SK),
              "页级 error 里的密钥样式串没有原文落盘（这个文件会进备份/同步/截图）")
        check(!onDisk.contains(FAKE_SK2),
              "条目级 evidence/models/title 里的密钥样式串没有原文落盘（第二层覆盖 promotions）")
        check(onDisk.contains("***REDACTED***"), "落盘内容里有掩码（正面证据：脱敏真的跑了）")

        print("== 8b. 解码边界脱敏（第一层）：decode 返回的内存值已经是干净的 ==")
        // 铁证链：Task 7 的编排器把 decode 出的 pages/promotions 直接发布给 UI（通知与
        // 面板逐字回显 error / evidence / title），只靠 save() 那层时内存里流转的就是
        // 原文；error 里的 exc.reason 是服务端可控文本（反爬/网关可回显 Authorization）。
        let leakyRaw = """
        {"schema":1,"fetched_at":"x","today":"2026-10-10","pages":[
          {"line":"gw-bailian","url":"https://example.com/pricing","status":"fetch-failed",
           "http_status":403,"bytes":0,"visible_chars":0,"fingerprint":"sha256:abc123def",
           "error":"HTTP 403 Forbidden body: denied: key=\(FAKE_SK)",
           "note":null,"truncated":false,"unchanged":false,
           "promotions":[{"id":"rule-x-demo","line":"gw-bailian","class":"peak_valley",
             "title":"t \(FAKE_SK2)","vendor":null,
             "models":["\(FAKE_SK2)","deepseek-v4"],
             "window":{"tz":"Asia/Shanghai","start":"22:00","end":"08:00",
                       "days":["mon"],"ends_next_day":true},
             "discount":{"ratio":0.5,"text":"闲时约为忙时的 5 折","short":"闲时 5 折"},
             "eligibility":null,"valid_from":"2026-08-17","valid_until":null,
             "source":{"url":"https://example.com/pricing","fetched_at":"x","official":true},
             "evidence":["gateway saw Bearer \(FAKE_TOKEN)"],
             "extractor":"rule:x","verified":true,"status":"active"}]}]}
        """
        let leakyDecoded = decodeOrDie("leaky", leakyRaw)
        let lp = leakyDecoded.pages[0]
        let lq = leakyDecoded.pages[0].promotions[0]
        check(lp.error?.contains("***REDACTED***") == true, "内存 error 已含掩码（解码即脱敏）")
        check(lp.error?.contains(FAKE_SK) != true, "内存 error 无假 key 原文（掩码在、原文不在）")
        check(lq.evidence[0].contains("***REDACTED***"), "内存 evidence 已含掩码")
        check(!lq.evidence[0].contains(FAKE_TOKEN), "内存 evidence 无 Bearer 假 key 原文")
        check(!lq.models.joined(separator: ",").contains(FAKE_SK2), "内存 models 无假 key 原文")
        check(!lq.title.contains(FAKE_SK2), "内存 title 无假 key 原文")
        check(lq.extractor == "rule:x" && lp.url == "https://example.com/pricing"
                && lq.window?.start == "22:00" && lq.discount?.short == "闲时 5 折",
              "keep 名单原样（extractor/window.start/short）+ 无 key 的 url 过 redact 不变形（过度脱敏回归锚）")

        print("== 9. 🔴 url 用户输入派生：带 key 的手填 url 不进内存/promotions.json/state.json（spec §3.2）==")
        // 2026-10-10 复审改判：url 原判「我们自己的：manifest 配置」是错的——manifest
        // 只是转述用户在 Task 9「管线管理」输入框手填的值，可能带 ?api_key=sk-…
        // （spec §3.2 与计划 :5571 的用户文案都承诺了这道保护）。三条通路全堵：
        // 内存（解码边界）、promotions.json（落盘两层）、state.json 的 fingerprints 键。
        // 🔴 假 key 一律由 FAKE_* 常量拼接，源码行不出现整串：scripts/tests/ 会被
        // 公开导出，门禁3 的 api_key= 正则会命中整串写法（拼接探针 2026-10-10 实测）。
        let leakyURL = "https://help.aliyun.com/billing?api_key=" + FAKE_SK
        let urlPayload = """
        {"schema":1,"fetched_at":"x","today":"2026-10-10","pages":[
          {"line":"gw-bailian","url":"\(leakyURL)","status":"ok","http_status":200,"bytes":1,
           "visible_chars":55,"fingerprint":"sha256:x","error":null,"note":null,
           "truncated":false,"unchanged":false,
           "promotions":[{"id":"p9","line":"gw-bailian","class":"peak_valley","title":"t",
             "vendor":null,"models":[],"window":null,"discount":null,"eligibility":null,
             "valid_from":null,"valid_until":null,
             "source":{"url":"\(leakyURL)","fetched_at":"x","official":true},
             "evidence":[],"extractor":null,"verified":true,"status":"active"}]}]}
        """
        let urlDecoded = decodeOrDie("leaky-url", urlPayload)
        let up9 = urlDecoded.pages[0]
        let uq9 = urlDecoded.pages[0].promotions[0]
        check(!up9.url.contains(FAKE_SK), "内存页级 url 无假 key 原文（解码边界已脱敏）")
        check(up9.url.contains("***REDACTED***"), "内存页级 url 含掩码（正面产物，不只断「不含」）")
        check(!uq9.source.url.contains(FAKE_SK), "内存 source.url 无假 key 原文（spec §3.2 点名字段）")
        check(uq9.source.url.contains("***REDACTED***"), "内存 source.url 含掩码")
        check(up9.url.hasPrefix("https://help.aliyun.com/billing?api_key="),
              "脱敏只动 key 段：url 前缀逐字保留（redact 保前 6 位，其余部分原样）")

        // 落盘通路一：decode 后的干净值经 save()（第二层此处为不动点 no-op）
        let up9Page = up9.asPage()
        try! PromotionStore.save(PromotionSnapshot(schema: 1, updatedAt: "x",
                                                   promotions: [uq9], pages: [up9Page]), in: tmp)
        let urlDisk = try! String(contentsOf: PromotionStore.promotionsURL(in: tmp), encoding: .utf8)
        check(!urlDisk.contains(FAKE_SK), "promotions.json 磁盘字节无假 key 原文（页级 url + source.url 两处）")
        check(urlDisk.contains("***REDACTED***"), "promotions.json 磁盘字节含掩码")

        // 落盘通路二：未经 decode 的原始值直接喂 save()（== 8 同模式）——
        // 这才是第二层对 url 的独立性证据，decode 路径只证明了第一层。
        let rawURLPage = PromotionPage(line: "gw-x", url: leakyURL, status: .ok, httpStatus: 200,
                                       bytes: 1, visibleChars: 55, fingerprint: "sha256:x",
                                       error: nil, note: nil, truncated: false, unchanged: false)
        let rawURLPromo = Promotion(
            id: "p9b", line: "gw-x", title: "t", vendor: nil, models: [], window: nil,
            discount: nil, eligibility: nil,
            source: PromotionSource(url: leakyURL, fetchedAt: "x", official: false),
            evidence: [], extractor: nil, verified: false, status: .active,
            kind: .limitedTime, validFrom: nil, validUntil: nil)
        try! PromotionStore.save(PromotionSnapshot(schema: 1, updatedAt: "x",
                                                   promotions: [rawURLPromo], pages: [rawURLPage]),
                                 in: tmp)
        let rawURLDisk = try! String(contentsOf: PromotionStore.promotionsURL(in: tmp), encoding: .utf8)
        check(!rawURLDisk.contains(FAKE_SK), "第二层独立覆盖 url：未脱敏值直接落盘也被洗（page.url 与 source.url）")
        check(rawURLDisk.contains("***REDACTED***"), "第二层洗过的落盘字节含掩码")

        // state.json 通路：fingerprints 键契约（见 PromotionState.fingerprints 契约注释）
        let fpKey = PromotionURLContract.storageKey(fromRaw: leakyURL)
        check(!fpKey.contains(FAKE_SK), "指纹键不含 key 原文（原始 url 做键 = 带 key 的 url 以字典键身份落盘）")
        st.fingerprints[fpKey] = "sha256:x"
        try! PromotionStore.saveState(st, in: tmp)
        let stateDisk = try! String(contentsOf: PromotionStore.stateURL(in: tmp), encoding: .utf8)
        check(!stateDisk.contains(FAKE_SK), "state.json 磁盘字节无假 key 原文（fingerprints 键通路）")
        // 🔴 这条原先是 `stateDisk.contains("***REDACTED***")`，断言「脱敏后的键真的落了盘」。
        //   键改成 sha256 摘要后掩码不再出现在键里，照旧写会**假红**——不是行为退化，
        //   是「键真的落了盘」的正面证据换了形式：现在是摘要串本身出现在磁盘字节里。
        //   📐 换形式后**仍承重**（实测 M1：两个 `storageKey` 都不过摘要 → 这条红，
        //   与 C1/C3 同批，共 3 红）。所以这不是把断言改软了，是换了个更硬的正面证据。
        //   ⚠️ 一个隐式依赖（delta 复审实测指出，值得钉住）：JSONEncoder **默认把 `/` 转义成
        //   `\/`**。正常路径下 fpKey 是 64 位十六进制、**不含 `/`**，所以 `contains` 比的是原样字节；
        //   而 M1 下键退化成 `https://…***REDACTED***`（**含 `//`**），落盘后磁盘字节里是 `\/\/`，
        //   这条红的**直接机理是斜杠转义**，不是「键被丢掉」。两者都判红、结论不变，但：
        //   🔴 若将来 digest 换成含 `/` 的编码（如标准 base64 字母表），**正常路径会假红**。
        //      改编码时必须同步改这条（改用 `.withoutEscapingSlashes`，或改成比对 decode 回来的键）。
        //   ✅「fpKey 不含 `/`」这半句**不是我顺手写的，它有本文件内的观测前提**：C1
        //      （`adjKey.count == 64 && adjKey.allSatisfy { "0123456789abcdef".contains($0) }`）——
        //      它断言键**只由十六进制字符组成**，`/` 不在那个集合里，所以 C1 绿 ⇒ 键不含 `/`。
        //      C1 当前全绿（`CHECKS=96`、❌0 行）。
        //   🔴 反向也要说清：若哪天 C1 转红（编码换了、或 digest 被绕过），本条会**跟着假红**，
        //      而红的样子与「键真的没落盘」**长得一样**——那时要先看 C1，别直接怀疑落盘。
        //      这是「一条断言的绿依赖另一条断言的绿」的实例：C1 是本条的观测前提（候选㉔ 同族）。
        check(stateDisk.contains(fpKey), "state.json 磁盘字节含摘要键（键真的落了盘，不是被丢掉）")
        let st9 = PromotionStore.loadState(from: tmp)
        check(st9.fingerprints[PromotionURLContract.storageKey(fromRaw: leakyURL)] == "sha256:x",
              "存查同键：查表端同一函数命中（用原始 url 查会永久 miss → 每天重复通知）")
        check(PromotionURLContract.storageKey(fromDecoded: up9.url) == fpKey,
              "存端（decode 后 url 走 fromDecoded）与查端（原始 url 走 fromRaw）同键")
        // 🔴 此处**删掉**了一条断言，删断言必须记账：原文是 `up9.url == fpKey`，
        //   消息写「decode 一遍后的 url 本身即存储键（Task 7 存端直接用 p.url，不要再套
        //   storageKey）」。键改成摘要后它**恒假**（url 永不等于自己的摘要），而它要表达的
        //   意思已由上面那条 `storageKey(fromDecoded:) == fpKey` 承接；留着只会是红或废话。
        //   另一条被删的旧消息文本「存端（decode 后 url 再过 storageKey）…同键」字面
        //   推荐的正是新契约**禁止**的两遍拼法，一并改掉。CHECKS 变化见台账第 20 节。

        // 不动点（Swift 侧自己测，不许引用 Python 侧修正 26 的结论——两侧 pattern
        // 是两份独立拷贝，本项目已 4 次静默漂移）：对**单把密钥**的 url，
        // redact(redact(u)) == redact(u)。
        // 🔴 措辞更正（2026-10-10 复审抓出，行为零影响但注释是边界的唯一依据）：
        //   这**不是**「存端一遍/查端一遍仍同键」的数学基础。基础是「同一个函数、
        //   同一个原始输入、两端各施加**恰好一遍**」，与不动点无关。恰恰相反——
        //   不动点是下面 B 那条断言**证伪**的东西（相邻密钥形状要二遍才达不动点），
        //   把它当基础会让人推出「多洗一遍也没事」，那正是被禁的写法。
        // ⚠️ 全称命题不成立，所以下面两条断言的样本必须是**单把密钥**的 url；
        //   相邻形状的行为由再下面的 A / B 两条钉住。
        let onceURL = SecretRedactor.redact(leakyURL)
        check(SecretRedactor.redact(onceURL) == onceURL,
              "单把密钥的 url 二遍达不动点：redact(redact(u)) == redact(u)")
        check(SecretRedactor.redact(SecretRedactor.redact("https://x.com/p?api_key=" + FAKE_TOKEN))
                == SecretRedactor.redact("https://x.com/p?api_key=" + FAKE_TOKEN),
              "不动点对第二把假 key 的单密钥 url 也成立")
        check(SecretRedactor.redact("https://help.aliyun.com/billing") == "https://help.aliyun.com/billing",
              "无 key 的 url 过 redact 不变形（普通配置零影响）")

        // 🔴 反例存档（2026-10-10 **Swift 侧实测**，不是推理、也不引 Python 侧修正 26 的结论）：
        // url 里两把密钥形状**紧邻**时，redact 一遍 != 两遍——P0 的 (?<![A-Za-z0-9])
        // lookbehind 挡住第一遍的 sk- 段（它前面是 alnum），P1 先把 ark 段 mask 成
        // ***REDACTED*** 后 sk- 前面变成 '*'（非 alnum）→ 第二遍 P0 才放行。
        //
        // 🔴 而「一遍没洗干净」对这个键来说**不只是功能问题，是泄漏**（2026-10-10 质量
        //   复审 Issue 1）：`saveState` 只有 decode 那一层脱敏，所以「一遍产物」就是
        //   state.json 的磁盘字节，残留的 key 原文直接落盘。修法是键过 sha256 摘要
        //   （见 PromotionURLContract）——摘要单向，键不再需要「洗干净」这个前提。
        //   ⚠️ 但摘要**只**关掉安全失效模式：存端拿不到原始 url，两端仍须各洗恰好一遍，
        //   否则摘要不同 → 永久 miss。所以下面 C 组守安全、A/B 守遍数，**一组都不能删**。
        //
        // 键规则是「**两端都恰好一遍，再过摘要**」，不是「洗到干净为止」：
        //   存端写 fingerprints[storageKey(fromDecoded: p.url)]
        //   查端写 fingerprints[storageKey(fromRaw: 原始 url)]
        // 存端多洗一遍、或在 saveState 里给字典键「补一道脱敏」求纵深防御，都会把遍数
        // 变成两遍 → 与查端不同摘要 → 指纹**永久 miss** → unchanged 永不成立 → 用户每天
        // 被重复通知同一个活动，且**全程无报错**。（save() 的第二层可以洗是因为它洗的
        // 是**值**、不参与精确匹配；字典**键**多洗一遍等于换了一把钥匙。）
        let adjacentURL = "https://x.com/p?sig=" + FAKE_ARK + FAKE_SK
        let adjPayload = """
        {"schema":1,"fetched_at":"x","today":"2026-10-10","pages":[
          {"line":"gw-adj","url":"\(adjacentURL)","status":"ok","http_status":200,"bytes":1,
           "visible_chars":55,"fingerprint":"sha256:x","error":null,"note":null,
           "truncated":false,"unchanged":false,"promotions":[]}]}
        """
        let adjDecoded = decodeOrDie("adjacent-url", adjPayload)
        let adjURLDecoded = adjDecoded.pages[0].url

        // C 组（**承重**，Issue 1 的守卫）：摘要形式让「一遍没洗干净」不再等于「原文落盘」。
        //   （为什么这是泄漏而不只是功能问题：`saveState` **只有一层脱敏**，所以
        //    「decode 一遍的产物」**就是** state.json 的磁盘字节。）
        //   C2 是 C1/C3 的**观测前提**：若一遍产物本来就干净，C1/C3 就是空转
        //   （候选㉔：断言绿可能因为根本没踩到洞，而不是因为洞被堵了）。
        //
        //   🔴 C2 的价值**已实测**（2026-10-10，`/tmp/mut20`，台账第 20.5 节），不是自称：
        //     M5（删 P0 的 lookbehind）→ **C2 红、C1/C3 仍绿**。这正是 C2 存在的理由：
        //     那时 `redact` **一遍就洗干净了**，C3 的绿于是**不再是摘要的功劳**（没有摘要
        //     它也绿）——C3 从「洞被堵住了」退化成空转。没有 C2，M5 只会显示 B 一条红，
        //     就会有人据此得出「C3 是恒真式、可以删」的**错误结论**。
        //     M1（两个 storageKey 都不过摘要）→ **C1/C3 红、C2 仍绿**。
        //     → 三条的检出域互不重叠，**删任何一条都会留下一个看不见的洞**。
        let adjOnce = SecretRedactor.redact(adjacentURL)
        check(adjOnce.contains(FAKE_SK),
              "C2 观测前提：相邻形状下 redact **一遍**的产物仍含第二把 key 原文（洞真被踩到）")
        let adjKey = PromotionURLContract.storageKey(fromRaw: adjacentURL)
        check(adjKey.count == 64 && adjKey.allSatisfy { "0123456789abcdef".contains($0) },
              "C1 指纹键是 64 位小写十六进制摘要（结构上不可能含任何形状的明文）")
        check(!adjKey.contains(FAKE_SK),
              "C3 相邻形状下指纹键不含 key 原文（一遍没洗干净的残留被摘要挡在 state.json 外）")

        // A（**承重**）：走真 decode 路径，不是拿 storageKey 与 redact 互比（那是恒真）。
        //   检出域＝「某一端的遍数写错」。实测：M3（删 decode 层三处 url 脱敏）→ A 红；
        //   M4（`fromRaw` 洗两遍）→ A 红。摘要化**没有**让这条退化——遍数一致的要求原封不动。
        check(PromotionURLContract.storageKey(fromDecoded: adjURLDecoded) == adjKey,
              "A 相邻密钥形状的 url：存端（decode 后恰好一遍）与查端（恰好一遍）仍同键")
        // B（**承重**，检出域与 A 不同——标注按候选㉖ 用变异实测，不靠自称）：
        //   把**已洗过一遍**的值再喂 `fromRaw`（= 被禁止的两遍拼法）会得到**不同**的键。
        //   它守的是「存端禁止再洗一遍 / saveState 禁止给键补脱敏」这条禁令的
        //   **事实基础**：P0 的 `(?<![A-Za-z0-9])` lookbehind 存在。
        //   🔴 历史更正（保留，别删）：本注释原先写「我**没能**构造出让它变红的变异，
        //     所以它只是诊断性」——**那句是假的**。2026-10-10 由 Task 5 spec 复审者提出、
        //     我独立复现（`/tmp/mut-e.sh`，不引用其日志）。教训是候选㉖ 的补句：
        //     判「只是诊断性」之前必须至少试过「改被测函数本身的实现/pattern」这一类变异
        //     ——**想不出 ≠ 不存在**。
        //   📐 本轮（键改 sha256 摘要之后）重测，`/tmp/mut20`、台账第 20.5 节，
        //     基线 `CHECKS=96`、五条变异全部是**断言红**（`CHECKS=` 照常打印）：
        //       M3 删 decode 层 url 脱敏 → 11 红（含 A、B）
        //       M4 `fromRaw` 洗两遍      → **2 红：A + B**
        //       M5 删 P0 的 lookbehind   → **2 红：C2 + B，A 仍绿**
        //     **M5 里 A 仍绿 ⇒ B 的红不是连带红**，它有独立检出域（与旧轮同一判据，复测成立）。
        //   ⚠️ 旧注释那些数（`CHECKS=90`、mutA′ 10 红、mutD「恰好 A 1 红」、mutE「恰好 B 1 红」）
        //     是**键改摘要之前**的口径，**已全部作废、不要沿用**。尤其 mutD：我当时预期
        //     「恰好 A 1 红」，**实测是 A + B 两条红**。
        //     → 红数**必须每轮重测**，不能从上一轮搬（候选㉒）。
        //   🔴 机理（18:25 探针实测逐遍值定案；此处原先写反过，delta 复审抓出，已改）：
        //     记 p0=原始、p1=redact(p0)…，相邻密钥形状下**第二遍即达不动点**：
        //       p1 ≠ p2，**p2 == p3 == p4**（实测输出，不是推理）。
        //     M4（`fromRaw` 洗两遍）下 B 断言的两端：
        //       `adjKey` = digest(redact(redact(p0))) = **digest(p2)**
        //       B 左值   = storageKey(fromRaw: p2)  = digest(redact(redact(p2))) = **digest(p4)**
        //     因 p4 == p2，**两端收敛成同一个键** → B 断言的「≠」翻假 → **红**。
        //     ⚠️ 我原先写的是「B 左值变成 digest(pass3)、相邻形状下 pass2 ≠ pass3，所以 B 也红」——
        //        **前提假**（实测 p2 == p3）**且方向反**（左值 ≠ adjKey 推出的是 B **绿**）。
        //        红数本身来自实测所以是对的，错的是事后补写的机理；而这条注释恰好在教
        //        「怎么预测变异红数」，写反会让人带着反向心智模型做下一轮。
        //        教训：**实测数值对了不等于机理对了**，机理也要能被探针复现（候选㉓）。
        //     正常路径 B 为绿的理由也一并钉住：adjKey=digest(p1)、B 左值=digest(p3)，p1 ≠ p3。
        check(PromotionURLContract.storageKey(fromRaw: adjURLDecoded) != adjKey,
              "B 反例存档：相邻形状下把已洗过的 url 再喂 fromRaw（=两遍）得到不同的键")

        // 🔴 出网边界不受影响：传给 promo-fetch.py 的 url 必须仍是原始的（含 key）。
        // 脱敏若被加到清单构造侧，脚本会去抓一个不存在的地址且不报错（静默失效）。
        // outbound 是恒等函数，这条断言守的正是「将来有人往出网侧加脱敏」。
        check(PromotionURLContract.outbound(leakyURL) == leakyURL
                && PromotionURLContract.outbound(leakyURL).contains(FAKE_SK),
              "出网边界拿到原始 url（含 key）：脱敏只在解码/落盘边界，不在清单构造侧")

        print("")
        print("CHECKS=\(checkCount)")
        if failures == 0 { print("全部通过 ✅") } else { print("\(failures) 项失败 ❌"); exit(1) }
    }

    static func statusPayload(_ statusJSON: String) -> String {
        return """
        {"schema":1,"fetched_at":"x","today":"2026-10-10","pages":[
          {"line":"l","url":"u","status":\(statusJSON),"http_status":null,"bytes":0,
           "visible_chars":55,"fingerprint":null,"error":"HTTP 403 Forbidden",
           "note":null,"truncated":false,"unchanged":false,"promotions":[]}]}
        """
    }
}
