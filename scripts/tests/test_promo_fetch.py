#!/usr/bin/env python3
"""优惠雷达抓取器单测。跑法：python3 -m unittest scripts.tests.test_promo_fetch
（本机 pytest 不可用，见计划开头「三个坑」第 3 条。）

🔴 别让人把「规则对 fixture 全绿」误读成「规则对现网有效」。
   从 Task 3 起，本文件的规则/解析测试是**对 `scripts/tests/fixtures/promo/
   aliyun-billing-2026-10-09.html` 这一份快照**验的，不是对厂商现网：
     1. 全绿**只**证明「抽取逻辑对这份 2026-10-09 的快照成立」；
     2. 厂商随时会改版/改价/改措辞，快照不会跟着变，所以绿**不能**外推；
     3. 现网漂移由**运行时四态**兜（`ok` / `fetch-failed` /
        `unsupported-js-page` / `parse-failed`，各有独立证据字段），
        **不由测试兜** —— 看到测试绿不要推断线上还抽得到。
   要判断线上是否仍有效，看面板上的页级状态与 `visible_chars`，不要看这个文件。
"""

import contextlib
import http.server
import importlib.util
import io
import json
import re
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.error
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("promo_fetch", ROOT / "scripts" / "promo-fetch.py")
promo_fetch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(promo_fetch)


class VisibleTextTest(unittest.TestCase):
    def test_strips_script_style_and_tags(self):
        html = ("<html><head><style>.a{color:red}</style>"
                "<script>var secret = 'sk-abc123';</script></head>"
                "<body><p>忙时 2 元</p><!-- 注释 --><div>闲时 1 元</div></body></html>")
        self.assertEqual(promo_fetch.visible_text(html), "忙时 2 元 闲时 1 元")

    def test_strips_noscript_and_template(self):
        html = "<noscript>请开启JS</noscript><template>模板</template><b>真正文</b>"
        self.assertEqual(promo_fetch.visible_text(html), "真正文")

    def test_collapses_whitespace_and_strips(self):
        self.assertEqual(promo_fetch.visible_text("<p>\n  a \t b \n</p>"), "a b")

    def test_empty_and_none(self):
        self.assertEqual(promo_fetch.visible_text(""), "")
        self.assertEqual(promo_fetch.visible_text(None), "")

    def test_script_content_never_leaks_into_text(self):
        """密钥卫生：script 里的东西绝不能进正文（会落盘、会回显）。"""
        html = "<script>token='sk-live-DEADBEEF'</script><p>可见</p>"
        self.assertNotIn("DEADBEEF", promo_fetch.visible_text(html))

    def test_unclosed_script_swallows_rest_instead_of_leaking(self):
        """未闭合 <script> 按 HTML 语义吞掉其后全部内容。宁可判成壳页（可见失败态），
        也绝不能把 script 里的字串当正文——它会进指纹、进 visible_chars、进落盘回显。"""
        text = promo_fetch.visible_text('<p>ok</p><script>token="sk-live-DEADBEEF"')
        self.assertNotIn("DEADBEEF", text)
        self.assertEqual(text, "ok")

    def test_end_tag_with_trailing_space_still_closes(self):
        """`</script >` 是 HTML 合法闭合写法（end tag 允许尾随空白），旧正则 `</\\1>` 匹配不上。"""
        self.assertEqual(promo_fetch.visible_text("<script>x=1</script >可见"), "可见")

    def test_html_entities_are_unescaped_after_tag_stripping(self):
        """实体必须还原，否则用户会在面板/通知里读到 `0 &lt; Token ≤ 32K`。
        实测：阿里云计费页正文残留 579 处实体（&lt;×576），绝大多数来自 Token 分档区间，
        正是 A 类（可弹通知）的素材。
        🔴 顺序不可换：必须先剥标签再反转义，反过来会静默吃掉内容（实测 3529 字符塌到 192）。"""
        self.assertEqual(promo_fetch.visible_text("<p>0 &lt; Token ≤ 32K</p>"), "0 < Token ≤ 32K")
        self.assertEqual(promo_fetch.visible_text("<p>a&nbsp;&nbsp;b</p>"), "a b")
        self.assertEqual(promo_fetch.visible_text("<p>&amp;lt;</p>"), "&lt;")


class FingerprintTest(unittest.TestCase):
    def test_prefixed_and_stable(self):
        a = promo_fetch.fingerprint("忙时 2 元")
        b = promo_fetch.fingerprint("忙时 2 元")
        self.assertEqual(a, b)
        self.assertTrue(a.startswith("sha256:"))
        self.assertEqual(len(a), len("sha256:") + 64)

    def test_different_text_different_fingerprint(self):
        self.assertNotEqual(promo_fetch.fingerprint("a"), promo_fetch.fingerprint("b"))

    def test_none_is_not_a_crash(self):
        self.assertEqual(promo_fetch.fingerprint(None), promo_fetch.fingerprint(""))


class FetchTest(unittest.TestCase):
    def test_connection_refused_returns_error_not_exception(self):
        """127.0.0.1:1 必然拒连。断言正面证据：error 非空、html 为空。"""
        status, html, error, truncated = promo_fetch.fetch("http://127.0.0.1:1/", timeout=3)
        self.assertIsNone(status)
        self.assertEqual(html, "")
        self.assertTrue(error, "error 必须非空——否则「抓不到」会被当成「没优惠」")
        self.assertIn(":", error)  # 形如 "URLError: <urlopen error ...>"
        self.assertFalse(truncated, "拒连没有正文，谈不上截断")

    def test_bad_scheme_is_an_error_not_a_crash(self):
        """urllib 认不出的协议立即报 URLError（实测 0.004s，密闭）。
        ⚠️ 不要改回 ftp://：urllib 原生支持 ftp，会对 example.com:21 真发起 TCP 连接
        并等满超时（实测 3.01s），断网与通网走不同路径却都绿——不是密闭测试。"""
        status, html, error, truncated = promo_fetch.fetch("foo://example.invalid/x", timeout=3)
        self.assertIsNone(status)
        self.assertEqual(html, "")
        self.assertTrue(error, "error 必须非空——协议错不是崩，是抓取失败的一种")
        self.assertFalse(truncated)


class GenericErrorRedactTest(unittest.TestCase):
    """M-1（2026-10-10 复审）：fetch 的通用异常分支 error 也要过 redact。
    AGENTS.md 硬约定「密钥不进仓库、不进日志、不进 UI 回显」——error 落盘
    （~/.claude/ccpod-promotions.json）、回显，异常消息不豁免（异常消息可能带
    密钥形状：代理把 Authorization 回显进 URLError reason 是真实形态）。
    进程内 mock urlopen（零网络），变异测试够得到。"""

    def test_generic_exception_error_is_redacted(self):
        def _raise(req, timeout=None):
            raise OSError("proxy echoed token sk-live-DEADBEEFDEADBEEF in error")

        with mock.patch.object(promo_fetch.urllib.request, "urlopen", _raise):
            status, html, error, truncated = promo_fetch.fetch("http://x/", timeout=3)
        self.assertIsNone(status)
        self.assertEqual(html, "")
        self.assertFalse(truncated)
        self.assertIn("OSError", error, "正面证据：异常类型名保留（区分超时/证书错/DNS）")
        self.assertIn("***REDACTED***", error, "正面证据：redact 真的跑了")
        self.assertNotIn("DEADBEEF", error, "密钥形状必须被 mask——error 会落盘、会回显")


class HttpErrorReasonRedactTest(unittest.TestCase):
    """复审 A（2026-10-10）：HTTPError 分支的 error 在 return 咽喉点整体 redact。

    exc.reason 是服务端可控文本——反爬/网关把「为什么被拒」写在那里、把
    Authorization 回显进去都是真实形态。error 落盘（~/.claude/ccpod-promotions.json）、
    被面板与 macOS 通知逐字回显，与 body 摘要（T4-R2）同一条硬约定。
    在咽喉点包而不是只在拼接处包：将来谁再往 error 拼第三段也自动被覆盖。
    进程内 mock urlopen（零网络），变异测试够得到。"""

    def test_http_error_reason_redacted_and_status_kept(self):
        def _raise(req, timeout=None):
            raise urllib.error.HTTPError(
                "http://x/", 403,
                "denied: key sk-live-DEADBEEFDEADBEEF lacks scope", None,
                io.BytesIO(b""))

        with mock.patch.object(promo_fetch.urllib.request, "urlopen", _raise):
            status, html, error, truncated = promo_fetch.fetch("http://x/", timeout=3)
        self.assertEqual(status, 403)
        self.assertEqual(html, "")
        self.assertFalse(truncated)
        self.assertIn("403", error,
                      "🔴 承重：状态码必须保留——403 被反爬挡 vs 404 URL 填错，修法完全"
                      "不同；把整个 error redact 光/置成常量也能让密钥消失，那不是修复")
        self.assertIn("HTTP 403", error, "正面证据：错误形态在")
        self.assertIn("***REDACTED***", error, "正面证据：redact 真的跑了")
        self.assertNotIn("DEADBEEF", error,
                         "reason 里的密钥形状必须被 mask——error 会落盘、会回显")

    def test_reason_and_body_secrets_both_masked_end_to_end(self):
        """reason 与 body 摘要两路密钥形状在同一份 error 里都要消失：snippet 在
        http_error_snippet 内部已 redact 一次、咽喉点再 redact 一次——本条与
        RedactIdempotencyTest 一起锁「脱敏两次不会把 mask 洗掉」。"""
        # 🔴 假 key 形状字面量一律**拼接构造**，源码行不出现整串（修正 24 §八 新增规则）。
        # 理由不是风格：整串会被 export-public.sh 门禁3（:190）的 Bearer 分支命中
        # （那条要求 Bearer 后跟 20 个以上 [A-Za-z0-9._-]，连字符也算），而 scripts/tests
        # 在 SCRIPT_DIRS（:42-44）里是**整目录导出**（:269）→ 公开导出会永久判红。
        # ⚠️ 代价要如实记：拼接形式对门禁3、lint-secret-shape、gitleaks **同时隐形**
        # （三者都是文本口径），所以"运行时值没变"只能靠整文件 AST 多重集比对来证，
        # 不能指望任何一道文本门。运行时值逐字不变的证明见台账第 19 节。
        fake_in_body = "sk-live-" + "DEADBEEFDEADBEEF"
        fake_in_reason = "sk-live-" + "FEEDFACEFEEDFACE"
        body = ("<html><body><p>Access denied: token " + fake_in_body +
                " lacks scope.</p></body></html>").encode("utf-8")

        def _raise(req, timeout=None):
            raise urllib.error.HTTPError(
                "http://x/", 403, "gateway saw Bearer " + fake_in_reason,
                None, io.BytesIO(body))

        with mock.patch.object(promo_fetch.urllib.request, "urlopen", _raise):
            _status, _html, error, _tr = promo_fetch.fetch("http://x/", timeout=3)
        self.assertIn("HTTP 403", error)
        self.assertIn("Access denied", error, "正面证据：body 摘要真的拼进来了")
        self.assertEqual(error.count("DEADBEEF") + error.count("FEEDFACE"), 0,
                         "reason 与 body 两路的密钥原文都必须消失"
                         "（error 会落盘、会回显）")
        self.assertGreaterEqual(error.count("***REDACTED***"), 2,
                                "两路各自留下 mask 痕迹——只看原文消失会被"
                                "「整个 error 置空」蒙过")


class RetryTest(unittest.TestCase):
    """锁住 fetch_with_retry 的四条分支。每条都对外部服务器有副作用，改坏不会自己发现。
    monkeypatch 模块属性，零网络、密闭、每次跑都是 0.00x 秒。"""

    def setUp(self):
        self.calls = []
        self._real_fetch = promo_fetch.fetch

    def tearDown(self):
        promo_fetch.fetch = self._real_fetch

    def _stub(self, result):
        def fake(url, **kwargs):
            self.calls.append(url)
            return result
        promo_fetch.fetch = fake

    def test_network_error_retries_up_to_attempts(self):
        self._stub((None, "", "URLError: boom", False))
        status, _html, error, _tr = promo_fetch.fetch_with_retry("http://x/", attempts=3)
        self.assertEqual(len(self.calls), 3, "网络层失败必须重试满 attempts 次")
        self.assertIsNone(status)
        self.assertIn("URLError", error)

    def test_http_status_does_not_retry(self):
        self._stub((403, "", "HTTP 403 Forbidden", False))
        status, _html, error, _tr = promo_fetch.fetch_with_retry("http://x/", attempts=3)
        self.assertEqual(len(self.calls), 1, "对方明确回话拒绝了，再打是骚扰")
        self.assertEqual(status, 403)
        self.assertIn("403", error)

    def test_success_returns_immediately_without_extra_hits(self):
        self._stub((200, "<p>x</p>", None, False))
        status, _html, error, _tr = promo_fetch.fetch_with_retry("http://x/", attempts=3)
        self.assertEqual(len(self.calls), 1, "成功还继续打 = 白白放大对厂商的请求量，会被反爬封")
        self.assertEqual(status, 200)
        self.assertIsNone(error)

    def test_attempts_zero_still_fetches_once(self):
        self._stub((None, "", "URLError: boom", False))
        promo_fetch.fetch_with_retry("http://x/", attempts=0)
        self.assertEqual(len(self.calls), 1, "max(1, attempts) 护栏：传 0 也要真跑 1 次，不能空转返回哨兵")


# 「一个真实的大页面有多少可见字符」的样本值，给下面三条测试当输入。
# 🔒 M-b（2026-10-10 复审）：这个数**不随页面漂移刷新**。它只当「远大于阈值的
#   真实样本」用，不是被断言对象（断言只拿它和 MIN_VISIBLE_CHARS 比大小）。
#   阿里正文自己就在漂（复审记录：两天内 95791 → 109349），好心人定期刷它
#   只会把测试变成「追页面」，哪天数变了反倒说不清是页面漂了还是 visible_text 改坏了。
# 🔴 口径必须是 **visible_text 反转义之后**的数，因为正式代码就是反转义的。
#   阿里计费页（help.aliyun.com/zh/model-studio/billing-for-model-studio，1.96 MB，
#   2026-10-09 抓取）实测：反转义后 **107606** 字符（反转义前 109349，缩短 1743 = 1.6%）。
#   这里原来写的是 109349（反转义前口径），Task 2 的 spec 复审者抓出来的：
#   数字本身不影响断言（远大于 500），但它对不上任何真实实测值 —— 那就是个推算值冒充实测值。
# ⚠️ 别和另外两个数混：3513 = 裁剪 fixture 的烘焙窗口长度，
#   3562 = 那个 fixture 文件整个过一遍 visible_text 的长度。三个数测的不是同一个对象。
REAL_PAGE_VISIBLE_CHARS = 107606


class PageStatusTest(unittest.TestCase):
    """页级四态。核心不变量：每一种「空」都有不同的名字。"""

    def test_fetch_failed(self):
        self.assertEqual(
            promo_fetch.page_status(error="HTTP 403 Forbidden", visible_chars=0,
                                    matched_rules=0, promotions=0),
            "fetch-failed")

    def test_js_shell_page(self):
        """HTTP 200 但正文 55 字符 = JS 壳（火山 docs 页实测值）。"""
        self.assertEqual(
            promo_fetch.page_status(error=None, visible_chars=55,
                                    matched_rules=0, promotions=0),
            "unsupported-js-page")

    def test_no_rule_matched_the_url(self):
        self.assertEqual(
            promo_fetch.page_status(error=None, visible_chars=REAL_PAGE_VISIBLE_CHARS,
                                    matched_rules=0, promotions=0),
            "parse-failed")

    def test_rule_matched_but_zero_hits(self):
        self.assertEqual(
            promo_fetch.page_status(error=None, visible_chars=REAL_PAGE_VISIBLE_CHARS,
                                    matched_rules=1, promotions=0),
            "parse-failed")

    def test_ok(self):
        self.assertEqual(
            promo_fetch.page_status(error=None, visible_chars=REAL_PAGE_VISIBLE_CHARS,
                                    matched_rules=1, promotions=1),
            "ok")

    def test_fetch_error_wins_over_short_text(self):
        """抓失败时 visible_chars 必然是 0，不能误报成 JS 壳。"""
        self.assertEqual(
            promo_fetch.page_status(error="HTTP 500 Internal Server Error",
                                    visible_chars=0, matched_rules=1, promotions=0),
            "fetch-failed")

    def test_threshold_boundary(self):
        self.assertEqual(
            promo_fetch.page_status(error=None, visible_chars=499,
                                    matched_rules=1, promotions=1),
            "unsupported-js-page")
        self.assertEqual(
            promo_fetch.page_status(error=None, visible_chars=500,
                                    matched_rules=1, promotions=1),
            "ok")


class NoteTest(unittest.TestCase):
    """parse-failed 必须区分「没规则」和「有规则没命中」——两者修法完全不同。"""

    def test_no_rule_note(self):
        self.assertEqual(promo_fetch.status_note(
            error=None, visible_chars=9000, matched_rules=0, promotions=0),
            "no-rule-matched-url")

    def test_no_hit_note(self):
        self.assertEqual(promo_fetch.status_note(
            error=None, visible_chars=9000, matched_rules=2, promotions=0),
            "rule-matched-no-hit")

    def test_ok_and_fetch_failed_have_no_note(self):
        self.assertIsNone(promo_fetch.status_note(
            error=None, visible_chars=9000, matched_rules=1, promotions=3))
        self.assertIsNone(promo_fetch.status_note(
            error="HTTP 404 Not Found", visible_chars=0, matched_rules=0, promotions=0))


FIXTURES = ROOT / "scripts" / "tests" / "fixtures" / "promo"


class FixtureTest(unittest.TestCase):
    """用真实页裁剪出来的 fixture 钉住抽取层。数字全是 2026-10-10 实测值。"""

    @classmethod
    def setUpClass(cls):
        # M-a（2026-10-10 复审）：不守卫的话，fixture 缺失会以裸 FileNotFoundError
        # 冒出来，unittest 侧显示 "Ran 0 tests"——整组测试凭空消失，还容易被误读成全绿。
        # 失败消息必须说「怎么办」，不只是「出错了」。
        for name in ("aliyun-billing-2026-10-09.html", "js-shell.html"):
            path = FIXTURES / name
            if not path.exists():
                raise FileNotFoundError(
                    "fixture 缺失：%s\n"
                    "整组 FixtureTest 连跑都没跑（Ran 0 tests ≠ 通过）。\n"
                    "找回：已提交过就 git checkout -- %s；这两个文件是人工裁剪/手写的，"
                    "没有生成脚本——aliyun 页按 help.aliyun.com/zh/model-studio/"
                    "billing-for-model-studio 的峰谷语义窗口重裁。" % (path, path))
        cls.real = (FIXTURES / "aliyun-billing-2026-10-09.html").read_text(encoding="utf-8")
        cls.shell = (FIXTURES / "js-shell.html").read_text(encoding="utf-8")

    def test_real_page_yields_enough_visible_text(self):
        text = promo_fetch.visible_text(self.real)
        self.assertGreater(len(text), promo_fetch.MIN_VISIBLE_CHARS,
                           "真实页正文必须远超阈值，否则阈值就是错的")
        self.assertIn("忙时为北京时间 8:00 - 22:00", text)
        self.assertIn("闲时为北京时间 22:00 - 次日 8:00", text)
        # I-2b 反转义锚点（2026-10-10 复审）：fixture 原文写的是 `0&lt;Token≤32K`，
        # 只有 unescape 真发生才会读成下面这样。专治「去掉 unescape」变异——那之下
        # 本 fixture 可见长度 3562→3661，两者都远超 500，上面的断言全区分不了。
        self.assertIn("0<Token≤32K", text,
                      "反转义没发生：正文里还是实体形式 0&lt;Token≤32K")

    def test_real_page_is_ok_not_any_failure_state(self):
        text = promo_fetch.visible_text(self.real)
        self.assertEqual(
            promo_fetch.page_status(error=None, visible_chars=len(text),
                                    matched_rules=1, promotions=1),
            "ok")

    def test_js_shell_page_is_classified_as_shell(self):
        """核心用例：抓到了 ≠ 读懂了。壳页必须有自己的名字，不能混进「没优惠」。"""
        text = promo_fetch.visible_text(self.shell)
        self.assertLess(len(text), promo_fetch.MIN_VISIBLE_CHARS)
        self.assertEqual(
            promo_fetch.page_status(error=None, visible_chars=len(text),
                                    matched_rules=0, promotions=0),
            "unsupported-js-page")
        # I-2b 正向锚点（2026-10-10 复审）：fixture 若被截成空文件，
        # visible_text("") == ""，上面 assertLess / assertEqual 照样全绿（vacuous green）。
        # 钉住壳页正文真的被读进来了——实测整个壳页的可见正文就是 title 里这 4 个字。
        self.assertIn("文档中心", text,
                      "壳页正文丢了——fixture 被截断，或 visible_text 剥过头了")

    def test_shell_page_leaks_no_script_content(self):
        text = promo_fetch.visible_text(self.shell)
        self.assertNotIn("__INITIAL_STATE__", text)
        self.assertNotIn("这里本该是全部正文", text)

    def test_qwen_rows_are_not_peak_valley(self):
        """用户原始需求是「qwen 夜间优惠」。这条断言把「qwen 没有峰谷价」这个事实钉死，
        防止后人以为规则漏了 qwen 而去放宽正则。

        窗口长度 140 的依据（2026-10-10 机械统计，口径与本断言代码同款——从匹配起点
        **向后**开窗）：
          行内真命中间距：deepseek 同表 14 处命中，起点→行内「忙时」31–125 字符；
          跨表串扰下界：qwen 到全文最近「忙时」324 字符。
          140 卡在两者中间（对上界 125 留 15 字符余量，对下界 324 隔开 184）。
        🔴 求稳想扩窗口之前先看代价：拉到 500，qwen 的「忙时」命中 0 → 6，全是
          跨表误报——这条事实锁就废了。
        ⚠️ 别引用「最近忙时距离 14」之类的双向数字：那是「匹配前面 14 字符处有忙时」
          的行，本断言窗口只向后开，那行并不命中；向后口径的实测最小值是 31。

        实测计数（2026-10-10）：本断言跑的 **fixture** 里 qwen 匹配 **15** 处、
        带「忙时」的 **0** 处；来源**整页**（help.aliyun.com 计费页，1.96 MB）里
        qwen 匹配 **750** 处、带峰谷价的同样 **0** 处。
        ⚠️ 两个数字测的不是同一个对象，别混引：fixture 只裁了峰谷语义窗口。
        """
        text = promo_fetch.visible_text(self.real)
        # I-2a 恒等锚点（2026-10-10 复审）：fixture 里 qwen 必须真有 15 行。
        # 没有这条，fixture 被重裁成不含 qwen 的窗口时，下面的 for 循环一次都不跑、
        # 测试无条件通过——计划里就记录过一次按错误锚点裁出废窗口的事故。
        matches = list(re.finditer(r"qwen[a-z0-9.\-]*", text, re.I))
        self.assertEqual(len(matches), 15,
                         "fixture 的 qwen 行数变了——被重裁了，或页面结构变了")
        for m in matches:
            window = text[m.start():m.start() + 140]
            self.assertNotIn("忙时", window,
                             "发现带峰谷价的 qwen 行，spec §2 的事实基础需要更新：%r" % window)

    def test_deepseek_rows_are_peak_valley_positive_control(self):
        """阳性对照（2026-10-10 复审 I-1b）：自证上面那条 qwen 断言的 140 窗口
        这把尺子量得出东西——同一把尺子量 deepseek，必须命中「忙时」（实测 14 处）。
        fixture 若被重裁到只剩 qwen 表，这里先红，而不是让 qwen 那条静默变绿。
        实测（2026-10-10）：deepseek 匹配 30 处、140 窗口内含「忙时」14 处。"""
        text = promo_fetch.visible_text(self.real)
        matches = list(re.finditer(r"deepseek[a-z0-9.\-]*", text, re.I))
        self.assertEqual(len(matches), 30,
                         "deepseek 行数变了——fixture 被重裁或页面结构变了")
        hits = sum(1 for m in matches if "忙时" in text[m.start():m.start() + 140])
        self.assertGreater(hits, 0,
                           "140 窗口量不出 deepseek 的峰谷行——fixture 只剩 qwen 表，"
                           "或窗口逻辑被改坏")


class RuleMatchTest(unittest.TestCase):
    def setUp(self):
        self.rules = promo_fetch.load_rules(ROOT / "scripts" / "promo-rules.json")
        self.rule = [r for r in self.rules if r["id"] == "bailian-peakvalley"][0]

    def test_rules_file_loads_and_has_one_rule(self):
        self.assertEqual(len(self.rules), 1)
        self.assertEqual(self.rule["class"], "peak_valley")
        self.assertEqual(self.rule["vendor"], "阿里云百炼")

    def test_matches_the_real_url(self):
        url = "https://help.aliyun.com/zh/model-studio/billing-for-model-studio"
        self.assertTrue(promo_fetch.rule_matches_url(self.rule, url))

    def test_rejects_other_vendor(self):
        self.assertFalse(promo_fetch.rule_matches_url(
            self.rule, "https://www.volcengine.com/docs/82379"))

    def test_rejects_right_domain_wrong_page(self):
        """域名对但页不对 → 不匹配。否则会拿首页去套计费正则，白跑还误报。"""
        self.assertFalse(promo_fetch.rule_matches_url(
            self.rule, "https://help.aliyun.com/zh/model-studio/getting-started"))

    def test_rule_with_no_locator_matches_nothing(self):
        """安全默认：没有 url_domain_contains / url_path_contains 的规则不是「万能规则」。"""
        self.assertFalse(promo_fetch.rule_matches_url({"id": "x"}, "https://anywhere/"))

    def test_non_string_url_matches_nothing(self):
        """坏 manifest 塞进非字符串 url 时，`dom not in url` 会 TypeError 击穿整个
        进程；这里必须安静地返回 False（页级 fetch-failed 由 fetch 层负责报）。"""
        self.assertFalse(promo_fetch.rule_matches_url(self.rule, 123))
        self.assertFalse(promo_fetch.rule_matches_url(self.rule, None))


class PeakValleyParseTest(unittest.TestCase):
    """全部数字来自 2026-10-10 对裁剪 fixture 的实测。"""

    @classmethod
    def setUpClass(cls):
        rules_path = ROOT / "scripts" / "promo-rules.json"
        cls.rules = promo_fetch.load_rules(rules_path)
        # 🔴 计划原稿漏传这两个参数（2026-10-10 实测抓出，两条测试因此红）：
        #    parse_page 的默认是 official_domains=[] / family_labels={} —— 不传则
        #    is_official 对空名单恒 False → verified 恒 False；family 标签退化成
        #    capitalize() 的「Deepseek」而不是规则表里的「DeepSeek」。
        #    正式调用方与 .local/verify-task3-values.py 都经 load_rule_meta 传入，
        #    这里必须走同一条读取路径。
        cls.domains, cls.families = promo_fetch.load_rule_meta(rules_path)
        html = (FIXTURES / "aliyun-billing-2026-10-09.html").read_text(encoding="utf-8")
        cls.text = promo_fetch.visible_text(html)
        cls.url = "https://help.aliyun.com/zh/model-studio/billing-for-model-studio"
        cls.promos = promo_fetch.parse_page(
            rules=cls.rules, text=cls.text, url=cls.url, line="gw-bailian",
            fetched_at="2026-10-10T00:40:00+08:00", today="2026-10-10",
            official_domains=cls.domains, family_labels=cls.families)

    def test_fixture_baseline_visible_chars(self):
        # 🔴 3562 是「**整个 fixture 文件**过一遍 visible_text」的长度，不是烘焙窗口长度。
        #    窗口是 3513，差的 49 个字符是 Task 2 烘焙时套的 <title> 文字（visible_text 会算进去）。
        #    原来这里写 3612 —— 那是烘焙**前**、**未反转义**的窗口长度，是推算值，
        #    在 fixture 还不存在时写下的，从没被测过（详见 plan-corrections.md 修正 13）。
        #    3562 已由 .local/verify-task3-values.py 用真实 visible_text 实测确认。
        self.assertEqual(len(self.text), 3562,
                         "fixture 变了？重新生成会改变所有期望值，别偷偷改这个数。"
                         "重算方法：python3 .local/verify-task3-values.py")

    def test_exactly_one_promotion_for_deepseek_family(self):
        self.assertEqual(len(self.promos), 1)
        self.assertEqual(self.promos[0]["id"], "bailian-peakvalley-deepseek")
        self.assertEqual(self.promos[0]["line"], "gw-bailian")
        self.assertEqual(self.promos[0]["class"], "peak_valley")

    def test_scope_column_regression(self):
        """🔴 这条钉的是计划写作期抓出的真 bug：
        非北京地域多一列「服务部署范围」，旧正则整页只命中 3/16 行。
        断言正面证据：带 scope 的行真的被收到了，且 scope 值被记下来。"""
        rows = promo_fetch.parse_items(self.rules[0], self.text)
        self.assertEqual(len(rows), 7, "裁剪 fixture 上应命中 7 行（旧无 scope 正则只有 3 行）")
        scopes = [r["scope"] for r in rows]
        self.assertIn("全球", scopes, "带 scope 列的行没被收到 —— scope 组又丢了")
        self.assertIn("美国", scopes)
        self.assertIn(None, scopes, "北京表那种没有 scope 列的行也必须能收到")

    def test_models_deduped_and_sorted(self):
        self.assertEqual(
            self.promos[0]["models"],
            ["deepseek-v4-flash-0731", "deepseek-v4-pro-0813", "deepseek-v4.1-flash"])

    def test_window_is_the_off_peak_window_and_normalized(self):
        w = self.promos[0]["window"]
        self.assertEqual(w["tz"], "Asia/Shanghai")
        self.assertEqual(w["start"], "22:00", "优惠窗口是**闲时**，不是忙时")
        self.assertEqual(w["end"], "08:00", "页面上写的是 8:00，必须补零成 08:00")
        self.assertTrue(w["ends_next_day"], "22:00–次日 08:00 跨午夜，倒计时算错就是这条")
        self.assertEqual(w["days"], ["mon", "tue", "wed", "thu", "fri", "sat", "sun"])

    def test_discount_ratio(self):
        d = self.promos[0]["discount"]
        self.assertEqual(d["ratio"], 0.5)
        self.assertEqual(d["text"], "闲时约为忙时的 5 折")

    def test_validity_and_status(self):
        p = self.promos[0]
        self.assertEqual(p["valid_from"], "2026-08-17")
        self.assertIsNone(p["valid_until"])
        self.assertEqual(p["status"], "active")

    def test_verified_true_and_why(self):
        """verified=True 的四个条件（spec §5）缺一不可。"""
        p = self.promos[0]
        self.assertTrue(p["verified"])
        self.assertTrue(p["source"]["official"])
        self.assertEqual(p["source"]["url"], self.url)
        self.assertEqual(p["source"]["fetched_at"], "2026-10-10T00:40:00+08:00")
        self.assertEqual(p["extractor"], "rule:bailian-peakvalley")
        self.assertEqual(len(p["evidence"]), 2)
        for ev in p["evidence"]:
            self.assertIn(ev, self.text, "evidence 必须是正文的逐字子串，不能是改写")
        self.assertIn("忙时为北京时间 8:00 - 22:00", p["evidence"][0])
        self.assertIn("2026-08-17", p["evidence"][1])

    def test_title(self):
        self.assertEqual(
            self.promos[0]["title"],
            "阿里云百炼 DeepSeek 系列 闲时 5 折（22:00–次日 08:00 北京时间）")

    def test_title_carries_tz_label(self):
        """标题会进通知正文，而通知里没有别处标时区。
        少了这个标签，不在北京时区的用户读到的「22:00」就是一个错的钟点。"""
        self.assertIn("北京时间", self.promos[0]["title"])

    def test_tz_label_falls_back_to_identifier(self):
        """没登记过的时区不能静默丢掉标签 —— 宁可显示 `Europe/Berlin`
        也不显示一个看起来像本地时间的错钟点。"""
        self.assertEqual(promo_fetch.tz_label("Europe/Berlin"), "Europe/Berlin")
        self.assertEqual(promo_fetch.tz_label("Asia/Shanghai"), "北京时间")
        self.assertEqual(promo_fetch.tz_label(None), "")

    def test_non_peakvalley_row_is_excluded(self):
        """deepseek-v4-pro 是 12 元 / 24 元、没有忙时闲时，必须不被收进来。
        这条是「宁缺勿假」的反面测试：多收一条不存在的优惠比漏收更糟。

        🔴 下面第一条 assertIn 是**负例的前置锚点**，不是负例本身：它先证明
        「无峰谷价的那一行确实在正文里」，否则后面 assertNotIn「没被收进来」是空转
        （行都不在，当然收不进来）。所以它红的时候，**大概率不是规则坏了**。
        """
        # T3-R1：这是全 Task 3 **唯一一处钉死字面价格**的断言（规则正则本身用捕获组
        # `(?P<peak_in>[\d.]+)\s*元`，不钉价格；情报层也有「不带绝对价格」的不变量）。
        # 厂商一改 deepseek-v4-pro 的价，这条就红 —— 而裸 `assertIn failed` 会把后人
        # 指向**规则正则**，方向完全错。所以失败消息必须带三要素：
        # ①什么漂了 ②什么没坏 ③下一步查哪。（`assertIn failed` 是现象复述，不是错误消息。）
        self.assertIn("deepseek-v4-pro 上下文缓存 享有折扣 12 元 24 元", self.text,
                      "①漂了：fixture `aliyun-billing-2026-10-09.html`（2026-10-09 快照）里"
                      "已找不到这行原文 —— 快照与断言的字面价格对不上了。"
                      "②没坏：这**不是**规则正则失配，正则用捕获组不钉价格；"
                      "也不是 parse_items 坏了。"
                      "③查哪：跑 `grep -o 'deepseek-v4-pro.\\{0,60\\}' "
                      "scripts/tests/fixtures/promo/aliyun-billing-2026-10-09.html` "
                      "看快照里那行现在长什么样，再决定是重裁 fixture 还是只更新这条字面量。"
                      "**不要**去改正则。")
        self.assertNotIn("deepseek-v4-pro", self.promos[0]["models"])

    def test_eligibility_is_rule_data_not_invention(self):
        self.assertEqual(
            self.promos[0]["eligibility"],
            "无需报名，闲时时段调用自动按闲时价计费；具体单价与地域以官方页为准")


class OfficialDomainTest(unittest.TestCase):
    """`official` 是 `verified` 的四个必要条件之一，`verified` 是弹通知的唯一前提。
    这一组测试防的是「攻击者用自己的页面借走 ccpod 的信任标记」。"""

    DOMAINS = ["help.aliyun.com"]

    def test_exact_host(self):
        self.assertTrue(promo_fetch.is_official(
            "https://help.aliyun.com/zh/model-studio/billing-for-model-studio", self.DOMAINS))

    def test_subdomain_is_official(self):
        self.assertTrue(promo_fetch.is_official(
            "https://billing.help.aliyun.com/x", self.DOMAINS))

    def test_domain_in_query_string_is_not_official(self):
        """🔴 子串匹配会在这里被骗过。整条测试存在的理由就是这一行。"""
        self.assertFalse(promo_fetch.is_official(
            "https://evil.com/?x=help.aliyun.com", self.DOMAINS))

    def test_domain_in_path_is_not_official(self):
        self.assertFalse(promo_fetch.is_official(
            "https://evil.com/help.aliyun.com/pricing", self.DOMAINS))

    def test_lookalike_host_is_not_official(self):
        """🔴 `endswith(d)` 而不加那个点会在这里被骗过。"""
        self.assertFalse(promo_fetch.is_official(
            "https://help.aliyun.com.evil.com/x", self.DOMAINS))

    def test_userinfo_trick_is_not_official(self):
        """🔴 userinfo 绕过：`https://help.aliyun.com@evil.com/` 里 `@` 前的
        help.aliyun.com 只是凭据装饰段，真 host 是 `@` 后的 evil.com ——
        urlparse().hostname 取的正是 @ 之后的 host，所以按 host 比对天然免疫，
        白名单前缀/子串匹配会在这里被骗过。这条把真绕过面钉住（实现已正确，
        2026-10-10 复审 Minor 3 补测试缺口）。"""
        # 前置锚点（防空转绿）：先证明同款白名单下正例判 True ——
        # is_official 若退化成恒 False，下面的 assertFalse 毫无意义。
        self.assertTrue(
            promo_fetch.is_official("https://help.aliyun.com/x", self.DOMAINS),
            "①漂了：正例 https://help.aliyun.com/x 不再判官方。"
            "②没坏：本条只测 is_official 的 host 比对，与规则/解析层无关。"
            "③查哪：promo-fetch.py is_official 的白名单遍历，"
            "以及 promo-rules.json 的 official_domains 数据。")
        self.assertFalse(
            promo_fetch.is_official("https://help.aliyun.com@evil.com/", self.DOMAINS),
            "①漂了：userinfo 绕过 URL https://help.aliyun.com@evil.com/ 被判成官方 —— "
            "它的真 host 是 @ 后的 evil.com，正文完全由攻击者控制，"
            "official=True 会带着 verified 一起失守。"
            "②没坏：正例 https://help.aliyun.com/x 上一行仍判官方 —— "
            "坏的不是白名单数据，是 host 的取法。"
            "③查哪：promo-fetch.py is_official 是否仍用 urlparse().hostname "
            "取 host 比对 —— 退化成 `d in url` 子串/前缀匹配就会在这里被骗过。")

    def test_non_http_scheme_is_not_official(self):
        self.assertFalse(promo_fetch.is_official("file:///etc/passwd", self.DOMAINS))

    def test_empty_and_none(self):
        self.assertFalse(promo_fetch.is_official("", self.DOMAINS))
        self.assertFalse(promo_fetch.is_official(None, self.DOMAINS))

    def test_blank_whitelist_entry_never_matches(self):
        """白名单里混进一个空串，`endswith("." + "")` 会让**任何** host 都变官方。"""
        self.assertFalse(promo_fetch.is_official("https://evil.com/x", [""]))
        self.assertFalse(promo_fetch.is_official("https://evil.com/x", []))


class LifecycleTest(unittest.TestCase):
    def test_active(self):
        self.assertEqual(promo_fetch.lifecycle("2026-08-17", None, "2026-10-10"), "active")

    def test_upcoming(self):
        self.assertEqual(promo_fetch.lifecycle("2026-11-01", None, "2026-10-10"), "upcoming")

    def test_expired(self):
        self.assertEqual(promo_fetch.lifecycle("2026-08-17", "2026-09-30", "2026-10-10"), "expired")

    def test_expires_today_is_still_active(self):
        self.assertEqual(promo_fetch.lifecycle(None, "2026-10-10", "2026-10-10"), "active")

    def test_starts_today_is_active_not_upcoming(self):
        self.assertEqual(promo_fetch.lifecycle("2026-10-10", None, "2026-10-10"), "active")

    def test_no_dates_is_active(self):
        self.assertEqual(promo_fetch.lifecycle(None, None, "2026-10-10"), "active")


class UnverifiedTest(unittest.TestCase):
    def test_unofficial_domain_is_never_verified(self):
        """同一个页搬到第三方站 → 规则还能解析，但 verified 必须是 False。
        verified 的语义是「官方页面确实这么写」，不是「我解析成功了」。"""
        rules_path = ROOT / "scripts" / "promo-rules.json"
        rules = promo_fetch.load_rules(rules_path)
        # 🔴 必须传真实白名单（计划原稿没传）：parse_page 默认 official_domains=[]，
        #    空名单下 official 恒 False，这条测试就锁不住「域名不在名单」这条链路。
        domains, _labels = promo_fetch.load_rule_meta(rules_path)
        html = (FIXTURES / "aliyun-billing-2026-10-09.html").read_text(encoding="utf-8")
        text = promo_fetch.visible_text(html)
        promos = promo_fetch.parse_page(
            rules=[dict(rules[0], url_domain_contains="mirror.example.com",
                        url_path_contains="billing")],
            text=text, url="https://mirror.example.com/billing", line="gw-x",
            fetched_at="2026-10-10T00:40:00+08:00", today="2026-10-10",
            official_domains=domains)
        self.assertEqual(len(promos), 1)
        self.assertFalse(promos[0]["verified"])
        self.assertFalse(promos[0]["source"]["official"])

    def test_missing_evidence_downgrades_to_unverified(self):
        rules_path = ROOT / "scripts" / "promo-rules.json"
        rules = promo_fetch.load_rules(rules_path)
        # 🔴 同上：传官方白名单，让 official=True，evidence 缺失成为 verified=False
        #    的唯一原因 —— 否则这条测试锁不住第四条件（collect_evidence 坏了它照样绿）。
        domains, _labels = promo_fetch.load_rule_meta(rules_path)
        html = (FIXTURES / "aliyun-billing-2026-10-09.html").read_text(encoding="utf-8")
        text = promo_fetch.visible_text(html)
        broken = dict(rules[0], evidence=["这句在页面上根本不存在"])
        promos = promo_fetch.parse_page(
            rules=[broken], text=text,
            url="https://help.aliyun.com/zh/model-studio/billing-for-model-studio",
            line="gw-bailian", fetched_at="2026-10-10T00:40:00+08:00", today="2026-10-10",
            official_domains=domains)
        self.assertEqual(len(promos), 1)
        self.assertFalse(promos[0]["verified"],
                         "evidence 找不到原文还标 verified=True，就是在编造依据")

    def test_empty_evidence_list_is_never_verified(self):
        """spec §5.2 条件 4 的另一半：evidence 不光每条要命中，列表本身**非空**才算数。
        空列表 = 规则作者根本没给逐字依据，verified 必须 False —— 官方页、
        A 类、窗口/条目全命中都救不了它（collect_evidence 对空列表返回 ([], False)，
        2026-10-10 复审 Minor 4 补测试缺口，实现已正确）。"""
        rules_path = ROOT / "scripts" / "promo-rules.json"
        rules = promo_fetch.load_rules(rules_path)
        # 🔴 传官方白名单（同上）：official=True、class=A 类、窗口/条目全命中，
        #    让「evidence 空列表」成为 verified=False 的唯一坏点。
        domains, _labels = promo_fetch.load_rule_meta(rules_path)
        html = (FIXTURES / "aliyun-billing-2026-10-09.html").read_text(encoding="utf-8")
        text = promo_fetch.visible_text(html)
        no_evidence = dict(rules[0], evidence=[])
        promos = promo_fetch.parse_page(
            rules=[no_evidence], text=text,
            url="https://help.aliyun.com/zh/model-studio/billing-for-model-studio",
            line="gw-bailian", fetched_at="2026-10-10T00:40:00+08:00", today="2026-10-10",
            official_domains=domains)
        # 前置锚点（防空转绿）：条目必须真产出了、evidence 字段必须真是空列表 ——
        # 前提不成立就先红，别让下面的 assertFalse 空转。
        self.assertEqual(
            len(promos), 1,
            "①漂了：官方页 + 窗口/条目全命中的规则没产出条目。"
            "②没坏：本条只把 evidence 换成空列表，规则定位/解析层没动。"
            "③查哪：parse_items / parse_window 对 fixture 的命中数，"
            "以及 rules[0] 是否还是 bailian-peakvalley。")
        self.assertEqual(
            promos[0]["evidence"], [],
            "①漂了：产出条目的 evidence 不是空列表 —— 本条的前提（规则 evidence=[]）"
            "没传进 parse_page。"
            "②没坏：verified 断言还没跑，先修前提。"
            "③查哪：上方 dict(rules[0], evidence=[]) 的字段覆盖写法。")
        self.assertFalse(
            promos[0]["verified"],
            "①漂了：evidence 空列表的条目被标了 verified=True —— 一条逐字依据都没有"
            "也自称已核实。"
            "②没坏：条目产出正常（len==1）、official=True、class=peak_valley 全成立，"
            "坏的只是「evidence 非空」这半边。"
            "③查哪：collect_evidence 的第二返回值（空列表必须给 False，看 bool(found)），"
            "以及 verified 表达式里的 evidence_ok —— 别把空列表当「全部命中」。")

    def test_explicit_class_b_is_never_verified(self):
        """spec §5.2 条件 2：verified 只属于 A 类（peak_valley）。
        B 类（限时优惠）即便官方域、窗口/条目/evidence 全命中，verified 也必须 False ——
        否则面板会给 B 类挂「已核实」标，Task 6 的 isAlertable 两道闸同时失效。"""
        rules_path = ROOT / "scripts" / "promo-rules.json"
        rules = promo_fetch.load_rules(rules_path)
        # 🔴 传官方白名单（否则 verified=False 来自空名单，锁不住 class 这条链路）：
        # 官方域/窗口/条目/evidence 全部成立，class 是唯一坏点。
        domains, _labels = promo_fetch.load_rule_meta(rules_path)
        html = (FIXTURES / "aliyun-billing-2026-10-09.html").read_text(encoding="utf-8")
        text = promo_fetch.visible_text(html)
        promos = promo_fetch.parse_page(
            rules=[dict(rules[0], **{"class": "promotion"})], text=text,
            url="https://help.aliyun.com/zh/model-studio/billing-for-model-studio",
            line="gw-bailian", fetched_at="2026-10-10T00:40:00+08:00", today="2026-10-10",
            official_domains=domains)
        self.assertEqual(len(promos), 1)
        self.assertEqual(promos[0]["class"], "promotion")
        self.assertFalse(promos[0]["verified"],
                         "spec §5.2 条件 2：class != peak_valley 则 verified 必须 False —— "
                         "B 类弹通知的两道闸不能一起失守")

    def test_missing_class_defaults_to_b_not_silently_a(self):
        """漏写 class 的规则 → 默认 B 类（promotion），verified=False。
        忘了写字段不能被静默升成 A 类：A 类可 verified=True、可弹通知，
        「宁缺勿假」要求默认只往少通知的方向偏。"""
        rules_path = ROOT / "scripts" / "promo-rules.json"
        rules = promo_fetch.load_rules(rules_path)
        domains, _labels = promo_fetch.load_rule_meta(rules_path)
        html = (FIXTURES / "aliyun-billing-2026-10-09.html").read_text(encoding="utf-8")
        text = promo_fetch.visible_text(html)
        no_class = dict(rules[0])
        del no_class["class"]
        promos = promo_fetch.parse_page(
            rules=[no_class], text=text,
            url="https://help.aliyun.com/zh/model-studio/billing-for-model-studio",
            line="gw-bailian", fetched_at="2026-10-10T00:40:00+08:00", today="2026-10-10",
            official_domains=domains)
        self.assertEqual(len(promos), 1)
        self.assertEqual(promos[0]["class"], "promotion",
                         "漏写 class 的默认值必须是 promotion（B 类），不是 peak_valley —— "
                         "默认 A 类 = 忘了写字段就拿到弹通知资格")
        self.assertFalse(promos[0]["verified"],
                         "忘了写 class 不能静默升成 A 类（verified=True 可弹通知）")


# ═════════════════════════════ Task 4：CLI 契约 ═════════════════════════════

SCRIPT = ROOT / "scripts" / "promo-fetch.py"


def run_cli(manifest, rules=None, extra_args=()):
    """跑一次真实子进程，返回 (returncode, stdout, stderr)。"""
    cmd = [sys.executable, str(SCRIPT), *extra_args]
    if rules is not None:
        cmd += ["--rules", str(rules)]
    proc = subprocess.run(cmd, input=json.dumps(manifest), capture_output=True,
                          text=True, timeout=120)
    return proc.returncode, proc.stdout, proc.stderr


def write_offline_rules(tmpdir):
    """造一份指向 fixture 的规则。生产规则的 url_domain_contains 是 help.aliyun.com，
    匹配不上 file:// 路径，所以离线测试要用自己的定位条件——**解析正则原样照抄生产规则**，
    否则测的就不是同一套正则了。"""
    prod = json.loads((ROOT / "scripts" / "promo-rules.json").read_text(encoding="utf-8"))
    rule = dict(prod["rules"][0])
    rule["url_domain_contains"] = "aliyun-billing-2026-10-09.html"
    rule["url_path_contains"] = ""
    out = dict(prod, rules=[rule])
    path = Path(tmpdir) / "rules.json"
    path.write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
    return path


def make_local_server(page_bytes, status=200):
    """起一个只会回同一份页的本地 HTTP 服务（回环，不出网）。返回 (server, Handler)。

    Handler.hits 是收到的 GET 数——URL 去重测试靠它在**服务端**数请求，
    比「两次指纹相同」强：抓两遍指纹也一样相同。"""
    class Handler(http.server.BaseHTTPRequestHandler):
        hits = 0

        def do_GET(self):
            Handler.hits += 1
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(page_bytes)))
            self.end_headers()
            self.wfile.write(page_bytes)

        def log_message(self, *args):
            pass  # 别把 HTTP 访问日志混进测试输出

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, Handler


class CliContractTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.rules = write_offline_rules(self.tmp.name)
        self.url = (FIXTURES / "aliyun-billing-2026-10-09.html").as_uri()

    def test_happy_path_schema_and_fields(self):
        code, out, err = run_cli(
            [{"line": "gw-bailian", "url": self.url, "previous_fingerprint": None}],
            rules=self.rules)
        self.assertEqual(code, 0, "stderr=%s" % err)
        doc = json.loads(out)
        self.assertEqual(doc["schema"], 1)
        self.assertIn("fetched_at", doc)
        self.assertIn("today", doc)
        self.assertEqual(len(doc["pages"]), 1)
        page = doc["pages"][0]
        for key in ("line", "url", "status", "http_status", "bytes", "visible_chars",
                    "fingerprint", "error", "note", "unchanged", "promotions"):
            self.assertIn(key, page, "页级输出缺键 %r —— Swift 的 Codable 会整条解码失败" % key)
        self.assertEqual(page["line"], "gw-bailian")
        self.assertEqual(page["status"], "ok")
        # 3562 = 整个 fixture 过一遍 visible_text（含烘焙时套的 <title> 那 49 字符）；
        # 烘焙窗口本身是 3513，别混。原计划写 3612 是推算值，见修正 13 的「三个数字」表。
        self.assertEqual(page["visible_chars"], 3562)
        self.assertIsNone(page["http_status"], "file:// 没有 HTTP 状态码，别编一个 200 出来")
        self.assertIsNone(page["error"])
        self.assertIsNone(page["note"])
        self.assertFalse(page["unchanged"])
        self.assertEqual(len(page["promotions"]), 1)
        self.assertEqual(page["promotions"][0]["id"], "bailian-peakvalley-deepseek")
        self.assertEqual(page["promotions"][0]["line"], "gw-bailian")
        # T4-R1 反例对照：几 KB 的小页面不该有截断信号（正例在 TruncationTest，
        # 两个方向都钉住，否则这个字段就退回「失败与通过输出一样」的假检查）。
        self.assertFalse(page["truncated"], "小页面不该报截断")
        self.assertNotIn("截断", err)

    def test_unchanged_flag_and_still_parses(self):
        """🔴 核心不变量：unchanged=True 时 promotions 仍然非空。
        空数组 + 照单全收 = 面板变空，而用户分不清「优惠结束」和「程序弄丢了」。"""
        code, out, _ = run_cli(
            [{"line": "gw-bailian", "url": self.url, "previous_fingerprint": None}],
            rules=self.rules)
        fp = json.loads(out)["pages"][0]["fingerprint"]

        code, out, err = run_cli(
            [{"line": "gw-bailian", "url": self.url, "previous_fingerprint": fp}],
            rules=self.rules)
        self.assertEqual(code, 0, err)
        page = json.loads(out)["pages"][0]
        self.assertTrue(page["unchanged"], "同一个文件第二次抓必须判为 unchanged")
        self.assertEqual(len(page["promotions"]), 1,
                         "unchanged 也必须带 promotions —— 这是 Task 4 的设计决定")

    def test_changed_flag(self):
        other = Path(self.tmp.name) / "other.html"
        other.write_text("<html><body><p>" + "别的页" * 400 + "</p></body></html>",
                         encoding="utf-8")
        code, out, _ = run_cli(
            [{"line": "l", "url": self.url, "previous_fingerprint": None}], rules=self.rules)
        fp = json.loads(out)["pages"][0]["fingerprint"]
        code, out, _ = run_cli(
            [{"line": "l", "url": other.as_uri(), "previous_fingerprint": fp}],
            rules=self.rules)
        page = json.loads(out)["pages"][0]
        self.assertFalse(page["unchanged"])
        self.assertEqual(page["status"], "parse-failed")
        self.assertEqual(page["note"], "no-rule-matched-url")

    def test_same_url_two_lines_fetches_once_emits_two_pages(self):
        """两条线路配了同一个页 → 只抓一次（别把人家服务器打两遍），
        但每条线路都要有自己的页记录，否则 Swift 的按线路存储会缺一块。"""
        manifest = [
            {"line": "gw-a", "url": self.url, "previous_fingerprint": None},
            {"line": "gw-b", "url": self.url, "previous_fingerprint": None},
        ]
        code, out, err = run_cli(manifest, rules=self.rules)
        self.assertEqual(code, 0, err)
        pages = json.loads(out)["pages"]
        self.assertEqual([p["line"] for p in pages], ["gw-a", "gw-b"])
        self.assertEqual(pages[0]["fingerprint"], pages[1]["fingerprint"])
        self.assertEqual(pages[0]["promotions"][0]["line"], "gw-a")
        self.assertEqual(pages[1]["promotions"][0]["line"], "gw-b")

    def test_unreachable_url_exits_zero_and_reports_fetch_failed(self):
        """T4-R3 退出码断言之一：退出码与「有没有情报」解耦，每页都失败也是 0。
        如果用 1 表示「没抓到情报」，Swift 就分不清「网断了」和「脚本坏了」。"""
        code, out, err = run_cli(
            [{"line": "gw-x", "url": "http://127.0.0.1:1/x", "previous_fingerprint": None}],
            rules=self.rules, extra_args=("--timeout", "3"))
        self.assertEqual(code, 0, "抓不到页不是脚本崩了。stderr=%s" % err)
        page = json.loads(out)["pages"][0]
        self.assertEqual(page["status"], "fetch-failed")
        self.assertTrue(page["error"], "必须带 error 文本，不能只给一个状态词")
        self.assertEqual(page["promotions"], [])
        self.assertEqual(page["visible_chars"], 0)

    def test_missing_file_url_is_fetch_failed(self):
        code, out, _ = run_cli(
            [{"line": "l", "url": "file:///definitely-not-here-xyz.html",
              "previous_fingerprint": None}],
            rules=self.rules, extra_args=("--timeout", "3"))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out)["pages"][0]["status"], "fetch-failed")

    def test_empty_manifest_is_valid(self):
        code, out, err = run_cli([], rules=self.rules)
        self.assertEqual(code, 0, err)
        doc = json.loads(out)
        self.assertEqual(doc["pages"], [])
        self.assertEqual(doc["schema"], 1)

    def test_bad_manifest_json_exits_one(self):
        """T4-R3 退出码断言之二：manifest 坏 = 用法错误，退出码 1。"""
        proc = subprocess.run(
            [sys.executable, str(SCRIPT), "--rules", str(self.rules)],
            input="{不是 JSON", capture_output=True, text=True, timeout=60)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("manifest", proc.stderr.lower(),
                      "stderr 要说清是哪一层坏了，别只丢一个 traceback")

    def test_missing_rules_file_exits_one(self):
        """T4-R3 退出码断言之三：规则文件读不了 = 用法错误，退出码 1。
        M-5（2026-10-10 复审）：断言**消息文本**而不是「stderr 非空」——
        非空断言会被 traceback 蒙过（AGENTS.md 验证纪律 #1：断言正面证据）。"""
        code, _out, err = run_cli([], rules=Path(self.tmp.name) / "nope.json")
        self.assertEqual(code, 1)
        self.assertIn("规则文件读不了", err,
                      "stderr 必须点名是规则文件这层坏了——实测消息是「规则文件读不了 …」")

    def test_stdout_is_pure_json(self):
        """Swift 用 JSONDecoder 直接吃 stdout。任何一行 print 调试都会让它整体解码失败。
        所以：诊断信息一律走 stderr。"""
        code, out, _err = run_cli(
            [{"line": "l", "url": self.url, "previous_fingerprint": None}], rules=self.rules)
        self.assertEqual(code, 0)
        json.loads(out)  # 不抛就算过
        self.assertTrue(out.lstrip().startswith("{"))

    def test_default_rules_path_is_next_to_the_script(self):
        """不传 --rules 时用脚本同目录的 promo-rules.json。
        这很重要：装到 ~/.claude/bin/ 之后 cwd 是任意的，不能依赖相对路径。"""
        code, out, err = run_cli(
            [{"line": "l", "url": "http://127.0.0.1:1/x", "previous_fingerprint": None}],
            extra_args=("--timeout", "2"))
        self.assertEqual(code, 0, "默认规则文件应能加载。stderr=%s" % err)

    def test_no_secret_looking_strings_in_output(self):
        """密钥卫生：输出会落盘到 ~/.claude/ccpod-promotions.json。
        fixture 里塞一个假密钥，断言它不出现在 stdout。"""
        leaky = Path(self.tmp.name) / "leaky.html"
        body = "定价说明 " * 200
        leaky.write_text(
            "<html><head><script>var k='sk-live-DEADBEEFDEADBEEF';</script></head>"
            "<body><p>" + body + "</p></body></html>", encoding="utf-8")
        rules = write_offline_rules(self.tmp.name)
        prod = json.loads(rules.read_text(encoding="utf-8"))
        prod["rules"][0]["url_domain_contains"] = "leaky.html"
        rules.write_text(json.dumps(prod, ensure_ascii=False), encoding="utf-8")
        code, out, err = run_cli(
            [{"line": "l", "url": leaky.as_uri(), "previous_fingerprint": None}],
            rules=rules, extra_args=("--timeout", "3"))
        self.assertEqual(code, 0, err)
        self.assertNotIn("DEADBEEF", out)
        self.assertNotIn("DEADBEEF", err)

    def test_non_string_url_is_fetch_failed_not_crash(self):
        """一页的坏 manifest 条目（url 非字符串）不许弄丢全部页的输出：
        必须落成该页的 fetch-failed、退出码 0，而不是击穿成进程级异常退 1。
        （2026-10-10 实测抓出：Request() 构造在 try 外 + rule_matches_url 的
        `dom not in url` TypeError，两处叠加才崩的，两处都已修。）"""
        manifest = [
            {"line": "bad", "url": 123, "previous_fingerprint": None},
            {"line": "good", "url": self.url, "previous_fingerprint": None},
        ]
        code, out, err = run_cli(manifest, rules=self.rules)
        self.assertEqual(code, 0, "坏条目击穿了整个进程。stderr=%s" % err)
        pages = json.loads(out)["pages"]
        self.assertEqual([p["line"] for p in pages], ["bad", "good"],
                         "坏条目也要有自己的页记录，好条目不能被连坐")
        self.assertEqual(pages[0]["status"], "fetch-failed")
        self.assertIn("unknown url type", pages[0]["error"])
        self.assertEqual(pages[0]["promotions"], [])
        self.assertEqual(pages[1]["status"], "ok")

    def test_unhashable_url_is_fetch_failed_not_crash(self):
        """I-1（2026-10-10 复审，协调者实测复现）：truthy 但**不可哈希**的 url
        （如 ["x"]）躲过 `if not url`，却在 `url not in cache` 的 dict 键查询处抛
        TypeError——比 url:123 更早，根本到不了 fetch，击穿到顶层兜底 → rc=1、
        stdout 空、好页连坐。修复后必须：① rc==0 ② stdout 是完整 JSON
        ③ 好页在且状态正常 ④ 坏页有页级记录且 fetch-failed。
        🔴 进程内直调 main()（不是 run_cli 子进程）：变异测试靠内存 exec 换模块，
        只够到进程内调用——子进程读的是磁盘上的未变异文件，锁不住这条不变量。
        🔴 main() 抛的异常要用 self.fail 转成**断言红**：直接让异常冒出去是异常红，
        变异引擎不算它抓住了变异（AGENTS.md 验证纪律 #2）。"""
        manifest = [
            {"line": "bad", "url": ["x"], "previous_fingerprint": None},
            {"line": "good", "url": self.url, "previous_fingerprint": None},
        ]
        buf = io.StringIO()
        try:
            with mock.patch("sys.stdin", io.StringIO(json.dumps(manifest))), \
                    contextlib.redirect_stdout(buf):
                rc = promo_fetch.main(["--rules", str(self.rules), "--timeout", "3"])
        except Exception as exc:
            self.fail("不可哈希 url 击穿了 main()：%s: %s" % (type(exc).__name__, exc))
        self.assertEqual(rc, 0, "① 坏条目击穿了整个进程（rc=%s）" % rc)
        doc = json.loads(buf.getvalue())  # ② stdout 是完整 JSON（崩了就是空/半截）
        pages = doc["pages"]
        self.assertEqual([p["line"] for p in pages], ["bad", "good"],
                         "④ 坏条目也要有自己的页记录——少一行就是静默丢页")
        self.assertEqual(pages[0]["status"], "fetch-failed",
                         "④ 坏页必须是页级 fetch-failed，不是静默跳过")
        # 正面证据：error 真的带「为什么失败」（["x"] 原样传给 fetch，由通用 except
        # 收编——实测是 ValueError: unknown url type: "['x']"，与 url:123 同族）
        self.assertIn("unknown url type", pages[0]["error"])
        self.assertEqual(pages[0]["promotions"], [])
        self.assertEqual(pages[1]["status"], "ok", "③ 好页不能被连坐")


class TruncationTest(unittest.TestCase):
    """T4-R1：体积上限必须带可见信号。静默截断的害处：parse-failed 时
    「正则没匹配上」和「正文被截掉了」两种情况长得一模一样。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_body_over_cap_reports_truncated(self):
        cap = promo_fetch.MAX_FETCH_BYTES
        big = Path(self.tmp.name) / "big.html"
        # 「定价说明与折扣条款 」= 9 个汉字(27B) + 空格(1B) = 28B/词；超上限 64 KiB 以上
        count = (cap + 65536) // 28 + 1
        big.write_text("<html><body><p>" + "定价说明与折扣条款 " * count
                       + "</p></body></html>", encoding="utf-8")
        # 观测前提：文件必须真的超了上限，否则后面全是空转
        self.assertGreater(big.stat().st_size, cap,
                           "测试输入没超过 MAX_FETCH_BYTES——截断路径根本没被走到")
        rules = write_offline_rules(self.tmp.name)
        prod = json.loads(rules.read_text(encoding="utf-8"))
        prod["rules"][0]["url_domain_contains"] = "big.html"
        rules.write_text(json.dumps(prod, ensure_ascii=False), encoding="utf-8")
        code, out, err = run_cli(
            [{"line": "l", "url": big.as_uri(), "previous_fingerprint": None}],
            rules=rules, extra_args=("--timeout", "3"))
        self.assertEqual(code, 0, "截断不是错误——退出码必须仍是 0。stderr=%s" % err)
        page = json.loads(out)["pages"][0]
        self.assertTrue(page["truncated"],
                        "超限必须置 truncated——这是「正文被截掉」与「正则没匹配上」的唯一区分")
        self.assertIn("截断", err, "stderr 诊断通道必须有截断行——页级字段之外的第二路信号")
        self.assertGreater(page["visible_chars"], 0, "锚点：截断后的正文真的被处理了")
        # 口径：bytes 是「截断后正文再编码」的字节数。截断点落在多字节汉字中间时，
        # errors="replace" 会把尾部残缺序列换成 1 个 U+FFFD（3 字节），再编码后
        # 比上限多 1–2 字节（实测 4194306 = cap+2）。下界 cap 证明真截在了上限处，
        # 上界 cap+4 覆盖单个残缺序列的最大膨胀，两边都钉。
        self.assertTrue(cap <= page["bytes"] <= cap + 4,
                        "处理量应压在 [%d, %d]，实际 %d"
                        % (cap, cap + 4, page["bytes"]))
        # 失败可见性成对出现：parse-failed 的 note 照常给出，同时 truncated 说明另一层
        self.assertEqual(page["status"], "parse-failed")
        self.assertEqual(page["note"], "rule-matched-no-hit")


class TruncationUnitTest(unittest.TestCase):
    """T4-R1 的进程内锁：直接调 fetch() 断言截断标志。

    子进程版（TruncationTest）测的是真实装机形态，但变异测试（内存 exec 换模块）
    只能够到**进程内**调用——没有这组，截断不变量在变异下是锁不住的。"""

    def test_fetch_marks_over_cap_file_truncated(self):
        cap = promo_fetch.MAX_FETCH_BYTES
        with tempfile.TemporaryDirectory() as tmp:
            big = Path(tmp) / "big.html"
            big.write_text("词" * (cap // 3 + 100), encoding="utf-8")  # 每字 3 字节
            self.assertGreater(big.stat().st_size, cap, "观测前提：输入必须真超上限")
            status, html, error, truncated = promo_fetch.fetch(big.as_uri(), timeout=3)
            self.assertIsNone(error)
            self.assertIsNone(status, "file:// 没有 HTTP 状态码")
            self.assertTrue(truncated, "超限必须置 truncated")
            # 残缺尾序列 decode 成 U+FFFD 再编码最多膨胀 2 字节（实测 cap+2）
            self.assertLessEqual(len(html.encode("utf-8")), cap + 4)
            self.assertGreater(len(html), 0, "锚点：截断后仍有正文")

    def test_fetch_under_cap_file_not_truncated(self):
        with tempfile.TemporaryDirectory() as tmp:
            small = Path(tmp) / "small.html"
            small.write_text("<html><body><p>定价说明</p></body></html>", encoding="utf-8")
            _status, html, error, truncated = promo_fetch.fetch(small.as_uri(), timeout=3)
            self.assertIsNone(error)
            self.assertFalse(truncated, "小文件不该报截断——反例对照")
            self.assertIn("定价说明", html)

    def test_fetch_exactly_cap_bytes_not_truncated(self):
        """M-4（2026-10-10 复审）：`>` 的精确边界。恰好 cap 字节的页**一字节没少**，
        truncated 必须 False——把 `>` 变异成 `>=` 时恰好 cap 的页会被误标截断，
        此前的小文件/超限两端测试都拦不住（都不会红），本条补锁。"""
        cap = promo_fetch.MAX_FETCH_BYTES
        with tempfile.TemporaryDirectory() as tmp:
            exact = Path(tmp) / "exact.html"
            exact.write_bytes(b"x" * cap)
            self.assertEqual(exact.stat().st_size, cap,
                             "观测前提：输入必须恰好 cap 字节，否则测的不是这个边界")
            _status, html, error, truncated = promo_fetch.fetch(exact.as_uri(), timeout=3)
            self.assertIsNone(error)
            self.assertFalse(truncated, "恰好等于上限 ≠ 被截断——一字节都没少")
            self.assertEqual(len(html), cap, "正文必须原样保留 cap 字符")

    def test_fetch_cap_plus_one_bytes_truncated(self):
        """M-4 的另一边：cap+1 字节 → truncated 必须 True，且正文削到恰好 cap。
        与恰好 cap 那条成对，`>` 边界的两侧都钉住。"""
        cap = promo_fetch.MAX_FETCH_BYTES
        with tempfile.TemporaryDirectory() as tmp:
            over = Path(tmp) / "over.html"
            over.write_bytes(b"x" * (cap + 1))
            self.assertEqual(over.stat().st_size, cap + 1,
                             "观测前提：输入必须恰好 cap+1 字节")
            _status, html, error, truncated = promo_fetch.fetch(over.as_uri(), timeout=3)
            self.assertIsNone(error)
            self.assertTrue(truncated, "超上限 1 字节也必须置 truncated")
            self.assertEqual(len(html), cap, "正文必须被削到恰好 cap 字符")


class HttpErrorBodyTest(unittest.TestCase):
    """T4-R2：HTTP 4xx/5xx 的 body 摘要（前 1KB → visible_text → redact）拼进 error。"""
    def test_body_snippet_visible_and_redacted(self):
        # 密钥出现在两处：script 里（visible_text 应整块丢弃）和可见正文里（redact 应 mask）。
        body = ("<html><head><script>var k='sk-live-DEADBEEFDEADBEEF';</script></head>"
                "<body><p>Access denied: token sk-live-DEADBEEFDEADBEEF lacks scope."
                " 请联系管理员。</p></body></html>").encode("utf-8")
        server, _handler = make_local_server(body, status=403)
        self.addCleanup(server.shutdown)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        rules = write_offline_rules(tmp.name)
        url = "http://127.0.0.1:%d/x" % server.server_address[1]
        code, out, err = run_cli(
            [{"line": "l", "url": url, "previous_fingerprint": None}],
            rules=rules, extra_args=("--timeout", "3"))
        self.assertEqual(code, 0, "HTTP 403 是页级失败不是脚本崩——退出码必须 0。stderr=%s" % err)
        page = json.loads(out)["pages"][0]
        self.assertEqual(page["status"], "fetch-failed")
        self.assertEqual(page["http_status"], 403)
        self.assertIn("HTTP 403", page["error"])
        self.assertIn("Access denied", page["error"], "正面证据：body 摘要真的浮出来了")
        self.assertIn("***REDACTED***", page["error"], "正面证据：redact 真的跑了")
        self.assertNotIn("DEADBEEF", page["error"])
        self.assertNotIn("DEADBEEF", out)
        self.assertNotIn("DEADBEEF", err)


class HttpErrorSnippetTest(unittest.TestCase):
    """T4-R2 的进程内锁：直接调 http_error_snippet()，不依赖本地 HTTP 服务。
    与 HttpErrorBodyTest 的分工同 TruncationUnitTest：这组才能被变异测试够到。"""

    def test_snippet_strips_script_and_redacts(self):
        body = ("<html><head><script>var k='sk-live-DEADBEEFDEADBEEF';</script></head>"
                "<body><p>Access denied: token sk-live-DEADBEEFDEADBEEF lacks scope.</p>"
                "</body></html>").encode("utf-8")
        exc = urllib.error.HTTPError(
            "http://x/", 403, "Forbidden", None, io.BytesIO(body))
        snippet = promo_fetch.http_error_snippet(exc)
        self.assertIn("Access denied", snippet, "正面证据：可见正文的摘要真的在")
        self.assertIn("***REDACTED***", snippet, "正面证据：redact 真的跑了")
        self.assertNotIn("DEADBEEF", snippet, "可见正文里的密钥形状必须被 mask")
        self.assertNotIn("var k", snippet, "script 里的内容必须被 visible_text 整块丢弃")

    def test_snippet_length_bounded_on_huge_body(self):
        """I-2（T4-R2 验收第三条，台账 plan-corrections.md:370-372 原文）：
        「③ 长度不超上限。三条都要断言——只断言①的话，把整个 error 置空也能过」。
        🔴 变异实证（复审者实测）：把实现里 `exc.read(limit)` 改成 `exc.read()`
        （错误页全量进 error，违反 AGENTS.md 硬约定）时，此前的 99 条测试全绿——
        这道防线只靠实现自觉，没有锁。本条补锁。
        上限校准依据（2026-10-10 实测，limit=1024；每个数都带量法，可本机复现）：
          · 纯 ASCII 正文 204853 B → snippet 1009 字符（read(1024) 生效）。量法：
            照抄本测试的 filler/big 两行构造，量 len(big) 与 http_error_snippet(exc)；
          · redact 最坏膨胀：`sk-aaaaaabbbb `（13 字符/匹配 + 1 分隔空格）铺满 200KB。
            与本测试同构的 html 包装实测 **1729**：前 1024B 里标签占 15B
            （`<html><body><p>`，实量 len(tag)），visible_text 后 1009 字符
            （= 1024 − 15，标签剥掉不留字符）、72 个匹配，每匹配 13→23
            （保留前缀 9 + `***REDACTED***` 14）
            膨胀 +10，1009+72×10=1729。裸串（无 html 包装）同法实测 1754 =
            1024+73×10，这是**理论上界口径**（73×13B+72 分隔=1021≤1024，74 个
            匹配装不下；非同构实测）；
          · visible_text 各步只缩不涨（剥标签 1 空格、反转义缩短、空白折叠），
            所以进 redact 的文本 ≤ 1024 字符，上界成立。
          上限钉 **1800**：距 1729 余 71（≈4%）、距上界口径 1754 只余 46（≈2.6%）——
          余量很薄，改 body 的密钥排布/分隔必须连带重估 1800。方向提醒：去掉单元间
          分隔空格不会更膨胀（无分隔时整串被一条正则吞成单匹配，实测塌缩成 23 字符）。
          不截断时 200KB body 实测产出 204819 字符 snippet，远超此界 →
          变异 `exc.read(limit)`→`exc.read()` 转红。
        下界（snippet 非空 + 含可见正文）：否则「返回空串」也满足长度上限，不是检查。"""
        filler = b"Access denied: request rejected by edge gateway. "
        big = b"<html><body><p>" + filler * (200 * 1024 // len(filler) + 1) \
            + b"</p></body></html>"
        self.assertGreater(len(big), 1024 * 100,
                           "观测前提：body 必须远超 1 KB，否则截断路径根本没被走到")
        exc = urllib.error.HTTPError("http://x/", 403, "Forbidden", None, io.BytesIO(big))
        snippet = promo_fetch.http_error_snippet(exc)
        self.assertGreater(len(snippet), 0, "下界：snippet 非空")
        self.assertIn("Access denied", snippet, "下界：可见正文真的浮出来了")
        self.assertLessEqual(
            len(snippet), 1800,
            "上界被突破（实测 %d 字符）：错误页 body 没有被 limit=1024 截住——"
            "error 会落盘+回显，全量进 error 违反 AGENTS.md 密钥纪律"
            % len(snippet))

    def test_unreadable_body_gives_empty_snippet(self):
        """body 读不出来只能给空摘要——摘要失败不能连累 error 本身。"""
        class _Boom(io.BytesIO):
            def read(self, *args):
                raise OSError("connection reset")

        exc = urllib.error.HTTPError(
            "http://x/", 502, "Bad Gateway", None, _Boom())
        self.assertEqual(promo_fetch.http_error_snippet(exc), "")


class RedactImportTest(unittest.TestCase):
    """T4-R2：redact 的 import 必须在**两种执行上下文**都成立。
    `scripts/` 不是包（无 __init__.py），这条 import 很容易只照顾一种上下文。"""

    def test_module_context_redact_imported_and_masks(self):
        """上下文一：本文件经 importlib 加载 promo-fetch.py（cwd=仓库根，命名空间包）。
        顶部 import 失败的话 exec_module 当场抛，整个测试文件都起不来——
        这条能跑本身就是证据；再钉行为：密钥形状必须被 mask。"""
        self.assertTrue(callable(promo_fetch.redact),
                        "promo_fetch.redact 不存在——模块上下文的 import 分支没走通")
        masked = promo_fetch.redact("token sk-live-DEADBEEFDEADBEEF here")
        self.assertIn("***REDACTED***", masked)
        self.assertNotIn("DEADBEEF", masked)

    def test_script_context_import_survives(self):
        """上下文二：作为脚本直跑（sys.path[0]=scripts/，`scripts.` 前缀不可用，
        import 必须走 fallback 分支）。空 manifest 探活：进程能起、回纯 JSON、退 0，
        说明顶部那条 try/except import 没把脚本弄挂。"""
        code, out, err = run_cli([])
        self.assertEqual(code, 0, "脚本直跑起不来——十有八九是 import 只照顾了一种上下文。"
                                  "stderr=%s" % err)
        doc = json.loads(out)
        self.assertEqual(doc["schema"], 1)


class RedactIdempotencyTest(unittest.TestCase):
    """逐形状：单形状孤立串上 redact(redact(x)) == redact(x)。

    复审 A 把 HTTPError 分支改成 return 咽喉点整体脱敏后，snippet 会被脱敏两次
    （http_error_snippet 内部一次 + 咽喉点一次）——这条从「好习惯」变成**承重**：
    若第二次能把第一次的 mask 洗掉或改形，咽喉点脱敏就成了泄漏口。
    样本覆盖 SECRET_PATTERNS 全部五类形状；每条先断言第一次真的 mask 了
    （否则等值断言对「本来就不匹配」的样本是空转绿）。

    🔴 **本类不是「redact 幂等」的全称证明，别当全称命题引用。**
    2026-10-10 delta 复审 M-1 实测出反例：两个不同形状的密钥**紧邻**时，
    前一个的 mask 产物会改变后一个的边界条件，第二遍能 mask 到第一遍漏的。
    本类 7 个样本都是孤立串，所以等值断言成立——成立的范围就是「单形状孤立串」。
    相邻形状与真正的承重命题（单调：只多不少、不复活、二遍达不动点）
    由 RedactMonotonicityTest 钉住。"""

    def test_redact_idempotent_on_all_secret_shapes(self):
        samples = [
            "token sk-live-DEADBEEFDEADBEEF here",      # sk- 前缀（含 6 字符保留段）
            "yessk-abcdefgh12345678",                   # yessk- 变体
            "ark-abcdef1234567890",                     # 火山 ark-
            "cr-abcdefg12345678",                       # cr- / ccr_ 家族（两形态各一）
            "ccr_abcdef12345678",
            "abcdef01234567890123456789012345.Abcdefghijklmnop",  # 6+26 hex + . + 16
            "Authorization: Bearer abcdefghijklmnop12",  # Bearer 头
        ]
        for sample in samples:
            once = promo_fetch.redact(sample)
            self.assertIn("***REDACTED***", once,
                          "样本没被 mask，等值断言对它是空转绿：%r" % sample)
            self.assertEqual(promo_fetch.redact(once), once,
                             "单形状孤立样本上 redact 不幂等：二次脱敏改动了已 mask 的结果：%r"
                             % sample)


class RedactMonotonicityTest(unittest.TestCase):
    """🔴 咽喉点「脱敏两次」真正依赖的命题：**单调**，不是幂等。

    来由（2026-10-10 delta 复审 M-1，协调者用 /tmp/verify-m1.py 独立复现）：
    严格幂等 `redact(redact(x)) == redact(x)` 作为全称命题**不成立**。反例机理——
    `ark-abcdef12345678sk-…` 里 sk- 前是 alnum `8`，被 P0 的 `(?<![A-Za-z0-9])`
    lookbehind 挡住；P1 先把 ark 段 mask 成 `ark-abcdef***REDACTED***`，
    sk- 前面变成 `*`（非 alnum）→ 第二遍 P0 放行，mask 到第一遍漏的那截。
    注意**不是**「mask 产物自身又匹配了别的 pattern」：`***REDACTED***` 不触发
    任何一条（实测 5 条逐条 search 均无命中），是 mask 改变了**相邻 token 的边界**。

    所以「二次脱敏安全」的正确论证是方向性的：第二遍只会更严。三条都要断言——
    少了「不复活」那条，一个把已 mask 内容洗回原文的实现也能让前两条绿。"""

    # 🔴 拼接构造，源码行不出现整串（同上，理由与代价见 fetch 那处的注释）。
    # ADJACENT **由 ARK_RAW + SK_RAW 派生**而不是硬写一整串：派生让"两段密钥相邻"
    # 这个反例的构造条件在代码里显式成立，不靠两个字面量恰好写得挨着
    # （挨着是靠不住的——改一个忘另一个，反例就静默失效，而测试仍会绿）。
    ARK_RAW = "ark-" + "abcdef12345678"
    SK_RAW = "sk-" + "qrstuvwxyz1234567890ab"
    ADJACENT = ARK_RAW + SK_RAW

    def test_second_pass_is_monotonic_and_reaches_fixpoint(self):
        once = promo_fetch.redact(self.ADJACENT)
        twice = promo_fetch.redact(once)

        # 观测前提：反例必须真的复现，否则本测试是在验一个不存在的形状（空转绿）。
        self.assertNotEqual(twice, once,
                            "反例没复现——P1 的 mask 未解除 P0 的 lookbehind 封锁。"
                            "要么 SECRET_PATTERNS 的顺序/形状变了，要么本样本失效；"
                            "两种情况都说明本测试已不再守卫它声称守卫的东西")
        self.assertIn(self.SK_RAW, once,
                      "第一遍本该漏掉 sk 段（这正是「单遍不够」的证据）；若没漏，"
                      "反例形状已变，上面的 assertNotEqual 也就失去解释")

        # 正面证据（纪律 #1）：第一遍**确实产出了 mask 产物**，且产物就是那个 token。
        # 🔴 这条是承重的，不是好看的。2026-10-10 实测（.local/mutation-task4.py 的 M7：
        #   把 P1 的替换串从 \1***REDACTED*** 改成 \1[MASK]）——变异后上面两条与下面
        #   ①②③ **全部仍然绿**，因为 ① 是 `assertGreaterEqual`，实测变成 `1 >= 0`；
        #   一个「产物身份被换掉」的 redact 就这么通过了整套单调性论证。
        #   M7 的 expect_red 在补这条之前回来是「绿 🔴 ← 这条测试锁不住该不变量，是装饰」，
        #   补上之后才变断言红。阳性对照见台账（替身确实生效、生产 redact 未被污染）。
        self.assertIn("***REDACTED***", once,
                      "第一遍没产出标准 mask 产物 → ① 的 `只多不少` 退化成 `0 >= 0`/`1 >= 0` "
                      "这种弱比较，整套单调性论证就在验一个空集。可能是替换串被改了，"
                      "也可能 P1 根本没匹配上；两种都说明咽喉点「脱敏两次」的前提没了")
        # 诊断性正例：ark 段确实在第一遍就没了。
        # ⚠️ 诚实标注：这条**不是**新增检出力。ark 段若没被 mask，上面的
        #   assertNotEqual(twice, once) 会先响（P0 的 lookbehind 封锁没被解除 → 两遍相同），
        #   失败消息只会说「反例没复现」，读的人得自己推为什么。这条把原因直接点名。
        #   （范围限定：这是对我能构造出的变异的观察，不是「任何变异下都如此」的证明。）
        self.assertNotIn(self.ARK_RAW, once,
                         "ark 原文在第一遍后仍在 → P1 没匹配上（替换串或 pattern 变了）。"
                         "此时对 ARK_RAW 谈「不复活」没有意义：它压根没被脱敏过")

        # ① 只多不少
        self.assertGreaterEqual(twice.count("***REDACTED***"), once.count("***REDACTED***"),
                                "第二遍 mask 计数减少了——脱敏在往回退")
        # ② 不复活：第一遍漏的、和第一遍已 mask 的，第二遍后都不得以原文出现
        for raw in (self.ARK_RAW, self.SK_RAW):
            self.assertNotIn(raw, twice,
                             "密钥原文在第二遍后重新出现（复活）：%r" % raw[:12])
        # ③ 第二遍即达不动点（复审 fuzz 20000 串：r3 != r2 为 0 次）
        self.assertEqual(promo_fetch.redact(twice), twice,
                         "第三遍仍在改动 → 不动点深度 >2，「脱敏两次」的论证不成立")

    def test_mask_product_matches_no_pattern(self):
        """机理取证：mask 产物自身不触发任何 pattern（否则①的「只多不少」可能是
        产物被反复改写造成的假象，而不是真的在 mask 密钥）。

        🔴 pattern 列表从 `redact.__globals__` 取，不是从 promo_fetch 取：
        promo-fetch.py:35 只 `from … import redact`，**没有**把 SECRET_PATTERNS
        带进自己的命名空间（写 `promo_fetch.SECRET_PATTERNS` 会 AttributeError，
        本测试就成了异常红而非断言红）。穿过函数对象拿到的正是生产 `redact`
        闭包里迭代的那一份，不存在「测了另一个副本」的可能。"""
        token = "***REDACTED***"
        self.assertEqual(promo_fetch.redact(token), token,
                         "mask 产物被再次改动 → 计数增加不能解读为「更严」")
        patterns = promo_fetch.redact.__globals__["SECRET_PATTERNS"]
        self.assertEqual(len(patterns), 5,
                         "SECRET_PATTERNS 条数变了（现 %d）→ 本测试与"
                         "RedactIdempotencyTest 声称的「五类形状」覆盖已失效，"
                         "且 Swift SecretRedactor 那 5 条是否仍同形需重新核对"
                         % len(patterns))
        hit = [i for i, (pat, _repl) in enumerate(patterns) if pat.search(token)]
        self.assertEqual(hit, [],
                         "有 pattern 匹配 mask 产物本身，下标=%s" % hit)


class LoadRulesClassGateTest(unittest.TestCase):
    """纪律 5（修正 18）：缺 class / class 值不合法的规则在**加载层**拒收并留痕，
    不许等 parse_page 运行时才静默跳过——那是静默丢真情报。"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        prod = json.loads((ROOT / "scripts" / "promo-rules.json").read_text(encoding="utf-8"))
        self.good = prod["rules"][0]

    def _write(self, rules):
        path = Path(self.tmp.name) / "rules.json"
        path.write_text(json.dumps({"rules": rules}, ensure_ascii=False), encoding="utf-8")
        return path

    def test_missing_class_rejected_with_stderr_trace(self):
        bad = dict(self.good)
        del bad["class"]
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            rules = promo_fetch.load_rules(self._write([bad, self.good]))
        self.assertEqual([r["id"] for r in rules], [self.good["id"]],
                         "坏规则拒收，好规则必须活下来")
        self.assertIn("class", buf.getvalue(),
                      "拒收必须往 stderr 留痕——静默拒收 = 静默丢规则，和静默丢情报同罪")

    def test_unknown_class_value_rejected_too(self):
        """class 只有 peak_valley / promotion 两个合法值：第三个值流到 Swift 的
        枚举解码就是整页 Codable 失败，所以加载层就挡掉。"""
        weird = dict(self.good, **{"class": "flash-sale"})
        buf = io.StringIO()
        with contextlib.redirect_stderr(buf):
            rules = promo_fetch.load_rules(self._write([weird]))
        self.assertEqual(rules, [])
        self.assertIn("class", buf.getvalue())


class CliRuleMetaTest(unittest.TestCase):
    """纪律 4（修正 17-1）的 CLI 侧锁：main() 必须经 load_rule_meta 把
    official_domains / family_labels 喂给 parse_page。计划原稿手工 json.load
    提三键——那条路把 domains 打空时**没有任何测试会红**（变异已证）。
    这里拿本地回环当「官方域」。子进程版测真实装机形态；进程内直调 main()
    的两版是给变异测试（内存 exec 换模块）留的靶——变异只能够到进程内调用。"""

    def _rules_for(self, tmpdir):
        prod = json.loads((ROOT / "scripts" / "promo-rules.json").read_text(encoding="utf-8"))
        rule = dict(prod["rules"][0])
        rule["url_domain_contains"] = "127.0.0.1"
        rule["url_path_contains"] = ""
        data = dict(prod, rules=[rule], official_domains=["127.0.0.1"])
        path = Path(tmpdir) / "rules.json"
        path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
        return path

    def test_cli_feeds_rule_meta_into_parse_page(self):
        html = (FIXTURES / "aliyun-billing-2026-10-09.html").read_text(encoding="utf-8")
        server, _handler = make_local_server(html.encode("utf-8"))
        self.addCleanup(server.shutdown)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        rules = self._rules_for(tmp.name)
        url = "http://127.0.0.1:%d/zh/model-studio/billing-for-model-studio" \
            % server.server_address[1]
        code, out, err = run_cli(
            [{"line": "gw-bailian", "url": url, "previous_fingerprint": None}],
            rules=rules, extra_args=("--timeout", "5"))
        self.assertEqual(code, 0, err)
        page = json.loads(out)["pages"][0]
        self.assertEqual(page["status"], "ok")
        self.assertEqual(page["http_status"], 200)
        promos = page["promotions"]
        self.assertEqual(len(promos), 1)
        self.assertTrue(promos[0]["verified"],
                        "CLI 没把 load_rule_meta 的 official_domains 传进 parse_page"
                        "（空名单下 official 恒 False → verified 恒 False）"
                        "——正是修正 17-1 要堵的静默失效")
        self.assertTrue(promos[0]["source"]["official"])
        self.assertIn("DeepSeek", promos[0]["title"],
                      "家族标签没走 load_rule_meta 的 family_labels——"
                      "退化成 capitalize() 的「Deepseek」了")

    def test_main_in_process_feeds_rule_meta(self):
        """进程内直调 main()：变异测试能锁住的版本（换模块只影响进程内调用）。"""
        html = (FIXTURES / "aliyun-billing-2026-10-09.html").read_text(encoding="utf-8")
        server, _handler = make_local_server(html.encode("utf-8"))
        self.addCleanup(server.shutdown)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        rules = self._rules_for(tmp.name)
        url = "http://127.0.0.1:%d/zh/billing" % server.server_address[1]
        manifest = [{"line": "gw-bailian", "url": url, "previous_fingerprint": None}]
        buf = io.StringIO()
        # contextlib 没有 redirect_stdin（只有 stdout/stderr），stdin 用 mock.patch 换
        with mock.patch("sys.stdin", io.StringIO(json.dumps(manifest))), \
                contextlib.redirect_stdout(buf):
            rc = promo_fetch.main(["--rules", str(rules), "--timeout", "5"])
        self.assertEqual(rc, 0)
        promos = json.loads(buf.getvalue())["pages"][0]["promotions"]
        self.assertEqual(len(promos), 1)
        self.assertTrue(promos[0]["verified"],
                        "main() 没把 load_rule_meta 的 official_domains 传进 parse_page"
                        "——修正 17-1 的静默失效在进程内同样成立")
        self.assertIn("DeepSeek", promos[0]["title"])

    def test_main_in_process_unchanged_still_parses(self):
        """Task 4 设计决定的进程内版：unchanged=True 时 promotions 仍然照常返回。
        （子进程版 test_unchanged_flag_and_still_parses 测真实形态；这条是变异靶。）"""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        rules = write_offline_rules(tmp.name)
        url = (FIXTURES / "aliyun-billing-2026-10-09.html").as_uri()

        def run_once(prev):
            manifest = [{"line": "l", "url": url, "previous_fingerprint": prev}]
            buf = io.StringIO()
            with mock.patch("sys.stdin", io.StringIO(json.dumps(manifest))), \
                    contextlib.redirect_stdout(buf):
                rc = promo_fetch.main(["--rules", str(rules), "--timeout", "3"])
            self.assertEqual(rc, 0)
            return json.loads(buf.getvalue())["pages"][0]

        page1 = run_once(None)
        page2 = run_once(page1["fingerprint"])
        self.assertTrue(page2["unchanged"], "同页二抓必须判 unchanged")
        self.assertEqual(len(page2["promotions"]), 1,
                         "unchanged 也必须照常返回 promotions——空数组 + Swift 照单全收"
                         " = 面板变空，用户分不清「优惠结束」和「程序弄丢了」")


class FetchOnceServerCountTest(unittest.TestCase):
    def test_same_url_hits_server_exactly_once(self):
        """计划那条去重测试只能证明「两次指纹相同」（抓两遍指纹也一样）。
        这里在**服务端**数请求：两条线路同一 URL，GET 必须恰好 1 次。"""
        html = (FIXTURES / "aliyun-billing-2026-10-09.html").read_text(encoding="utf-8")
        server, handler = make_local_server(html.encode("utf-8"))
        self.addCleanup(server.shutdown)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        rules = write_offline_rules(tmp.name)
        prod = json.loads(rules.read_text(encoding="utf-8"))
        prod["rules"][0]["url_domain_contains"] = "127.0.0.1"
        rules.write_text(json.dumps(prod, ensure_ascii=False), encoding="utf-8")
        url = "http://127.0.0.1:%d/x" % server.server_address[1]
        manifest = [
            {"line": "gw-a", "url": url, "previous_fingerprint": None},
            {"line": "gw-b", "url": url, "previous_fingerprint": None},
        ]
        code, out, err = run_cli(manifest, rules=rules, extra_args=("--timeout", "5"))
        self.assertEqual(code, 0, err)
        self.assertEqual(handler.hits, 1,
                         "同一 URL 打了 %d 次服务器——去重没生效" % handler.hits)
        pages = json.loads(out)["pages"]
        self.assertEqual([p["line"] for p in pages], ["gw-a", "gw-b"])


class FatalFallbackTest(unittest.TestCase):
    """复审 B（2026-10-10）：顶层兜底抽成模块级 report_fatal（内联在 __main__ 里
    测试够不到）+ print 首行与 traceback 两处出口都过 redact。"""

    def test_rules_array_not_object_hits_fatal_fallback(self):
        """rules 文件顶层数组（而非对象）→ load_rules 里 data.get 抛 AttributeError，
        不被 main 的 except (OSError, ValueError) 接住 → 顶层兜底。
        锁住「抽函数没把兜底改坏」：rc=1、stdout 0 字节、stderr 有 AttributeError。"""
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        bad_rules = Path(tmp.name) / "rules.json"
        bad_rules.write_text('[{"class":"peak_valley"}]', encoding="utf-8")
        code, out, err = run_cli([], rules=bad_rules)
        self.assertEqual(code, 1,
                         "兜底必须退 1——0 会让 Swift 把「脚本崩了」当成「跑完了」。"
                         "stderr=%s" % err)
        self.assertEqual(len(out.encode("utf-8")), 0,
                         "stdout 必须纯空：Swift 的 JSONDecoder 不能吃到半截 JSON")
        self.assertIn("AttributeError", err,
                      "触发路径必须是 AttributeError（顶层数组没有 .get）——异常类型"
                      "变了说明触发路径漂了，这条测的就不是兜底了")
        # delta 复审 M-3 加固：本条是**真实子进程 + 真实生产触发路径**，
        # 而 traceback 那份出口原先只被下一条（进程内直调 report_fatal）钉住。
        # 生产唯一调用点在 __main__ 的 except 块内，与下一条同形——但「同形」是
        # 推理，这条是实测。format_exc 依赖 sys.exc_info()，抽成函数后仍取得到
        # 当前异常，就靠这行在真实进程里证明。
        self.assertIn("Traceback (most recent call last)", err,
                      "兜底没打出 traceback → report_fatal 的第二处出口"
                      "（traceback.format_exc()）失效，人肉调试通道瞎了一半")
        self.assertIn("promo-fetch 自身异常 AttributeError", err,
                      "兜底首行消息模板不许动——守卫它的是本测试与下一条，"
                      "不是 check-t4r3.sh（实测 2026-10-10 12:47：它三条 grep -F 断言的是"
                      "「规则文件读不了 / manifest JSON 解析失败 / manifest 必须是数组」，"
                      "全走 main() 自己的 return 1，到不了顶层兜底）")

    def test_report_fatal_redacts_print_line_and_traceback(self):
        """print 首行与 traceback 末行是**同一份 exc 文本的两次出口**，都必须脱敏。
        断言密钥原文出现次数 == 0（不是只看第一行）——只盯首行会漏掉 traceback
        那第二次。traceback 正文里的 raise 源码行也含密钥字面量，一并被数进来。"""
        buf = io.StringIO()
        try:
            raise ValueError("proxy echoed sk-live-DEADBEEFDEADBEEF in error")
        except ValueError as exc:
            with contextlib.redirect_stderr(buf):
                promo_fetch.report_fatal(exc)
        captured = buf.getvalue()
        self.assertIn("promo-fetch 自身异常 ValueError", captured,
                      "消息模板不许动——守卫它的是本条断言，不是 check-t4r3.sh"
                      "（该脚本的三条 grep -F 目标是别的消息，到不了顶层兜底，实测同上）")
        self.assertIn("Traceback (most recent call last)", captured,
                      "traceback 真的打出来了——顺带实测 format_exc 在 except 块内"
                      "调用的函数里仍取得到 sys.exc_info（抽函数没把它弄丢）")
        self.assertIn("***REDACTED***", captured, "正面证据：redact 真的跑了")
        self.assertEqual(captured.count("DEADBEEF"), 0,
                         "密钥原文出现 %d 次——print 首行或 traceback 那一份没过 redact"
                         % captured.count("DEADBEEF"))


if __name__ == "__main__":
    unittest.main()
