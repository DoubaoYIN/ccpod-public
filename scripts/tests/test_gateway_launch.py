"""Run CLI launchers against a recording Claude stub and isolated fixture HOME.

No real Claude process, Keychain lookup, gateway request or paid inference runs.
"""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"


class GatewayLaunchTests(unittest.TestCase):
    def setUp(self):
        fixtures = ROOT / "tmp/gateway-launch-tests"
        fixtures.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(dir=fixtures)
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.state = self.home / ".claude"
        self.providers = self.state / "providers"
        self.providers.mkdir(parents=True)
        self.project = self.home / "project"
        self.project.mkdir()
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.capture = self.home / "launch.json"
        self.env = {
            "HOME": str(self.home), "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "CCPOD_CLAUDE_DIR": str(self.state), "TEST_CAPTURE": str(self.capture),
            "PYTHONDONTWRITEBYTECODE": "1", "TERM_PROGRAM": "fixture",
        }
        stub = self.bin / "claude"
        stub.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
from pathlib import Path
config = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude")))
settings = {}
for name in ("settings.json", "settings.local.json"):
    path = config / name
    if path.exists():
        settings[name] = json.loads(path.read_text())
data = {"args": sys.argv[1:], "config": str(config), "settings": settings,
        "env": {k: v for k, v in os.environ.items() if k in (
            "ANTHROPIC_MODEL", "ANTHROPIC_BASE_URL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
            "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
            "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CCR_ROUTE")},
        "auth_present": bool(os.environ.get("ANTHROPIC_AUTH_TOKEN")),
        "provider": os.environ.get("CCPOD_PROVIDER")}
Path(os.environ["TEST_CAPTURE"]).write_text(json.dumps(data))
''')
        stub.chmod(0o700)
        self.main_settings = {
            "apiKeyHelper": "fixture-helper-do-not-execute",
            "availableModels": ["glm/old"], "model": "glm/old",
            "env": {"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456",
                    "ANTHROPIC_MODEL": "glm/old",
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm/old",
                    "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm/old",
                    "ANTHROPIC_SMALL_FAST_MODEL": "glm/old",
                    "CCR_ROUTE": "old", "UNRELATED_SETTING": "keep"},
        }
        self.write_json(self.state / "settings.json", self.main_settings)
        self.write_json(self.home / ".claude.json", {
            "oauthAccount": {"emailAddress": "fixture@example.invalid"},
            "hasCompletedOnboarding": True,
        })
        self.gateway = "gw-dragoncode-12345678"
        self.model = "dragoncode/claude-opus-5-5"
        self.add_provider(self.gateway, source="gateway", display_name="Dragon Code",
                          gateway_provider="dragoncode", gateway_model="claude-opus-5-5",
                          gateway_models=["claude-opus-5-5", "claude-sonnet-4-6"],
                          env={"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456",
                               "ANTHROPIC_MODEL": self.model},
                          claude_args=["--model", self.model])

    @staticmethod
    def write_json(path, data):
        path.write_text(json.dumps(data, ensure_ascii=False))

    def add_provider(self, name, **data):
        self.write_json(self.providers / f"{name}.json", data)

    def run_cli(self, name, *args, stdin=None, extra_env=None, ok=True):
        result = subprocess.run(
            ["bash", str(SCRIPTS / f"{name}.sh"), *args], input=stdin,
            env=dict(self.env, **(extra_env or {})), cwd=self.project,
            text=True, capture_output=True, timeout=20,
        )
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def launch(self):
        self.assertTrue(self.capture.is_file(), "recording Claude stub did not run")
        return json.loads(self.capture.read_text())

    def default_provider(self):
        result = subprocess.run(
            ["bash", "-c", 'source "$1"; get_default_provider "$2"', "fixture",
             str(SCRIPTS / "lib/common.sh"), str(self.project)],
            env=self.env, text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def add_bailian(self):
        name = "gw-bailian-12345678"
        self.add_provider(name, source="gateway", display_name="百炼", gateway_provider="bailian",
                          gateway_model="qwen3.8-max", gateway_models=["qwen3.8-max"],
                          env={"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456",
                               "ANTHROPIC_MODEL": "bailian/qwen3.8-max"},
                          claude_args=["--model", "bailian/qwen3.8-max"])
        return name

    def test_visible_catalog_and_human_labels(self):
        self.add_provider("old-direct", env={"ANTHROPIC_BASE_URL": "https://old.invalid"})
        self.add_provider("official", env={})
        self.add_provider("imported", source="imported", display_name="已导入线路")
        self.add_provider("manual", source="manual", display_name="手动线路")
        self.add_provider("ccr", env={"ANTHROPIC_BASE_URL": "http://localhost:3456"})
        self.add_provider("ccr-bailian", env={"ANTHROPIC_BASE_URL": "https://remote.invalid"})
        self.add_provider("ccr-dear", env={"ANTHROPIC_BASE_URL": "http://[::1]:3456"})
        result = self.run_cli("ccuse", "--list")
        for expected in ("Dragon Code", "已导入线路", "手动线路"):
            self.assertIn(expected, result.stdout)
        for hidden in ("old-direct", "official", "[ccr]", "[ccr-bailian]", "[ccr-dear]"):
            self.assertNotIn(hidden, result.stdout)

    def test_legacy_catalog_is_fallback_only_and_requires_local_gateway(self):
        (self.providers / f"{self.gateway}.json").unlink()
        self.add_provider("ccr", env={"ANTHROPIC_BASE_URL": "http://localhost:3456"})
        self.add_provider("ccr-bailian", env={"ANTHROPIC_BASE_URL": "https://remote.invalid"})
        self.add_provider("ccr-dear", env={"ANTHROPIC_BASE_URL": "http://[::1]:3456"})
        result = self.run_cli("ccuse", "--list")
        self.assertIn("网关默认模型", result.stdout)
        self.assertIn("每日 300 次", result.stdout)
        self.assertNotIn("[ccr-bailian]", result.stdout)

    def test_model_aliases_never_create_extra_catalog_entries(self):
        for model in ("opus", "sonnet", "haiku"):
            self.add_provider(f"gw-old-{model}", source="gateway-alias", gateway_provider="dragoncode",
                              pipeline_id=self.gateway, display_name=f"Dragon Code {model}")
        result = self.run_cli("ccuse", "--list")
        self.assertEqual(result.stdout.count("Dragon Code"), 1)
        self.assertIn(f"[{self.gateway}]", result.stdout)
        self.assertNotIn("gw-old-", result.stdout)

    def test_unmigrated_model_entries_are_hidden_when_canonical_exists(self):
        for model in ("opus", "sonnet"):
            self.add_provider(f"gw-old-{model}", source="gateway", gateway_provider="dragoncode",
                              gateway_model=model, display_name=f"Dragon Code {model}")
        (self.state / "current-provider").write_text("gw-old-sonnet")
        result = self.run_cli("ccuse", "--list")
        self.assertEqual(result.stdout.count("Dragon Code"), 1)
        self.assertNotIn("gw-old-", result.stdout)
        self.assertEqual(self.default_provider(), self.gateway)

    def test_unmigrated_model_entries_do_not_hide_legacy_fallbacks(self):
        (self.providers / f"{self.gateway}.json").unlink()
        self.add_provider("gw-old-model", source="gateway", gateway_provider="dragoncode",
                          gateway_model="claude-opus-5-5", display_name="Old Model")
        self.add_provider("ccr", env={"ANTHROPIC_BASE_URL": "http://localhost:3456"})
        result = self.run_cli("ccuse", "--list")
        self.assertIn("[ccr]", result.stdout)
        self.assertIn("[gw-old-model]", result.stdout)

    def test_alias_preferences_resolve_without_rewriting_record_files(self):
        for fields in ({"pipeline_id": self.gateway}, {"gateway_provider": "dragoncode"}):
            with self.subTest(fields=fields):
                self.add_provider("old-model", source="gateway-alias", **fields)
                for path, value in (
                    (self.state / "project-providers.json", json.dumps({str(self.project): "old-model"})),
                    (self.state / "current-provider", "old-model"),
                ):
                    path.write_text(value)
                self.assertEqual(self.default_provider(), self.gateway)
                self.assertEqual((self.state / "project-providers.json").read_text(),
                                 json.dumps({str(self.project): "old-model"}))
                self.assertEqual((self.state / "current-provider").read_text(), "old-model")

    def test_legacy_preferences_resolve_to_matching_pipeline(self):
        bailian = self.add_bailian()
        # CCR 的默认模型厂商来自主配置，不能把所有 ccr 偏好都改成同一个厂商。
        self.main_settings["env"]["ANTHROPIC_MODEL"] = "bailian/qwen3.8-max"
        self.write_json(self.state / "settings.json", self.main_settings)
        for old, target in (("ccr-dear", self.gateway), ("ccr-bailian", bailian), ("ccr", bailian)):
            with self.subTest(old=old):
                (self.state / "current-provider").write_text(old)
                self.assertEqual(self.default_provider(), target)
                self.assertEqual((self.state / "current-provider").read_text(), old)

    def test_existing_preferences_win_then_dragoncode_then_first_pipeline(self):
        bailian = self.add_bailian()
        self.assertEqual(self.default_provider(), self.gateway)
        (self.state / "current-provider").write_text(bailian)
        self.assertEqual(self.default_provider(), bailian)
        self.add_provider("manual", source="manual", display_name="手动线路")
        self.write_json(self.state / "project-providers.json", {str(self.project): "manual"})
        self.assertEqual(self.default_provider(), "manual")
        (self.state / "project-providers.json").unlink()
        (self.state / "current-provider").unlink()
        (self.providers / f"{self.gateway}.json").unlink()
        self.assertEqual(self.default_provider(), bailian)

    def test_alias_launch_preserves_original_model_auth_and_id(self):
        alias = "gw-old-sonnet"
        alias_model = "dragoncode/claude-sonnet-4-6"
        self.add_provider(alias, source="gateway-alias", gateway_provider="dragoncode",
                          pipeline_id=self.gateway, display_name="Old Sonnet",
                          env={"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456",
                               "ANTHROPIC_MODEL": alias_model, "ANTHROPIC_AUTH_TOKEN": "fixture-limited-auth"},
                          claude_args=["--model", alias_model])
        result = self.run_cli("ccgo", alias, str(self.project))
        data = self.launch()
        self.assertEqual(data["provider"], alias)
        self.assertEqual(data["args"], ["--model", alias_model])
        self.assertEqual(data["env"]["ANTHROPIC_MODEL"], alias_model)
        self.assertTrue(data["auth_present"])
        self.assertNotIn("apiKeyHelper", data["settings"]["settings.json"])
        self.assertIn("Dragon Code", result.stdout)
        self.assertNotIn("Old Sonnet", result.stdout)

    def test_keyless_alias_still_gets_isolated_model_settings(self):
        alias_model = "dragoncode/claude-sonnet-4-6"
        self.add_provider("gw-old-keyless", source="gateway-alias", pipeline_id=self.gateway,
                          env={"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456", "ANTHROPIC_MODEL": alias_model},
                          claude_args=["--model", alias_model])
        self.run_cli("ccgo", "gw-old-keyless", str(self.project))
        data = self.launch()
        self.assertEqual(Path(data["config"]).name, "gw-old-keyless")
        self.assertEqual(data["args"], ["--model", alias_model])
        self.assertEqual(data["settings"]["settings.json"]["env"], {"UNRELATED_SETTING": "keep"})
        self.assertEqual(data["settings"]["settings.json"]["apiKeyHelper"], "fixture-helper-do-not-execute")

    def test_keyless_gateway_isolates_settings_and_passes_model(self):
        self.write_json(self.state / "settings.local.json", self.main_settings)
        before = (self.state / "settings.json").read_bytes()
        result = self.run_cli("ccgo", self.gateway, str(self.project), extra_env={
            "ANTHROPIC_MODEL": "inherited/old", "ANTHROPIC_DEFAULT_HAIKU_MODEL": "inherited/old",
            "ANTHROPIC_SMALL_FAST_MODEL": "inherited/old", "CCR_ROUTE": "inherited",
        })
        data = self.launch()
        self.assertEqual(data["args"], ["--model", self.model])
        # 继承来的别家档位被换掉；五个档位全部钉在本管线（没有 haiku/快速版 → 主模型）
        self.assertEqual(data["env"], {"ANTHROPIC_MODEL": self.model,
                                       "ANTHROPIC_BASE_URL": "http://127.0.0.1:3456",
                                       "ANTHROPIC_DEFAULT_OPUS_MODEL": self.model,
                                       "ANTHROPIC_DEFAULT_FABLE_MODEL": self.model,
                                       "ANTHROPIC_DEFAULT_SONNET_MODEL": "dragoncode/claude-sonnet-4-6",
                                       "ANTHROPIC_DEFAULT_HAIKU_MODEL": self.model,
                                       "ANTHROPIC_SMALL_FAST_MODEL": self.model})
        self.assertFalse(data["auth_present"])
        self.assertIn("Dragon Code", result.stdout)
        config = Path(data["config"])
        self.assertEqual(config, self.state / "provider-configs" / self.gateway)
        self.assertEqual(stat.S_IMODE(config.stat().st_mode), 0o700)
        for filename, copied in data["settings"].items():
            self.assertEqual(copied["apiKeyHelper"], "fixture-helper-do-not-execute")
            self.assertEqual(copied["env"], {"UNRELATED_SETTING": "keep"})
            self.assertNotIn("model", copied)
            self.assertNotIn("availableModels", copied)
            self.assertEqual(stat.S_IMODE((config / filename).stat().st_mode), 0o600)
        self.assertEqual((self.state / "settings.json").read_bytes(), before)
        self.assertEqual(json.loads((config / ".claude.json").read_text()), {"hasCompletedOnboarding": True})

    def test_ccstart_rejects_stale_default_and_passes_model(self):
        self.add_provider("official", env={})
        self.write_json(self.state / "project-providers.json", {str(self.project): "official"})
        (self.state / "current-provider").write_text("missing")
        result = self.run_cli("ccstart", stdin=f"{self.project}\n\n")
        data = self.launch()
        self.assertEqual(data["provider"], self.gateway)
        self.assertEqual(data["args"], ["--model", self.model])
        self.assertIn("默认: Dragon Code", result.stderr)
        self.assertNotIn("official", result.stderr)

    def test_ccstart_honors_visible_project_preference(self):
        self.add_provider("ccr", env={"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456"})
        self.write_json(self.state / "project-providers.json", {str(self.project): self.gateway})
        self.run_cli("ccstart", stdin=f"{self.project}\n\n")
        self.assertEqual(self.launch()["provider"], self.gateway)

    def test_gateway_default_preserves_profile_model_mapping(self):
        (self.providers / f"{self.gateway}.json").unlink()
        self.add_provider("ccr", env={"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456"})
        self.run_cli("ccstart", stdin=f"{self.project}\n\n")
        data = self.launch()
        self.assertEqual(data["provider"], "ccr")
        self.assertEqual(data["args"], [])
        copied = data["settings"]["settings.json"]
        self.assertEqual(copied["env"]["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "glm/old")
        self.assertEqual(copied["apiKeyHelper"], "fixture-helper-do-not-execute")

    def test_hidden_direct_stays_explicitly_launchable_and_isolated(self):
        self.add_provider("old-direct", env={"ANTHROPIC_BASE_URL": "https://old.invalid",
                                              "ANTHROPIC_AUTH_TOKEN": "fixture-auth-value"})
        self.run_cli("ccgo", "old-direct", str(self.project))
        data = self.launch()
        self.assertEqual(data["env"]["ANTHROPIC_BASE_URL"], "https://old.invalid")
        self.assertTrue(data["auth_present"])
        copied = data["settings"]["settings.json"]
        self.assertNotIn("apiKeyHelper", copied)
        self.assertNotIn("model", copied)
        self.assertEqual(copied["env"], {"UNRELATED_SETTING": "keep"})

    def test_resume_and_managed_config_switch(self):
        old_config = self.state / "provider-configs" / "old"
        old_config.mkdir(parents=True)
        self.run_cli("ccgo", self.gateway, str(self.project), "--resume", "fixture-session-id",
                     extra_env={"CLAUDE_CONFIG_DIR": str(old_config)})
        data = self.launch()
        self.assertEqual(data["args"], ["--model", self.model, "--resume", "fixture-session-id"])
        self.assertEqual(Path(data["config"]).name, self.gateway)

    def test_bad_model_args_fail_before_claude(self):
        self.add_provider("bad", source="gateway", env={"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456"},
                          claude_args=["--model\ninvalid"])
        result = self.run_cli("ccgo", "bad", str(self.project), ok=False)
        self.assertIn("取线路 claude 参数失败", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_failed_auth_resolution_cannot_fall_back_to_helper(self):
        self.add_provider("bad-auth", source="imported", env={"ANTHROPIC_AUTH_TOKEN": {"$exec": "false"}})
        result = self.run_cli("ccgo", "bad-auth", str(self.project), ok=False)
        self.assertIn("拒绝以无 key 状态启动", result.stderr)
        self.assertFalse(self.capture.exists())

    def test_empty_catalog_fails_with_actionable_message(self):
        (self.providers / f"{self.gateway}.json").unlink()
        self.add_provider("official", env={})
        result = self.run_cli("ccstart", stdin=f"{self.project}\n", ok=False)
        self.assertIn("没有可用线路；请先同步网关模型或导入线路", result.stderr)
        self.assertFalse(self.capture.exists())


    def test_alias_whose_model_left_pipeline_moves_to_pipeline_model(self):
        # 已下架的模型名打到网关会被静默转给 profile 默认（别家），必须启动前就换掉并说出来
        gone = "dragoncode/claude-opus-5"
        self.add_provider("gw-old-gone", source="gateway-alias", pipeline_id=self.gateway,
                          env={"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456", "ANTHROPIC_MODEL": gone},
                          claude_args=["--model", gone])
        result = self.run_cli("ccgo", "gw-old-gone", str(self.project))
        data = self.launch()
        self.assertEqual(data["args"], ["--model", self.model])
        self.assertEqual(data["env"]["ANTHROPIC_MODEL"], self.model)
        self.assertIn(f"原模型 {gone} 已不在管线 dragoncode 里", result.stderr)

    def test_tiers_only_use_models_that_recently_passed(self):
        import sqlite3
        name = "gw-yescode-12345678"
        self.add_provider(name, source="gateway", display_name="YesCode", gateway_provider="yescode",
                          gateway_model="claude-opus-5-5",
                          gateway_models=["claude-fable-5", "claude-haiku-4-5", "claude-opus-5-5", "claude-sonnet-5"],
                          env={"ANTHROPIC_BASE_URL": "http://127.0.0.1:3456",
                               "ANTHROPIC_MODEL": "yescode/claude-opus-5-5"},
                          claude_args=["--model", "yescode/claude-opus-5-5"])
        db = self.home / "usage.sqlite"
        con = sqlite3.connect(db)
        con.execute("create table usage_events (created_at text, logical_model text, status_code int)")
        con.executemany("insert into usage_events values (strftime('%Y-%m-%dT%H:%M:%fZ','now'), ?, ?)", [
            ("yescode/claude-opus-5-5", 200), ("yescode/claude-sonnet-5", 403),
            ("yescode/claude-haiku-4-5", 403), ("other/claude-sonnet-5", 200)])
        con.commit()
        con.close()
        self.run_cli("ccgo", name, str(self.project), extra_env={"CCPOD_CCR_USAGE_DB": str(db)})
        env = self.launch()["env"]
        for key in ("ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                    "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL"):
            self.assertEqual(env[key], "yescode/claude-opus-5-5", key)


class LineModelTierTests(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, str(SCRIPTS / "lib"))
        import line_models
        self.lm = line_models

    def test_fast_tier_prefers_main_model_family(self):
        models = ["deepseek-v4.1-flash", "glm-5.3", "qwen3.6-flash", "qwen3.8-flash", "qwen3.8-max"]
        tiers = self.lm.tiers(models, "qwen3.8-max")
        self.assertEqual(tiers["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "qwen3.8-flash")
        self.assertEqual(tiers["ANTHROPIC_DEFAULT_OPUS_MODEL"], "qwen3.8-max")

    def test_claude_tiers_pick_newest_of_each_family(self):
        models = ["claude-fable-5", "claude-fable-5-1", "claude-haiku-4-5-20251001",
                  "claude-opus-4-8", "claude-opus-5-5", "claude-sonnet-5"]
        tiers = self.lm.tiers(models, "claude-opus-5-5")
        self.assertEqual(tiers["ANTHROPIC_DEFAULT_OPUS_MODEL"], "claude-opus-5-5")
        self.assertEqual(tiers["ANTHROPIC_DEFAULT_FABLE_MODEL"], "claude-fable-5-1")
        self.assertEqual(tiers["ANTHROPIC_DEFAULT_HAIKU_MODEL"], "claude-haiku-4-5-20251001")

    def test_non_gateway_lines_are_left_alone(self):
        self.assertIsNone(self.lm.plan({"env": {"ANTHROPIC_MODEL": "x"}}, "/nonexistent"))


if __name__ == "__main__":
    unittest.main()
