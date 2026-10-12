#!/usr/bin/env python3
"""优惠雷达抓取器。

读 stdin 的 manifest，抓公开定价/活动页，抽正文、算指纹、按规则提取情报，输出 JSON。

设计不变量（改这个文件前先读）：
  1. 无状态。不读不写任何自己的存储；指纹比对由调用方（Swift）做。
  2. 退出码 0 = 跑完了（即使每一页都抓失败）；1 = 脚本自身崩了。
     「有没有情报」和「脚本坏没坏」是两件事，绝不能用同一个退出码表达。
  3. 每一种「空」都必须有自己的名字（页级四态），并把判据（visible_chars / http_status /
     error / note）一起回传。本文件的诞生原因就是一次工具把超时静默报成 "No results"，
     差点让人误判「qwen 没有夜间优惠」。
  4. 密钥卫生：script/style/noscript/template 整块丢弃，不进正文、不进指纹、不落盘。
"""

import argparse
import hashlib
import html as html_module  # 别名：形参名 html 是钉死的公开接口，不许撞
import json
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

# T4-R2：HTTP 4xx/5xx 的 body 摘要要过脱敏再进 error（AGENTS.md「密钥不进仓库、
# 不进日志、不进 UI 回显」——error 会落盘、会回显，错误页不豁免）。
# redact 与 scripts/claude-rename、Swift SecretRedactor 是同一套模式（cchandoff.py:200）。
# 🔴 两种执行上下文的 sys.path 不同，两条分支缺一不可（各有测试钉住）：
#   作为模块被 import（unittest / importlib，cwd=仓库根）→ `scripts.cchandoff` 可解析；
#   作为脚本直跑（python3 scripts/promo-fetch.py，sys.path[0]=scripts/）→ 只能 `cchandoff`。
try:
    from scripts.cchandoff import redact
except ImportError:
    from cchandoff import redact

SCHEMA = 1
DEFAULT_TIMEOUT = 25
DEFAULT_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ccpod-promo-radar/1"

# 可见正文少于此字符数 → 判为 JS 壳页。校准依据（2026-10-10 实测，均为 visible_text 反转义后的值）：
#   阿里计费页 107606 字符 → ok；火山 docs 页 55 字符 → 壳。
#   ⚠️ 反转义会让正文变短（实体如 &lt; 4 字符 → < 1 字符），阿里页实测缩短 1743 字符（1.6%）。
#      实体极密集的页理论上可能被推下阈值，但方向是保守的：多判成壳页是**看得见**的失败态
#      （面板回传 visible_chars），不会把失败判成成功、不会漏报优惠。
# ⚠️ 500–3000 字符是已知误判区间（spec §0.1）。所以两个失败态都必须回传 visible_chars，
#    让人在面板上一眼看出「是真壳页，还是我把正常页判错了」。
MIN_VISIBLE_CHARS = 500

# 响应体体积上限（T4-R1）。校准：阿里计费页 2026-10-09 实测 1.96 MB，4 MiB 留一倍余量；
# 超过这个量的「定价页」基本是下载站/错 URL。超限**不是错误**（退出码仍 0，照常解析
# 截断后的正文），但必须留下**可见信号**，两路冗余：
#   ① 页记录的 truncated: true（进 JSON，Swift 面板可显示）；
#   ② stderr 诊断行（人肉调试通道）。
# 没有信号的话，「正则没匹配上」和「正文被截掉了」在面板上长得一模一样——
# 尤其截断点落进未闭合 <script> 时，TAG_RE 的 |\Z 分支会把余下正文全吞掉，
# 页会退化成 unsupported-js-page，人只会去怀疑阈值。
MAX_FETCH_BYTES = 4 * 1024 * 1024

# 正则三处写法的理由：
#   [^>]*>          —— 兼容 <script type="text/javascript"> 这类带属性的开标签。
#   </\1\s*>        —— 兼容 </script > 尾随空白（end tag 允许，是 HTML 合法闭合写法）。
#   |\Z             —— 未闭合时吞到文件末尾。⚠️ 这是故意的，不是 bug：按 HTML 语义未闭合的
#                      <script> 本来就会吞掉其后全部内容；而且宁可少读正文被判成
#                      unsupported-js-page（四态里看得见的失败态，面板会显示 visible_chars），
#                      也绝不能把 script 里的字串当正文漏出去（进指纹、进落盘、进回显）。
TAG_RE = re.compile(r"<(script|style|noscript|template)\b[^>]*>.*?(?:</\1\s*>|\Z)", re.S | re.I)
ANY_TAG_RE = re.compile(r"<[^>]+>")
WS_RE = re.compile(r"\s+")


def visible_text(html):
    """抽可见正文：整块丢弃 script/style/noscript/template，去所有标签，还原实体，折叠空白。

    🔴 顺序不可换：**先剥标签，后反转义**。反过来会让页面里以 `&lt;script&gt;` 形式
    写出的文字先变成真标签、再被整块删掉。
    实测（对仓库内 fixture `scripts/tests/fixtures/promo/aliyun-billing-2026-10-09.html`；
    本机可用 `python3 .local/verify-fixture-order.py` 复现，但 `.local/` 被 .gitignore
    忽略、克隆者拿不到——自包含复现：把本函数里两步剥标签与 `html_module.unescape`
    的顺序手工交换（先 unescape 再剥标签），对 fixture 跑即得下行数字）：
        正确顺序 → 可见正文 3562 字符、峰谷行命中 7 条
        错误顺序 → 可见正文  225 字符、峰谷行命中 0 条（93.7% 内容被吃掉）
    ⚠️ 225 < MIN_VISIBLE_CHARS(500)，所以错误顺序不只是少几行：页级状态会从 `ok`
       直接翻成 `unsupported-js-page`，面板上显示一个**看起来合理但完全错误**的原因。
    反转义在折叠空白之前也有意：`&nbsp;` → `\\xa0`，Python 3 的 `\\s` 匹配 `\\xa0`，
    这样 `a&nbsp;&nbsp;b` 能正确折叠成 `a b`；放到折叠之后就折叠不掉了。
    """
    text = TAG_RE.sub(" ", html or "")
    text = ANY_TAG_RE.sub(" ", text)
    text = html_module.unescape(text)
    return WS_RE.sub(" ", text).strip()


def fingerprint(text):
    """正文指纹。页没变就跳过解析（省钱、省时间），但**绝不**跳过上报。"""
    return "sha256:" + hashlib.sha256((text or "").encode("utf-8")).hexdigest()


def fetch(url, timeout=DEFAULT_TIMEOUT, ua=DEFAULT_UA):
    """返回 (http_status, html, error, truncated)。error 非 None 即抓取失败。

    HTTP 4xx/5xx 要保留状态码：403（被反爬挡）和 404（URL 填错）的修法完全不同。
    4xx/5xx 的 body 摘要（前 1KB → visible_text → redact）拼进 error：
    反爬/网关错误页往往把「为什么被拒」写在 body 里，光有状态码看不出。
    超过 MAX_FETCH_BYTES 的响应体截断到上限并置 truncated=True（T4-R1，见常量注释）。
    """
    # 🔴 Request 构造必须在 try **里面**（2026-10-10 实测抓出）：manifest 塞进非字符串
    #    url（如 123）时 Request() 自己就抛 ValueError，放 try 外会击穿到顶层兜底、
    #    整个进程退 1——一页的坏 manifest 条目不该弄丢全部页的输出。
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": ua, "Accept-Language": "zh-CN,zh;q=0.9"})
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read(MAX_FETCH_BYTES + 1)  # 多读 1 字节只为探测超限
            truncated = len(raw) > MAX_FETCH_BYTES
            if truncated:
                raw = raw[:MAX_FETCH_BYTES]
            charset = resp.headers.get_content_charset() or "utf-8"
            return resp.status, raw.decode(charset, errors="replace"), None, truncated
    except urllib.error.HTTPError as exc:
        snippet = http_error_snippet(exc)
        error = "HTTP %s %s" % (exc.code, exc.reason)
        if snippet:
            error = "%s body: %s" % (error, snippet)
        # 🔴 咽喉点整体脱敏（2026-10-10 复审 A）：exc.reason 是服务端可控文本——
        #    反爬/网关把「为什么被拒」写在那里、把 Authorization 回显进去都是真实形态。
        #    error 进 stdout JSON → 落盘 ~/.claude/ccpod-promotions.json → 面板与
        #    macOS 通知逐字回显，与 body 摘要同一条硬约定（AGENTS.md 密钥纪律）。
        #    在 return 处包、而不是只在拼 snippet 那行包：将来谁再往 error 拼第三段，
        #    咽喉点自动覆盖——「每段各自在源头脱敏」这种不变量靠人记不住。
        #    snippet 在 http_error_snippet 内部已 redact 过一次，这里会脱敏两次。
        #    🔴 二次脱敏安全的真正理由是**单调**，不是「幂等」——严格幂等不成立
        #    （2026-10-10 delta 复审 M-1，协调者独立复现）：P1(ark-) 的 mask 产物把
        #    相邻 token 前的 alnum 换成 `*`，解除 P0(sk-) 的 `(?<![A-Za-z0-9])`
        #    lookbehind 封锁，于是第二遍能 mask 到第一遍漏掉的那截。
        #    实测三条：mask 计数只增不减 / 已 mask 的 span 不会被洗回原文 /
        #    第二遍即达不动点（r3==r2，20000 串 fuzz 无一例外）。方向是「更严」，
        #    所以重复调用安全——钉住它的是 RedactMonotonicityTest。
        #    RedactIdempotencyTest 的 7 个样本都是单形状孤立串、不含这种相邻，
        #    它的等值断言依然成立且有意义，别把相邻样本塞进去（会红）。
        return exc.code, "", redact(error), False
    except Exception as exc:
        # URLError / socket.timeout / SSL / DNS 全归这一类。
        # 带上异常类型名：让面板能区分「超时」和「证书错」和「域名不存在」。
        # M-1（2026-10-10 复审）：异常消息也可能带密钥形状（代理把 Authorization 回显进
        # URLError reason 是真实形态）。error 落盘（~/.claude/ccpod-promotions.json）、
        # 回显，与 T4-R2 的错误页 body 同一条硬约定——过 redact，不豁免。
        return None, "", redact("%s: %s" % (type(exc).__name__, exc)), False


def http_error_snippet(exc, limit=1024):
    """HTTPError 的 body 摘要：读出来 → 前 1 KB → visible_text → redact（T4-R2）。

    🔴 顺序就是防线：visible_text 先把 script/style 整块丢掉（错误页内联 JS 里的
    追踪串、密钥形状的字串不该进 error），redact 再把残留在可见正文里的密钥形状
    mask 掉。error 字段落盘（~/.claude/ccpod-promotions.json）、回显，两道都不能省。
    body 读不出来（连接已断/服务端 RST）就给空串——摘要失败不能连累 error 本身。
    """
    try:
        try:
            raw = exc.read(limit)
        finally:
            # M-2（2026-10-10 复审）：read 抛异常也必须关 fp——原来 close 只在成功
            # 路径上，body 读不出来时连接泄漏。语义不变：读不出仍返回空串。
            exc.close()
    except Exception:                                       # noqa: BLE001
        return ""
    text = visible_text(raw.decode("utf-8", errors="replace"))
    if not text:
        return ""
    return redact(text)


def fetch_with_retry(url, attempts=2, **kwargs):
    """重试只在网络层失败时发生；HTTP 4xx/5xx 不重试（对方明确拒绝了，再打是骚扰）。"""
    result = (None, "", "no attempt made", False)
    for _ in range(max(1, attempts)):
        result = fetch(url, **kwargs)
        status, _html, error, _truncated = result
        if error is None:
            return result
        if status is not None:  # 拿到了 HTTP 状态码 = 对方回话了，不重试
            return result
    return result


def page_status(error, visible_chars, matched_rules, promotions):
    """页级四态。判定顺序即优先级，不要调换。"""
    if error:
        return "fetch-failed"
    if visible_chars < MIN_VISIBLE_CHARS:
        return "unsupported-js-page"
    if matched_rules == 0 or promotions == 0:
        return "parse-failed"
    return "ok"


def status_note(error, visible_chars, matched_rules, promotions):
    """parse-failed 的子原因。其他态返回 None。

    no-rule-matched-url  → 要写新规则（或这个页根本不是定价页）
    rule-matched-no-hit  → 规则命中了 URL 但正文变了，正则要修
    """
    if error or visible_chars < MIN_VISIBLE_CHARS:
        return None
    if matched_rules == 0:
        return "no-rule-matched-url"
    if promotions == 0:
        return "rule-matched-no-hit"
    return None


DEFAULT_DAYS = ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]

# evidence 摘录的截断上限。校准依据（2026-10-10 实测）：本规则两条真实摘录分别
# 45 / 79 字符 —— 200 卡在「最长真实摘录 79（留足余量）」与「规则正则意外吞进
# 长段正文」之间。摘录是让人回官方页对质的锚点，不是正文转储，不需要更大。
# 🔴 不变量：截断只做 `[:EVIDENCE_MAX_CHARS]` 前缀截短，截断结果仍是正文的
#    **逐字子串**，所以 spec §5.2 条件 4 的 substring 校验不受截断影响
#    （test_verified_true_and_why 的逐条 assertIn 靠的就是这个性质。
#    若将来改成截断后拼省略号之类的修饰，子串性质立刻破，那条测试会红）。
EVIDENCE_MAX_CHARS = 200


def load_rules(path):
    """读规则数据。文件坏了直接抛——规则是这个功能唯一会持续烂掉的部分，
    静默降级成「没优惠」是最坏的失败方式。

    🔴 缺 class / class 值不认识的规则在**加载层**拒收并往 stderr 留痕（纪律 5，
    修正 18）：等 parse_page 运行时才静默跳过 = 静默丢真情报。class 只有
    peak_valley（A 类，可 verified）和 promotion（B 类）两个合法值——第三个值
    流到 Swift 的枚举解码上就是整页 Codable 失败，所以在这层就挡掉。
    parse_page 里的 `rule.get("class", "promotion")` 仍是解析层的第二道兜底
    （护的是绕过 load_rules 直接调 parse_page 的调用方，如单测），两层并存不冲突。
    """
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    kept = []
    for i, rule in enumerate(data.get("rules", [])):
        if isinstance(rule, dict) and rule.get("class") in ("peak_valley", "promotion"):
            kept.append(rule)
            continue
        print("规则缺 class 或 class 不合法，已拒收（该规则不参与解析）#%d: %s"
              % (i, json.dumps(rule, ensure_ascii=False)[:200]), file=sys.stderr)
    return kept


def load_rule_meta(path):
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    return data.get("official_domains", []), data.get("family_labels", {})


def rule_matches_url(rule, url):
    """两条定位条件都必须满足；两条都没写 → 永不匹配（不做「万能规则」）。"""
    if not isinstance(url, str):
        # 非字符串 url（manifest 塞坏了）在 fetch 层已是页级 fetch-failed；
        # 这里必须返回 False 而不是 `dom not in url` 的 TypeError——
        # build_page 对抓失败的页也要算 matched，不能被坏条目击穿成进程级崩溃。
        return False
    dom = rule.get("url_domain_contains")
    path = rule.get("url_path_contains")
    if not dom and not path:
        return False
    if dom and dom not in url:
        return False
    if path and path not in url:
        return False
    return True


def family_of(model):
    """deepseek-v4.1-flash → deepseek。按 family 聚合成一条情报，
    否则同一个系列 3 个型号会刷出 3 条重复通知。"""
    return re.split(r"[-.]", model)[0]


def normalize_hhmm(value):
    """页面上写 8:00，面板和倒计时要 08:00。"""
    parts = (value or "").split(":")
    if len(parts) != 2:
        return value
    return "%02d:%s" % (int(parts[0]), parts[1])


def parse_window(rule, text):
    spec = rule.get("window") or {}
    pattern = spec.get("pattern")
    if not pattern:
        return None
    m = re.search(pattern, text)
    if not m:
        return None
    g = m.groupdict()
    return {
        "tz": spec.get("tz", "Asia/Shanghai"),
        # 优惠窗口是**闲时**。存忙时窗口会让倒计时提醒用户在最贵的时候开机。
        "start": normalize_hhmm(g.get("off_start")),
        "end": normalize_hhmm(g.get("off_end")),
        "days": spec.get("days", DEFAULT_DAYS),
        "ends_next_day": bool(spec.get("ends_next_day", False)),
    }


def parse_items(rule, text):
    spec = rule.get("items") or {}
    pattern = spec.get("pattern")
    if not pattern:
        return []
    rows = []
    for m in re.finditer(pattern, text):
        g = m.groupdict()
        try:
            peak_in = float(g["peak_in"])
            off_in = float(g["off_in"])
            peak_out = float(g["peak_out"])
            off_out = float(g["off_out"])
        except (KeyError, TypeError, ValueError):
            # 🔴 2026-10-10 04:45 修正（修正 14）：原文这里漏了 `except` 关键字，
            #    逐字粘进 promo-fetch.py 会让整个模块 SyntaxError → Task 3 的测试**全部**红。
            #    是用「机械抽出代码块 + ast.parse」查出来的，肉眼读过一遍没看出来。
            continue
        if peak_in <= 0 or peak_out <= 0 or off_in <= 0 or off_out <= 0:
            continue
        rows.append({
            "model": g["model"],
            "family": family_of(g["model"]),
            "scope": g.get("scope"),
            # 保留 2 位小数：官方页把 4.8125 印成 4.813，不四舍五入会得到 0.5001，
            # 于是「各模型折扣一致」这个判断会假失败。
            "ratio_in": round(off_in / peak_in, 2),
            "ratio_out": round(off_out / peak_out, 2),
        })
    return rows


def lifecycle(valid_from, valid_until, today):
    """ISO 日期字符串可以直接按字典序比。边界都算 active：
    今天开始 = 已经能用；今天结束 = 今天还能用。"""
    if valid_from and valid_from > today:
        return "upcoming"
    if valid_until and valid_until < today:
        return "expired"
    return "active"


def discount_of(rows):
    """返回 {ratio, text, short}。text 是完整句（面板正文用），short 是标题用的短语。

    折扣不统一就给 ratio=None。宁可少说一句，也不说一个错的数字。
    """
    ratios = set()
    for r in rows:
        ratios.add(r["ratio_in"])
        ratios.add(r["ratio_out"])
    if len(ratios) != 1:
        return {"ratio": None,
                "text": "闲时折扣各型号/地域不一，详见官方页",
                "short": "闲时更便宜"}
    ratio = ratios.pop()
    return {"ratio": ratio,
            "text": "闲时约为忙时的 %g 折" % (ratio * 10),
            "short": "闲时 %g 折" % (ratio * 10)}


def collect_evidence(rule, text):
    """返回 (命中的原文列表, 是否全部命中)。
    evidence 必须是正文的**逐字子串**——它是 verified 的依据，改写成自己的话就等于编造。"""
    found = []
    for pattern in rule.get("evidence", []):
        m = re.search(pattern, text)
        if not m:
            return found, False
        found.append(m.group(0)[:EVIDENCE_MAX_CHARS])
    return found, bool(found)


def is_official(url, official_domains):
    """这个 URL 是不是官方页。

    🔴 **必须按 host 比，绝不能按子串比。** 直觉写法 `any(d in url for d in …)`
    会被 `https://evil.com/?x=help.aliyun.com` 骗过 —— 那个页面的正文完全由
    攻击者控制，却会被标成 `official: true`。而 `official` 是 `verified` 的四个
    必要条件之一，`verified` 又是**弹通知的唯一前提**（`isAlertable`）。
    连起来就是：攻击者用一个自己控制的页面，能让 ccpod 替他弹一条
    「🌙 已核实的新优惠」的桌面通知。这是本功能最坏的失效方式，
    因为它把「ccpod 核实过」这个信任标记借给了第三方。

    `endswith("." + d)` 而不是 `endswith(d)`：后者会放行 `help.aliyun.com.evil.com`。
    """
    host = (urlparse(url or "").hostname or "").lower()
    if not host:
        return False
    for d in official_domains:
        d = (d or "").strip().lower()
        if not d:
            continue
        if host == d or host.endswith("." + d):
            return True
    return False


TZ_LABELS = {"Asia/Shanghai": "北京时间"}


def tz_label(tz):
    """时区的人话标签。

    时段钟点是**页面声明时区**的，而标题会进通知正文 —— 通知里没有别的地方标时区，
    光写「22:00」对不在那个时区的人就是一个错的钟点。所以在标题里标一次。
    没登记过的时区直接回退成标识符（`Europe/Berlin`）：宁可显示一个用户要查一下的名字，
    也不显示一个看起来像本地时间的错钟点。
    """
    return TZ_LABELS.get(tz or "", tz or "")


def parse_page(rules, text, url, line, fetched_at, today,
               official_domains=None, family_labels=None):
    """对一个页的正文跑所有匹配的规则，按 family 聚合，返回情报列表。"""
    official_domains = official_domains or []
    family_labels = family_labels or {}
    out = []
    for rule in rules:
        if not rule_matches_url(rule, url):
            continue
        window = parse_window(rule, text)
        rows = parse_items(rule, text)
        if window is None or not rows:
            continue  # 页级 parse-failed，由调用方按 status_note 上报原因

        vf_pattern = (rule.get("valid_from") or {}).get("pattern")
        vf_match = re.search(vf_pattern, text) if vf_pattern else None
        valid_from = vf_match.group("valid_from") if vf_match else None

        evidence, evidence_ok = collect_evidence(rule, text)
        official = is_official(url, official_domains)
        # verified 四条件（spec §5.2 原文）：
        #   1. source.official == true（is_official 按 host 比白名单）
        #   2. class == "peak_valley"（A 类才谈「可核实」；B 类 promotion 永远 verified=False，
        #      否则面板会给限时优惠挂「已核实」、Task 6 的 isAlertable 两道闸一起失守）
        #   3. extractor 以 "rule:" 开头（本函数构造的 extractor 恒为 "rule:<id>"，结构性满足，
        #      不写字面比较 —— spec 原文的 `extractor == "rule"` 是前缀语义）
        #   4. evidence 非空且每条都是正文逐字子串（collect_evidence）
        # 🔴 window / rows 不在这四条里：它们是结构性前提（不命中直接 continue，根本不产条目），
        #    写进条件只会制造恒真项 —— 上一版注释就靠这两个恒真项把真条件 2、3 挤掉了，
        #    bug 因此藏了一整个 Task（2026-10-10 spec 复审抓出）。
        #    「不写进上面的清单」与「下面表达式仍保留 `window and rows`」并不矛盾：
        #    清单必须逐条对上 spec 的四条件（多列一个恒真项，下次复述 spec 就可能再挤掉真条件）；
        #    表达式里保留是**防御性冗余** —— 若上面的 `continue` 前置逻辑将来被改动，
        #    这里也不会静默放行出一个条目级前提已失守的 verified=True。别删它们。
        verified = bool(official and window and rows and evidence_ok
                        and rule.get("class") == "peak_valley")

        vendor = rule.get("vendor", "")
        rule_id = rule.get("id", "rule")

        by_family = {}
        for r in rows:
            by_family.setdefault(r["family"], []).append(r)

        for family in sorted(by_family):
            fam_rows = by_family[family]
            label = family_labels.get(family, family.capitalize())
            discount = discount_of(fam_rows)
            # span 用 discount["short"]：ratio 不统一时 short 是「闲时更便宜」，
            # 同一个格式串两种情况都成立，不需要分支。
            span = "%s–%s" % (window["start"], window["end"])
            if window["ends_next_day"]:
                span = "%s–次日 %s" % (window["start"], window["end"])
            span = "%s %s" % (span, tz_label(window["tz"]))
            title = "%s %s 系列 %s（%s）" % (vendor, label, discount["short"], span)
            out.append({
                "id": "%s-%s" % (rule_id, family),
                "line": line,
                # class 默认 promotion（B 类）而不是 peak_valley：漏写 class 的规则
                # 绝不能被静默升成 A 类 —— A 类可 verified=True、可弹通知。按「宁缺勿假」，
                # 默认只能往**少通知**的方向偏，不能往**多通知**偏。
                # （加载层已在 load_rules 拒收缺 class / 非法 class 的规则并往 stderr
                #  留痕——Task 4 落地。这层 get 默认值是第二道兜底，护的是绕过
                #  load_rules 直接调 parse_page 的调用方。两层并存，别删任何一层。）
                "class": rule.get("class", "promotion"),
                "title": title,
                "vendor": vendor,
                "models": sorted({r["model"] for r in fam_rows}),
                "window": window,
                "discount": discount,
                "eligibility": rule.get("eligibility"),
                "valid_from": valid_from,
                "valid_until": None,
                "source": {"url": url, "fetched_at": fetched_at, "official": official},
                "evidence": evidence,
                "extractor": "rule:%s" % rule_id,
                "verified": verified,
                "status": lifecycle(valid_from, None, today),
            })
    return out


# ═══════════════════════ Task 4：CLI 契约 ═══════════════════════
# stdin 读 manifest（[{"line","url","previous_fingerprint"}]），stdout 输出纯 JSON，
# 诊断一律走 stderr（Swift 用 JSONDecoder 直接吃 stdout，混一行 print 就整体解码失败）。

def default_rules_path():
    """规则文件与脚本同目录。装到 ~/.claude/bin/ 之后 cwd 是任意的，
    所以必须用 __file__ 解析，绝不能用相对路径。"""
    return str(Path(__file__).resolve().with_name("promo-rules.json"))


def now_iso():
    return datetime.now().astimezone().replace(microsecond=0).isoformat()


def today_iso():
    return datetime.now().astimezone().date().isoformat()


def build_page(line, url, previous_fingerprint, http_status, html, error, truncated,
               rules, official_domains, family_labels, fetched_at, today):
    """一个 (line, url) 的完整页级记录。抓失败时也要把判据字段全填上。"""
    text = "" if error else visible_text(html)
    fp = fingerprint(text)
    matched = [r for r in rules if rule_matches_url(r, url)]
    promos = [] if error else parse_page(
        rules=rules, text=text, url=url, line=line, fetched_at=fetched_at, today=today,
        official_domains=official_domains, family_labels=family_labels)
    status = page_status(error=error, visible_chars=len(text),
                         matched_rules=len(matched), promotions=len(promos))
    return {
        "line": line,
        "url": url,
        "status": status,
        "http_status": http_status,
        "bytes": len((html or "").encode("utf-8")),
        "visible_chars": len(text),
        "fingerprint": fp,
        "error": error,
        "note": status_note(error=error, visible_chars=len(text),
                            matched_rules=len(matched), promotions=len(promos)),
        # T4-R1：体积截断的页级可见信号（与 stderr 诊断行互为冗余，两路都留）。
        # 不许静默截断：否则「正则没匹配上」和「正文被截掉了」在面板上长得一样。
        "truncated": truncated,
        # unchanged 只是提醒层的信号；promotions 永远照解析照返回（Task 4 设计决定：
        # 跳过解析省不下东西，而空数组 + Swift 照单全收 = 面板变空还看不出原因）
        "unchanged": bool(previous_fingerprint) and previous_fingerprint == fp,
        "promotions": promos,
    }


def main(argv=None):
    # M-3（2026-10-10 复审裁定：本轮不改退出码）：argparse 的用法错（如 --timeout abc）
    # 退 **2**，与本文件「1 = 脚本自身坏」口径不一；但调用方（Swift）只判 0/非 0，
    # 2 与 1 同为非 0，不影响判读。已登记 Task 12 文档回写清单，改契约须连带改测试。
    ap = argparse.ArgumentParser(description="ccpod 优惠雷达抓取器")
    ap.add_argument("--rules", default=default_rules_path(),
                    help="规则 JSON 路径（默认：脚本同目录的 promo-rules.json）")
    ap.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT,
                    help="单次请求超时秒数（默认 %d）" % DEFAULT_TIMEOUT)
    ap.add_argument("--attempts", type=int, default=2,
                    help="网络层失败的最大尝试次数（HTTP 4xx/5xx 不重试；默认 2）")
    args = ap.parse_args(argv)

    raw = sys.stdin.read()
    try:
        manifest = json.loads(raw) if raw.strip() else []
    except ValueError as exc:
        # 诊断走 stderr，stdout 必须保持纯 JSON（Swift 直接 JSONDecoder 吃它）
        print("manifest JSON 解析失败: %s" % exc, file=sys.stderr)
        return 1
    if not isinstance(manifest, list):
        print("manifest 必须是数组，实际是 %s" % type(manifest).__name__, file=sys.stderr)
        return 1

    # 🔴 纪律 4（修正 17-1）：parse_page 的 official_domains / family_labels 必须来自
    #    load_rule_meta。计划原稿在这里手工 json.load 提三键——那条路漏传是**静默的**
    #    （official 恒 False → verified 恒 False，测试照样绿），变异测试证明过。
    try:
        rules = load_rules(args.rules)
        official_domains, family_labels = load_rule_meta(args.rules)
    except (OSError, ValueError) as exc:
        print("规则文件读不了 %s: %s" % (args.rules, exc), file=sys.stderr)
        return 1

    fetched_at = now_iso()
    today = today_iso()

    # URL 去重：同一个页被多条线路配置时只抓一次，别把人家服务器打 N 遍；
    # 但每条线路各出一份页记录（promotions 里的 line 各归各）。
    cache = {}
    pages = []
    for entry in manifest:
        if not isinstance(entry, dict):
            print("manifest 条目不是对象，已跳过: %r" % (entry,), file=sys.stderr)
            continue
        url = entry.get("url")
        line = entry.get("line") or ""
        if not url:
            print("manifest 条目缺 url，已跳过: %r" % (entry,), file=sys.stderr)
            continue
        # 🔴 cache 的键必须可哈希（2026-10-10 复审 I-1，实测复现）：truthy 但不可哈希的
        #    url（如 ["x"]）躲过上面的 `if not url`，却在 `in cache` 的 dict 键查询处抛
        #    TypeError，击穿到顶层兜底 → 整个 JSON 输出没了、好页连坐。键只用于去重：
        #    字符串 url 用自身，非字符串用 repr()。repr 有理论撞键（url=["x"] 与字面量
        #    "['x']"、url=123 与 "123"）——撞了只是两个**本来就都抓失败**的条目共用一条
        #    缓存的 error 消息（页记录仍各自产出、各自可见），可接受。url 本身**原样**传给
        #    fetch_with_retry，坏值在那里被通用 except 变成页级 fetch-failed，不在这层吞。
        cache_key = url if isinstance(url, str) else repr(url)
        if cache_key not in cache:
            http_status, html, error, truncated = fetch_with_retry(
                url, attempts=args.attempts, timeout=args.timeout)
            if truncated:
                # T4-R1 的第二路信号（stderr 诊断）；第一路是页记录的 truncated 字段。
                print("正文超过 %d 字节已截断，解析结果可能因此失真: %s"
                      % (MAX_FETCH_BYTES, url), file=sys.stderr)
            cache[cache_key] = (http_status, html, error, truncated)
        http_status, html, error, truncated = cache[cache_key]
        pages.append(build_page(
            line=line, url=url, previous_fingerprint=entry.get("previous_fingerprint"),
            http_status=http_status, html=html, error=error, truncated=truncated,
            rules=rules, official_domains=official_domains, family_labels=family_labels,
            fetched_at=fetched_at, today=today))

    json.dump({"schema": SCHEMA, "fetched_at": fetched_at, "today": today,
               "pages": pages}, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    # 退出码 0 = 跑完了。哪怕每一页都 fetch-failed 也是 0。
    # 1 只留给「脚本自己坏了」（manifest 不成 JSON、规则文件读不了、未捕获异常）。
    # 「今天没优惠」是正常结果不是错误——退 1 会被调用方当故障报警（T4-R3）。
    return 0


def report_fatal(exc):
    """顶层兜底的出口。抽成模块级函数才可单测——内联在 __main__ 里测试够不到。

    两处都过 redact（2026-10-10 复审 B，纵深防御）：
      ① 首行「promo-fetch 自身异常 …」；② traceback——它的最后一行就是
      `类型: 消息`，同一份 exc 文本会第二次落到 stderr，异常消息可能带密钥形状
      （与 fetch 的 M-1 同理）。stderr 是人肉调试通道，不豁免脱敏。
    🔴 消息模板不许动：守卫它的是 FatalFallbackTest（直接断言这行文本出现在兜底 stderr）。
      ⚠️ 别以为 .local/check-t4r3.sh 也在守卫它——实测（2026-10-10 12:47）它三条
      grep -F 断言的是「规则文件读不了 / manifest JSON 解析失败 / manifest 必须是数组」，
      三条全走 main() 自己的 return 1，**到不了本函数**；脚本末尾那句「③ 自身异常→1」
      是 echo 小结文案，不是断言目标。这个误会曾经真的发生并被写进过本注释。
    traceback.format_exc() 依赖 sys.exc_info()，在 except 块内调用的本函数里
    仍取得到当前异常（FatalFallbackTest 实测钉住，别凭这段注释信）。
    """
    import traceback
    print(redact("promo-fetch 自身异常 %s: %s" % (type(exc).__name__, exc)), file=sys.stderr)
    print(redact(traceback.format_exc()), file=sys.stderr, end="")


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(0)
    except Exception as exc:  # 兜底：崩了也要让人知道是脚本崩了，不是网断了
        report_fatal(exc)
        sys.exit(1)
