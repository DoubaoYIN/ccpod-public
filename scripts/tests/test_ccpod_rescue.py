"""ccpod-rescue：只清旧工具输出，用户原话/助手文本/配对块一字不动；只读源文件、新副本 0600、不覆盖。"""
import importlib.util
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("ccpod_rescue", HERE.parent / "ccpod-rescue.py")
rescue = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rescue)

SID = "11111111-2222-3333-4444-555555555555"


def _rows(n_tools=8):
    rows = [{"type": "permission-mode", "permissionMode": "bypassPermissions", "sessionId": SID},
            {"type": "user", "sessionId": SID, "cwd": "/tmp/proj",
             "message": {"role": "user", "content": "用户原话：把线路状态修好"}}]
    for i in range(n_tools):
        rows.append({"type": "assistant", "sessionId": SID, "message": {"role": "assistant", "content": [
            {"type": "text", "text": f"助手第 {i} 轮结论"},
            {"type": "tool_use", "id": f"toolu_{i:03d}", "name": "Bash", "input": {"command": f"echo {i}"}}]}})
        rows.append({"type": "user", "sessionId": SID, "toolUseResult": {"stdout": "x" * 1000},
                     "message": {"role": "user", "content": [
                         {"type": "tool_result", "tool_use_id": f"toolu_{i:03d}", "content": "x" * 1000}]}})
    rows.append({"type": "user", "sessionId": SID, "message": {"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "data": "A" * 500}},
        {"type": "text", "text": "用户发了张图并说：就按这个来"}]}})
    return rows


class SlimTest(unittest.TestCase):
    def test_keeps_recent_clears_old_and_preserves_text(self):
        rows, st = rescue.slim(_rows(8), keep=3)
        results = [b for d in rows if d["type"] == "user" and isinstance(d["message"]["content"], list)
                   for b in d["message"]["content"] if b.get("type") == "tool_result"]
        self.assertEqual(st["tool_results"], 8)
        self.assertEqual(st["cleared"], 5)
        self.assertEqual([r["content"] == rescue.PLACEHOLDER for r in results], [True] * 5 + [False] * 3)
        # 配对块一个不少，tool_use_id 原样
        self.assertEqual([r["tool_use_id"] for r in results], [f"toolu_{i:03d}" for i in range(8)])
        texts = [b["text"] for d in rows if d["type"] == "assistant" for b in d["message"]["content"] if b.get("type") == "text"]
        self.assertEqual(texts, [f"助手第 {i} 轮结论" for i in range(8)])
        self.assertEqual(rows[1]["message"]["content"], "用户原话：把线路状态修好")
        self.assertEqual(st["images"], 1)
        self.assertEqual(rows[-1]["message"]["content"][0], {"type": "text", "text": "[image cleared]"})
        self.assertEqual(rows[-1]["message"]["content"][1]["text"], "用户发了张图并说：就按这个来")
        self.assertLess(st["chars_after"], st["chars_before"] * 0.6)  # 8 条里清 5 条（每条 tool_result + toolUseResult 各 1000 字）

    def test_keep_zero_clears_everything(self):
        _, st = rescue.slim(_rows(4), keep=0)
        self.assertEqual(st["cleared"], 4)


class CliTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.claude = Path(self.tmp.name) / "claude"
        self.proj = self.claude / "projects" / "-tmp-proj"
        self.proj.mkdir(parents=True)
        self.src = self.proj / f"{SID}.jsonl"
        self.src.write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in _rows(6)) + "{半行", encoding="utf-8")
        self.before = (self.src.stat().st_size, self.src.stat().st_mtime_ns, self.src.read_bytes())

    def tearDown(self):
        self.tmp.cleanup()

    def test_writes_new_copy_readonly_on_source(self):
        rc = rescue.main([SID, "--keep", "2", "--claude-dir", str(self.claude), "--write"])
        self.assertEqual(rc, 0)
        self.assertEqual((self.src.stat().st_size, self.src.stat().st_mtime_ns, self.src.read_bytes()), self.before)
        copies = [p for p in self.proj.glob("*.jsonl") if p != self.src]
        self.assertEqual(len(copies), 1)
        dst = copies[0]
        self.assertEqual(stat.S_IMODE(dst.stat().st_mode), 0o600)
        new_id = dst.stem
        self.assertNotEqual(new_id, SID)
        body = dst.read_text(encoding="utf-8")
        self.assertNotIn(SID, body)
        self.assertIn(f'"sessionId": "{new_id}"', body)
        self.assertEqual(body.count(rescue.PLACEHOLDER), 4 * 2)  # 4 条被清 × (tool_result + toolUseResult)
        self.assertIn("用户原话：把线路状态修好", body)
        self.assertEqual(dst.stat().st_mtime_ns, self.src.stat().st_mtime_ns)  # 不顶掉菜单栏按 mtime 退回的定位

    def test_resumed_copy_becomes_the_newest_file_by_design(self):
        # 写入时副本沿用源 mtime（不顶掉别的运行中会话的定位）；被 --resume 之后副本就是这条会话的活本，
        # mtime 正常前进、源文件停在旧值——此后菜单栏按 mtime 退回时挑到副本是**预期行为**（源会话已卡死/退出）。
        rescue.main([SID, "--claude-dir", str(self.claude), "--write"])
        dst = next(p for p in self.proj.glob("*.jsonl") if p != self.src)
        self.assertEqual(dst.stat().st_mtime_ns, self.src.stat().st_mtime_ns)
        with dst.open("a", encoding="utf-8") as fh:  # 模拟 claude --resume 后追加一条记录
            fh.write(json.dumps({"type": "user", "sessionId": dst.stem, "message": {"role": "user", "content": "续开后的新话"}}) + "\n")
        os.utime(dst, ns=(self.src.stat().st_atime_ns, self.src.stat().st_mtime_ns + 1_000_000_000))
        newest = max(self.proj.glob("*.jsonl"), key=lambda p: p.stat().st_mtime_ns)
        self.assertEqual(newest, dst)

    def test_default_is_preview_and_writes_nothing(self):
        rescue.main([str(self.src)])
        self.assertEqual([p.name for p in self.proj.glob("*.jsonl")], [self.src.name])

    def test_refuses_existing_target(self):
        import uuid as _uuid
        fixed = "99999999-9999-9999-9999-999999999999"
        (self.proj / f"{fixed}.jsonl").write_text("占位", encoding="utf-8")
        real = rescue.uuid.uuid4
        rescue.uuid.uuid4 = lambda: _uuid.UUID(fixed)
        try:
            with self.assertRaises(FileExistsError):
                rescue.main([SID, "--claude-dir", str(self.claude), "--write"])
        finally:
            rescue.uuid.uuid4 = real
        self.assertEqual((self.proj / f"{fixed}.jsonl").read_text(encoding="utf-8"), "占位")

    def test_unknown_session_dies(self):
        with self.assertRaises(SystemExit):
            rescue.main(["no-such-session", "--claude-dir", str(self.claude)])


if __name__ == "__main__":
    unittest.main()
