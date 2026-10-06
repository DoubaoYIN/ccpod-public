"""Exercise the real shell entry point using only isolated project-local state."""
import concurrent.futures
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
COMMON = ROOT / "scripts/lib/common.sh"


class SessionRegistryTests(unittest.TestCase):
    def setUp(self):
        fixtures = ROOT / "tmp/session-registry-tests"
        fixtures.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=fixtures)
        self.addCleanup(self.temp.cleanup)
        self.state = Path(self.temp.name)
        self.counter = self.state / "ccpod-session-counter"
        self.backup = self.state / "ccpod-session-counter.bak"
        self.registry = self.state / "ccpod-sessions.json"

    def register(self, pid=1001, reuse="", ok=True, inherited="220"):
        # 默认带一个「继承来的」CCPOD_SESSION_NUM：真实环境里它会顺着子进程 / `open -a` 泄漏，
        # 注册逻辑必须无视它，只认显式的 CCPOD_REUSE_NUM。
        env = dict(os.environ, CCPOD_CLAUDE_DIR=str(self.state),
                   CCPOD_SESSION_NUM=inherited, CCPOD_REUSE_NUM=reuse)
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; register_session "$2" fixture test /fixture terminal',
             "fixture", str(COMMON), str(pid)], env=env, text=True, capture_output=True,
            timeout=20,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            return int(result.stdout.strip())
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        return result

    def test_fresh_and_existing_counter(self):
        self.assertEqual(self.register(), 1)
        self.counter.write_text("41")
        self.assertEqual(self.register(), 42)
        self.assertEqual(self.counter.read_text(), "42")
        self.assertEqual(self.backup.read_text(), "42")

    def test_corrupt_primary_recovers_latest_backup(self):
        self.counter.write_text("41")
        self.assertEqual(self.register(), 42)
        self.counter.write_text("broken")
        self.assertEqual(self.register(1002), 43)

    def test_missing_primary_recovers_backup(self):
        self.backup.write_text("80")
        self.assertEqual(self.register(), 81)

    def test_partial_commit_uses_higher_reserved_number(self):
        self.counter.write_text("41")
        self.backup.write_text("42")
        self.assertEqual(self.register(), 43)

    def test_corrupt_without_backup_fails_without_rewriting(self):
        for raw in (b"broken", b"", b"-1", b"\xff", b"999999999999999999999"):
            with self.subTest(raw=raw):
                self.counter.write_bytes(raw)
                self.registry.write_text("[]")
                result = self.register(ok=False)
                self.assertIn("拒绝从 1 重置", result.stderr)
                self.assertEqual(self.counter.read_bytes(), raw)
                self.assertEqual(self.registry.read_text(), "[]")
                self.assertFalse(self.backup.exists())

    def test_both_missing_with_history_refuses_reset(self):
        self.registry.write_text('[{"pid":1000,"num":42}]')
        self.register(ok=False)
        self.assertFalse(self.counter.exists())

    def test_valid_primary_repairs_bad_backup(self):
        self.counter.write_text("41")
        self.backup.write_text("bad")
        self.assertEqual(self.register(), 42)
        self.assertEqual(self.backup.read_text(), "42")

    def test_existing_registry_numbers_raise_floor(self):
        self.counter.write_text("1")
        self.registry.write_text('[{"pid":1000,"num":42}]')
        self.assertEqual(self.register(), 43)

    def test_reuse_preserves_high_water(self):
        self.counter.write_text("41")
        self.assertEqual(self.register(reuse="20"), 20)
        self.assertEqual(self.counter.read_text(), "41")
        self.assertEqual(self.register(1002), 42)
        self.assertEqual(self.register(1003, reuse="80"), 80)
        self.assertEqual(self.register(1004), 81)

    def test_inherited_session_num_is_not_a_reuse_request(self):
        # 2026-10-05 实测撞号：#220 会话里 `open -a Ghostty`，新 Ghostty 继承了 CCPOD_SESSION_NUM=220，
        # 在里面开 ccgo 也登记成 #220。继承来的号必须被无视，照常分配新号。
        self.counter.write_text("230")
        self.registry.write_text('[{"pid":1000,"num":220}]')
        self.assertEqual(self.register(inherited="220"), 231)
        nums = sorted(e["num"] for e in json.loads(self.registry.read_text()))
        self.assertEqual(nums, [220, 231])

    def test_explicit_reuse_wins_over_inherited(self):
        self.counter.write_text("230")
        self.assertEqual(self.register(reuse="205", inherited="220"), 205)
        self.assertEqual(self.counter.read_text(), "230")

    def test_bad_reuse_and_overflow_preserve_files(self):
        self.counter.write_text(str(2**63 - 1))
        for reuse in ("", "0", "-3", "garbage", str(2**63)):
            with self.subTest(reuse=reuse):
                self.register(reuse=reuse, ok=False)
                self.assertEqual(self.counter.read_text(), str(2**63 - 1))
                self.assertFalse(self.backup.exists())

    def test_corrupt_registry_preserved(self):
        self.counter.write_text("41")
        for raw in ("broken", "{}", '[{"num":true}]'):
            self.registry.write_text(raw)
            self.register(ok=False)
            self.assertEqual(self.registry.read_text(), raw)
            self.assertEqual(self.counter.read_text(), "41")

    def test_unwritable_backup_does_not_consume_number(self):
        self.counter.write_text("41")
        self.backup.mkdir()
        self.register(ok=False)
        self.assertEqual(self.counter.read_text(), "41")
        self.assertFalse(self.registry.exists())

    def test_failed_registry_write_reserves_number(self):
        # Inject failure only at the final registry rename in the child Python.
        self.counter.write_text("41")
        self.registry.write_text("[]")
        (self.state / "sitecustomize.py").write_text(
            "import os\noriginal = os.replace\n"
            "def replace(src, dst):\n"
            "    if str(dst).endswith('ccpod-sessions.json'):\n"
            "        raise OSError('injected registry rename failure')\n"
            "    return original(src, dst)\n"
            "os.replace = replace\n"
        )
        env = dict(os.environ, CCPOD_CLAUDE_DIR=str(self.state), CCPOD_REUSE_NUM="",
                   PYTHONPATH=str(self.state), PYTHONDONTWRITEBYTECODE="1")
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; register_session 1001 fixture test /fixture terminal',
             "fixture", str(COMMON)], env=env, capture_output=True, timeout=20,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"injected registry rename failure", result.stderr)
        self.assertEqual(self.registry.read_text(), "[]")
        self.assertEqual(self.counter.read_text(), "42")
        self.assertEqual(self.backup.read_text(), "42")
        self.assertEqual(self.register(), 43)

    def test_concurrent_allocations_are_unique(self):
        self.counter.write_text("41")
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            numbers = list(pool.map(self.register, range(2000, 2024)))
        self.assertEqual(sorted(numbers), list(range(42, 66)))
        self.assertEqual(len(json.loads(self.registry.read_text())), 24)
        self.assertEqual(self.counter.read_text(), "65")


if __name__ == "__main__":
    unittest.main()
