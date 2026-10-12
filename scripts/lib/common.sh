#!/usr/bin/env bash
# common.sh — shared variables and helpers for ccpod scripts
#
# This file is sourced by ccuse / ccstart / ccnow.
# Do not execute it directly.

# ─── Paths ────────────────────────────────────────────────
: "${CCPOD_CLAUDE_DIR:=$HOME/.claude}"
CCPOD_PROVIDERS_DIR="$CCPOD_CLAUDE_DIR/providers"
CCPOD_CURRENT_FILE="$CCPOD_CLAUDE_DIR/current-provider"
CCPOD_STATUS_FILE="$CCPOD_CLAUDE_DIR/ccpod-status.txt"
CCPOD_SETTINGS_FILE="$CCPOD_CLAUDE_DIR/settings.json"
CCPOD_PROJECT_MAP="$CCPOD_CLAUDE_DIR/project-providers.json"
CCPOD_SESSIONS_FILE="$CCPOD_CLAUDE_DIR/ccpod-sessions.json"
CCPOD_PROJECTS_FILE="$CCPOD_CLAUDE_DIR/ccpod-projects.json"
CCPOD_COUNTER_FILE="$CCPOD_CLAUDE_DIR/ccpod-session-counter"

# ─── Pre-formatted badge for statusline tools ─────────────
# Writes "<emoji> <name>" to CCPOD_STATUS_FILE. Any statusline can
# inline it via `cat ~/.claude/ccpod-status.txt`.
ccpod_format_badge() {
  local label emoji
  label="$(get_provider_display_name "$1")"
  case "$1" in
    official|AiGoCC|aigocc|AiGoCode|aigocode) emoji='🟢' ;;
    easyclaude) emoji='🔵' ;;
    minimax) emoji='🟠' ;;
    glm) emoji='🟣' ;;
    volcengine) emoji='🔴' ;;
    aliyun) emoji='🟤' ;;
    deepseek) emoji='🔷' ;;
    kimi) emoji='🟡' ;;
    *) emoji='⚪' ;;
  esac
  printf '%s %s' "$emoji" "$label"
}

is_valid_provider_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." ]]
}

# 同一份目录判据供列表、默认选择和配置隔离使用。旧直连仍能显式 ccgo <id>，
# 但只有用户导入/创建的线路和本地网关线路进入默认列表。
provider_catalog() {
  require_cmd python3
  python3 - "$CCPOD_CLAUDE_DIR" "$1" "${2:-}" <<'PYEOF'
import json, re, sys
from pathlib import Path
from urllib.parse import urlsplit

root, mode, query = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
legacy = {
    "ccr": "网关默认模型",
    "ccr-bailian": "百炼 Qwen3.8 Max",
    "ccr-dear": "Dragon Code Opus 5.5（每日 300 次）",
}

def load(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}

def gateway(name, data):
    # 旧的按模型拆分 ID 只用于显式恢复；仍需使用网关隔离配置。
    if data.get("source") in ("gateway", "gateway-alias"):
        return True
    env = data.get("env") or {}
    base = env.get("ANTHROPIC_BASE_URL") if isinstance(env, dict) else None
    try:
        url = urlsplit(base) if isinstance(base, str) else None
        local = url and url.scheme in ("http", "https") and url.hostname in ("localhost", "127.0.0.1", "::1")
    except ValueError:
        local = False
    return name in legacy and bool(local)

providers = {}
for path in sorted((root / "providers").glob("*.json")):
    name = path.stem
    if name in (".", "..") or name.endswith(".example") or not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        continue
    providers[name] = load(path)
canonical = {name: data for name, data in providers.items()
             if data.get("source") == "gateway" and isinstance(data.get("gateway_models"), list)}
by_provider = {}
for name, data in canonical.items():
    provider = data.get("gateway_provider")
    if isinstance(provider, str) and provider:
        by_provider.setdefault(provider, name)
visible = {name: data for name, data in providers.items()
           if not (canonical and name in legacy)
           and (data.get("source") in ("imported", "manual") or name in canonical
                or (not canonical and data.get("source") == "gateway")
                or (not canonical and name in legacy and gateway(name, data)))}

def pipeline(name):
    if not isinstance(name, str):
        return None
    if name in visible:
        return name
    data = providers.get(name, {})
    target = data.get("pipeline_id")
    if isinstance(target, str) and target in canonical:
        return target
    provider = data.get("gateway_provider")
    if not isinstance(provider, str) or not provider:
        provider = {"ccr-bailian": "bailian", "ccr-dear": "dragoncode"}.get(name)
        if name == "ccr":
            env = load(root / "settings.json").get("env") or {}
            model = env.get("ANTHROPIC_MODEL") if isinstance(env, dict) else None
            if isinstance(model, str) and "/" in model:
                provider = model.split("/", 1)[0]
    return by_provider.get(provider) if isinstance(provider, str) else None

if mode == "list":
    print("\n".join(visible), end="\n" if visible else "")
elif mode == "display":
    data = providers.get(query, {})
    old_gateway = data.get("source") == "gateway-alias" or (data.get("source") == "gateway" and query not in canonical)
    target = pipeline(query) if old_gateway else None
    label = canonical.get(target, data).get("display_name")
    if not isinstance(label, str) or not label.strip():
        label = legacy.get(query, query)
    # display_name 是展示数据，不允许终端转义或换行改变标题/列表。
    print("".join(c if c.isprintable() else " " for c in label).strip())
elif mode == "gateway":
    sys.exit(0 if gateway(query, providers.get(query, {})) else 1)
elif mode == "default":
    project = load(root / "project-providers.json").get(query)
    try:
        current = (root / "current-provider").read_text().strip()
    except OSError:
        current = None
    # 只解析旧偏好，不改写记录；用户确认启动后仍由原流程记住所选管线。
    candidates = [pipeline(project), pipeline(current), by_provider.get("dragoncode")]
    candidates += list(canonical)
    candidates += ["ccr-dear", "ccr"]
    candidates += list(visible)
    for name in candidates:
        if isinstance(name, str) and name in visible:
            print(name)
            break
    else:
        raise SystemExit("没有可用线路；请先同步网关模型或导入线路")
else:
    raise SystemExit("unknown provider catalog operation")
PYEOF
}

get_provider_display_name() { provider_catalog display "$1"; }
available_provider_names() { provider_catalog list; }
get_default_provider() { provider_catalog default "$1"; }
provider_is_gateway() { provider_catalog gateway "$1"; }

# ─── Provider prefix resolver ─────────────────────────────
# "off" → "official", "easy" → "easyclaude". Exact match wins first.
# Errors out if the prefix is ambiguous.
resolve_provider() {
  local q="$1"
  is_valid_provider_name "$q" || die "provider 名称非法: '$q'"
  if [[ -f "$CCPOD_PROVIDERS_DIR/$q.json" ]]; then
    printf '%s' "$q"
    return 0
  fi
  local matches=()
  local f name
  for f in "$CCPOD_PROVIDERS_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    name="$(basename "$f" .json)"
    [[ "$name" == *.example ]] && continue
    is_valid_provider_name "$name" || continue
    if [[ "$name" == "$q"* ]]; then
      matches+=("$name")
    fi
  done
  case ${#matches[@]} in
    0) die "未知 provider: '$q' (运行 'ccuse --list' 查看可用)" ;;
    1) printf '%s' "${matches[0]}" ;;
    *) die "provider '$q' 不唯一，匹配到: ${matches[*]}" ;;
  esac
}

# ─── Fuzzy match against projects ─────────────────────────
# Searches: 1) manual entries in ccpod-projects.json
#           2) scan_dirs from ccpod-projects.json
#           3) CC's ~/.claude/projects/ (legacy)
# Returns the first match whose path contains $1 as a substring.
find_project_by_fragment() {
  local frag="$1"

  # Search ccpod-projects.json (manual + scan_dirs)
  if [[ -f "$CCPOD_PROJECTS_FILE" ]]; then
    require_cmd python3
    local result
    result="$(python3 - "$CCPOD_PROJECTS_FILE" "$frag" <<'PYEOF'
import json, os, sys, glob
path, frag = sys.argv[1], sys.argv[2]
try:
    cfg = json.load(open(path))
except Exception:
    sys.exit(1)
# manual entries first
for m in cfg.get("manual", []):
    p = os.path.expanduser(m["path"])
    if os.path.isdir(p) and frag in p:
        print(p, end="")
        sys.exit(0)
# then scan_dirs
for sd in cfg.get("scan_dirs", []):
    sd = os.path.expanduser(sd)
    if not os.path.isdir(sd):
        continue
    for entry in sorted(os.listdir(sd)):
        p = os.path.join(sd, entry)
        if not os.path.isdir(p):
            continue
        if frag not in p:
            continue
        if os.path.exists(os.path.join(p, "CLAUDE.md")) or os.path.exists(os.path.join(p, ".git")):
            print(p, end="")
            sys.exit(0)
sys.exit(1)
PYEOF
    )" && { printf '%s' "$result"; return 0; }
  fi

  # Fallback: CC's project dirs
  local d="$HOME/.claude/projects"
  [[ -d "$d" ]] || return 1
  local enc decoded
  for enc in $(ls -t1 "$d" 2>/dev/null); do
    decoded="$(echo "$enc" | sed 's|^-|/|; s|-|/|g')"
    if [[ -d "$decoded" && "$decoded" == *"$frag"* ]]; then
      printf '%s' "$decoded"
      return 0
    fi
  done
  return 1
}

# ─── Output helpers ───────────────────────────────────────
die() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

info() {
  printf '%s\n' "$*"
}

warn() {
  printf '⚠️  %s\n' "$*" >&2
}

# ─── Dependency check ─────────────────────────────────────
require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    if [[ -n "$hint" ]]; then
      die "缺少依赖: $cmd (安装: $hint)"
    else
      die "缺少依赖: $cmd"
    fi
  fi
}

# ─── Symlink-safe script directory resolution ─────────────
# Usage: SCRIPT_DIR="$(resolve_script_dir "${BASH_SOURCE[0]}")"
resolve_script_dir() {
  local src="$1"
  while [[ -L "$src" ]]; do
    local dir
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
}

# ─── Smart-default B: per-project provider memory ─────────
remember_project_provider() {
  local proj="$1"
  local prov="$2"
  require_cmd python3
  python3 - "$CCPOD_PROJECT_MAP" "$proj" "$prov" <<'PYEOF'
import json, os, sys
path, proj, prov = sys.argv[1:4]
data = {}
if os.path.exists(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
data[proj] = prov
os.makedirs(os.path.dirname(path), exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
PYEOF
}

get_project_provider() {
  local proj="$1"
  [[ -f "$CCPOD_PROJECT_MAP" ]] || return 1
  require_cmd python3
  python3 - "$CCPOD_PROJECT_MAP" "$proj" <<'PYEOF'
import json, sys
path, proj = sys.argv[1:3]
try:
    data = json.load(open(path))
except Exception:
    sys.exit(1)
if proj in data:
    print(data[proj])
else:
    sys.exit(1)
PYEOF
}

# ─── Terminal detection ──────────────────────────────────
detect_terminal() {
  case "${TERM_PROGRAM:-}" in
    ghostty)       printf 'ghostty' ;;
    Apple_Terminal) printf 'terminal' ;;
    iTerm.app)     printf 'iterm2' ;;
    *)             printf '%s' "${TERM_PROGRAM:-unknown}" ;;
  esac
}

# ─── Provider env injection ──────────────────────────────
# Reads provider JSON and outputs export/unset statements.
# Always unsets ANTHROPIC_* first to prevent leakage from prior sessions
# in the same shell (critical for one-click provider switch).
# Usage: eval "$(get_provider_env easyclaude)"
get_provider_env() {
  local name="$1" model_override="${2:-}"
  local prov="$CCPOD_PROVIDERS_DIR/${name}.json"
  [[ -f "$prov" ]] || die "未知 provider: $name"
  require_cmd python3
  python3 - "$prov" "$(dirname "${BASH_SOURCE[0]}")" "$CCPOD_PROVIDERS_DIR" "$model_override" <<'PYEOF'
import json, os, re, sys, shlex
data = json.load(open(sys.argv[1]))
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[2])
import line_models
# 启动时一次性的 --model（ccgo / 菜单栏「启动新会话」）：只改这次的副本，不写文件
if sys.argv[4]:
    data = line_models.apply_overrides(data, sys.argv[3], model=sys.argv[4])

def resolve_env_value(v):
    # {"$exec": "cmd"} → 取命令 stdout（如从钥匙串取 key，避免明文落 json）。
    # 取不到值必须报错而不是静默回退，否则会悄悄退回 apiKeyHelper 的无限额 key。
    if isinstance(v, dict):
        if set(v.keys()) != {"$exec"}:
            raise SystemExit("env 对象值只支持 {\"$exec\": \"命令\"}")
        import subprocess
        r = subprocess.run(v["$exec"], shell=True, capture_output=True, text=True)
        if r.returncode != 0 or not r.stdout.strip():
            raise SystemExit(f"$exec 未取到值: {v['$exec']}")
        return r.stdout.strip()
    return v

env = {k: resolve_env_value(v) for k, v in (data.get("env", {})).items()}
# 网关管线：主模型必须还在管线里，五个档位钉到本管线，子代理档走全局默认模型（见 line_models.py 文件头）
plan = line_models.plan(data, sys.argv[3])
if plan:
    env["ANTHROPIC_MODEL"] = plan["route"]
    for k, v in plan["tiers"].items():
        env.setdefault(k, v)
    if plan["notice"]:
        print(f"⚠️  {plan['notice']}", file=sys.stderr)
# 自动压缩窗口安全网（所有线路，PITFALLS #58）：线路 env 自己写了按线路的；"off" 时显式 unset
window, window_warning = line_models.auto_compact_window(data, sys.argv[3])
if window_warning:
    print(f"⚠️  {window_warning}", file=sys.stderr)
if window:
    env.setdefault(line_models.AUTO_COMPACT_KEY, window)
all_keys = {"ANTHROPIC_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_API_TOKEN",
            "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_BASE_URL", "CLAUDE_AGENT_API_BASE_URL",
            "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "CLAUDE_API_KEY",
            "CLAUDE_CODE_API_KEY", "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY",
            # 直连线路/读不到全局默认模型时必须显式 unset：open -a 会把父环境整份带进新终端（PITFALLS #9b），
            # 不清掉就会继承别的会话留下的子代理档 / 压缩窗口
            line_models.SUBAGENT_KEY, line_models.AUTO_COMPACT_KEY}
all_keys.update(k for k in os.environ if k.startswith(("ANTHROPIC_DEFAULT_", "CCR_", "CODEXL_")))
all_keys.update(env.keys())
for k in sorted(all_keys):
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k):
        raise SystemExit(f"invalid env key: {k}")
    if k in env and env[k]:
        print(f"export {k}={shlex.quote(env[k])}")
    else:
        print(f"unset {k} 2>/dev/null || true")
if env.get("ANTHROPIC_BASE_URL") and "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY" not in env:
    print("export CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1")
PYEOF
}

get_provider_claude_args() {
  local name="$1" model_override="${2:-}" effort_override="${3:-}"
  local prov="$CCPOD_PROVIDERS_DIR/${name}.json"
  [[ -f "$prov" ]] || die "未知 provider: $name"
  require_cmd python3
  python3 - "$prov" "$(dirname "${BASH_SOURCE[0]}")" "$CCPOD_PROVIDERS_DIR" "$model_override" "$effort_override" <<'PYEOF'
import json, sys
data = json.load(open(sys.argv[1]))
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[2])
import line_models
# 启动时一次性的 --model / --effort：只改这次的副本，不写文件
if sys.argv[4] or sys.argv[5]:
    data = line_models.apply_overrides(data, sys.argv[3], model=sys.argv[4] or None, effort=sys.argv[5] or None)
args = data.get("claude_args", [])
if not isinstance(args, list) or not all(isinstance(x, str) for x in args):
    raise SystemExit("claude_args must be a string array")
plan = line_models.plan(data, sys.argv[3])
if plan:
    args = line_models.rewrite_model_arg(args, plan["route"])
level, warning = line_models.effort(data, sys.argv[3])
if warning:
    print("⚠️  " + warning, file=sys.stderr)
if level and not any(a == "--effort" or a.startswith("--effort=") for a in args):
    args = args + ["--effort", level]
for arg in args:
    if "\n" in arg or "\0" in arg:
        raise SystemExit("invalid claude_args value")
    print(arg)
PYEOF
}

# 启动时一次性的 --model / --effort（ccgo）：在记项目偏好、同步配置目录这些副作用之前先校验，出错说清原因
check_launch_overrides() {
  local name="$1" model_override="${2:-}" effort_override="${3:-}"
  [[ -n "$model_override" || -n "$effort_override" ]] || return 0
  local prov="$CCPOD_PROVIDERS_DIR/${name}.json"
  [[ -f "$prov" ]] || die "未知 provider: $name"
  require_cmd python3
  python3 - "$prov" "$(dirname "${BASH_SOURCE[0]}")" "$CCPOD_PROVIDERS_DIR" "$model_override" "$effort_override" <<'PYEOF'
import json, sys
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv[2])
import line_models
line_models.apply_overrides(json.load(open(sys.argv[1])), sys.argv[3],
                            model=sys.argv[4] or None, effort=sys.argv[5] or None)
PYEOF
}

provider_has_api_auth_env() {
  [[ -n "${ANTHROPIC_API_KEY:-}" \
    || -n "${ANTHROPIC_AUTH_TOKEN:-}" \
    || -n "${ANTHROPIC_API_TOKEN:-}" \
    || -n "${CLAUDE_API_KEY:-}" \
    || -n "${CLAUDE_CODE_API_KEY:-}" ]]
}

link_shared_claude_config_item() {
  local dir="$1" item="$2"
  local src="$CCPOD_CLAUDE_DIR/$item"
  local dst="$dir/$item"
  [[ -e "$src" || -L "$src" ]] || return 0

  if [[ -L "$dst" ]]; then
    local cur
    cur="$(readlink "$dst")"
    [[ "$cur" == "$src" ]] && return 0
    rm "$dst"
  elif [[ -e "$dst" ]]; then
    return 0
  fi

  ln -s "$src" "$dst"
}

sync_provider_settings_item() {
  local dir="$1" item="$2" prov="$3"
  local src="$CCPOD_CLAUDE_DIR/$item"
  local dst="$dir/$item"
  [[ -f "$src" ]] || return 0
  require_cmd python3
  python3 - "$src" "$dst" "$prov" <<'PYEOF'
import json
import os
import sys

src, dst, prov = sys.argv[1:4]
try:
    with open(src, encoding="utf-8") as f:
        settings = json.load(f)
except Exception:
    settings = {}
if not isinstance(settings, dict):
    settings = {}

# Provider sessions should discover gateway models dynamically. A copied
# availableModels allowlist becomes stale as soon as the provider adds models.
settings.pop("availableModels", None)

# 线路拥有自己的上游/鉴权/模型。settings.json 的 env 会**无条件覆盖**进程环境
# （官方 env-vars#precedence），而主配置由 CCR takeover 写成指向 127.0.0.1:3456。
# 原样复制 = 直连线路的 BASE_URL 被静默改回 CCR，拿线路 token 去打 CCR → 401，
# 模型发现也 401，/model 只剩主配置里的 GLM 标签（2026-09-27 #170 会话实测）。
with open(prov, encoding="utf-8") as f:
    provider = json.load(f)
prov_env = provider.get("env") or {}
has_model = bool(prov_env.get("ANTHROPIC_MODEL")) or "--model" in provider.get("claude_args", [])
changed_base = False
env = settings.get("env")
if isinstance(env, dict):
    # 先取主配置的上游，再删键（顺序反了会把同网关线路误判成换了上游）
    prov_base = prov_env.get("ANTHROPIC_BASE_URL")
    main_base = env.get("ANTHROPIC_BASE_URL")
    # 1. 线路定义了的键，一律让线路说了算
    for key in prov_env:
        env.pop(key, None)
    # 2. 换了上游或显式选模型 → 不继承主配置的其他线路模型档（同网关也可能是 GLM）。
    changed_base = isinstance(prov_base, str) and prov_base.rstrip("/") != str(main_base or "").rstrip("/")
    if changed_base or has_model:
        for key in list(env):
            if key in ("ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL") \
                    or key.startswith(("ANTHROPIC_DEFAULT_", "CCR_", "CODEXL_")):
                env.pop(key)
    if changed_base:
        for key in ("ANTHROPIC_BASE_URL", "ANTHROPIC_API_BASE_URL", "CLAUDE_AGENT_API_BASE_URL"):
            env.pop(key, None)
if changed_base or has_model:
    settings.pop("model", None)
# 3. 线路自带 token 时 apiKeyHelper 只会被忽略，还会触发 "Both ANTHROPIC_AUTH_TOKEN and apiKeyHelper set"
if any(k in prov_env for k in ("ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "ANTHROPIC_API_TOKEN",
                              "CLAUDE_API_KEY", "CLAUDE_CODE_API_KEY")):
    settings.pop("apiKeyHelper", None)

os.makedirs(os.path.dirname(dst), exist_ok=True)
if os.path.islink(dst):
    os.unlink(dst)
elif os.path.exists(dst) and not os.path.isfile(dst):
    raise SystemExit(f"refusing to overwrite non-file settings: {dst}")
tmp = f"{dst}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as f:
    os.fchmod(f.fileno(), 0o600)
    json.dump(settings, f, indent=2, ensure_ascii=False)
    f.write("\n")
os.replace(tmp, dst)
PYEOF
}

sync_provider_settings() {
  local dir="$1" name="$2"
  local prov="$CCPOD_PROVIDERS_DIR/${name}.json"
  sync_provider_settings_item "$dir" settings.json "$prov"
  sync_provider_settings_item "$dir" settings.local.json "$prov"
}

sync_provider_claude_state() {
  local dir="$1"
  local src="$HOME/.claude.json"
  local dst="$dir/.claude.json"
  [[ -f "$src" ]] || return 0
  require_cmd python3
  python3 - "$src" "$dst" <<'PYEOF'
import json
import os
import sys

src, dst = sys.argv[1:3]

def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

source = load(src)
current = load(dst)
if not isinstance(current, dict):
    current = {}

# Never copy account auth into provider configs. Claude Code 2.1+ treats
# oauthAccount + ANTHROPIC_API_KEY as an auth conflict.
for key in ("oauthAccount",):
    current.pop(key, None)

top_level = (
    "theme",
    "hasCompletedOnboarding",
    "lastOnboardingVersion",
    "customApiKeyResponses",
    "tipsHistory",
    "showSpinnerTree",
    "installMethod",
    "optionAsMetaKeyInstalled",
    "autoUpdates",
    "autoUpdatesProtectedForNative",
    "deepLinkTerminal",
)
for key in top_level:
    if key in source:
        current[key] = source[key]

project_keys = (
    "allowedTools",
    "mcpContextUris",
    "enabledMcpjsonServers",
    "disabledMcpjsonServers",
    "hasTrustDialogAccepted",
    "projectOnboardingSeenCount",
    "hasClaudeMdExternalIncludesApproved",
    "hasClaudeMdExternalIncludesWarningShown",
    "hasCompletedProjectOnboarding",
)
projects = {}
for path, data in source.get("projects", {}).items():
    if not isinstance(data, dict):
        continue
    clean = {key: data[key] for key in project_keys if key in data}
    if clean:
        projects[path] = clean
if projects:
    current["projects"] = projects

os.makedirs(os.path.dirname(dst), exist_ok=True)
tmp = f"{dst}.tmp.{os.getpid()}"
with open(tmp, "w", encoding="utf-8") as f:
    os.fchmod(f.fileno(), 0o600)
    json.dump(current, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, dst)
PYEOF
}

prepare_provider_claude_config() {
  local name="$1"
  # 无 token 的网关线路仍需隔离，否则主 settings.env 会盖过选定模型；
  # apiKeyHelper 留在副本里供网关鉴权使用。
  provider_has_api_auth_env || provider_is_gateway "$name" || return 0
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" && "$CLAUDE_CONFIG_DIR" != "$CCPOD_CLAUDE_DIR"/provider-configs/* ]]; then
    return 0
  fi

  local dir="$CCPOD_CLAUDE_DIR/provider-configs/$name"
  mkdir -p "$dir"
  chmod 700 "$CCPOD_CLAUDE_DIR/provider-configs" "$dir"

  # Claude Code 2.1+ refuses claude.ai OAuth + API key in the same config dir.
  # Keep auth isolated, while sharing normal ccpod settings and local history.
  local item
  for item in \
    CLAUDE.md \
    statusline.sh \
    ccpod-extra-cmd.sh \
    plugins \
    skills \
    projects \
    sessions \
    tasks \
    file-history \
    plans \
    paste-cache \
    shell-snapshots
  do
    link_shared_claude_config_item "$dir" "$item"
  done
  sync_provider_settings "$dir" "$name"
  sync_provider_claude_state "$dir"

  export CLAUDE_CONFIG_DIR="$dir"
}

run_pending_switch() {
  # 优先按**登记号**找 pending 文件：pid 会被系统复用，按 pid 命名的残留文件会让日后
  # 撞号的 ccgo 误换线；登记号单调、永不复用。仍回退看一眼旧命名，兼容升级前留下的文件。
  local pending=""
  if [[ -n "${CCPOD_SESSION_NUM:-}" && -f "$CCPOD_CLAUDE_DIR/ccpod-pending-$CCPOD_SESSION_NUM.json" ]]; then
    pending="$CCPOD_CLAUDE_DIR/ccpod-pending-$CCPOD_SESSION_NUM.json"
  elif [[ -f "$CCPOD_CLAUDE_DIR/ccpod-pending-$$.json" ]]; then
    pending="$CCPOD_CLAUDE_DIR/ccpod-pending-$$.json"
  else
    return 0
  fi
  require_cmd python3
  info "🔄 自动切换"
  # 换线重启要沿用本会话的号：显式交给下一个 ccgo（execv 继承环境）
  CCPOD_REUSE_NUM="${CCPOD_SESSION_NUM:-}" exec python3 -c '
import json, os, sys

pending, ccgo, my_num, my_pid = sys.argv[1:5]


def drop():
    # 解析失败也要删：留着一个坏文件会让这个会话每次退出都重试失败
    try:
        os.unlink(pending)
    except OSError:
        pass


try:
    with open(pending, encoding="utf-8") as f:
        data = json.load(f)
    # 身份校验：文件里写的登记号必须是本会话的，否则说明这是留给别人的（或历史残留）
    want = data.get("num")
    if want is None:
        # 旧格式文件（按 pid 命名、payload 里没有 num）：只有 pid 与本进程一致才消费。
        # 否则可能是升级前残留的文件被后来撞号的 ccgo 捡到 —— 那会莫名其妙换线、
        # 还 resume 到别人的会话（现网曾有一个残留 4 个月的 pending 文件）。
        if str(data.get("pid") or "") != (my_pid or ""):
            print("ccpod pending switch skipped: 旧格式文件且 pid 不符，已删除", file=sys.stderr)
            drop()
            sys.exit(0)
    elif str(want) != (my_num or ""):
        print(f"ccpod pending switch skipped: num={want} != this session {my_num}", file=sys.stderr)
        drop()
        sys.exit(0)
    provider = data.get("provider")
    project = data.get("project")
    if not isinstance(provider, str) or not provider:
        raise ValueError("missing provider")
    if not isinstance(project, str) or not project:
        raise ValueError("missing project")
    resume = data.get("sessionId")
    handoff = data.get("handoffDir")
    drop()
    argv = [ccgo, provider, project]
    if isinstance(handoff, str) and handoff:
        argv += ["--handoff", handoff]
    elif isinstance(resume, str) and resume:
        argv += ["--resume", resume]
    os.execv(ccgo, argv)
except SystemExit:
    raise
except Exception as exc:
    print(f"ccpod pending switch failed: {exc}", file=sys.stderr)
    drop()
    sys.exit(1)
' "$pending" "$SCRIPT_DIR/ccgo.sh" "${CCPOD_SESSION_NUM:-}" "$$"
}

# ─── Session registry ────────────────────────────────────
# Atomic read-modify-write of ccpod-sessions.json via python3.
register_session() {
  local pid="$1" tty="$2" provider="$3" project="$4" terminal="$5"
  require_cmd python3
  # 复用编号只认显式的一次性请求 CCPOD_REUSE_NUM（菜单栏「新窗口恢复」、切线路后自动重启时给出），
  # 调用方注册完必须 unset，别让它传给 claude 及其子孙。
  # 绝不能看 CCPOD_SESSION_NUM：那是「本会话自己的号」，会被会话里拉起的一切继承——连 `open -a Ghostty`
  # 都会把调用者的环境带给新启动的 App（2026-10-05 实测），在那个 Ghostty 里再开 ccgo 就和 #220 撞号。
  python3 - "$CCPOD_SESSIONS_FILE" "$pid" "$tty" "$provider" "$project" "$terminal" "$CCPOD_COUNTER_FILE" "${CCPOD_REUSE_NUM:-}" <<'PYEOF'
import fcntl, json, os, sys, tempfile, time
path, counter_path = sys.argv[1], sys.argv[7]
reuse_num = sys.argv[8].strip() if len(sys.argv) > 8 else ""
rec = {
    "pid": int(sys.argv[2]),
    "tty": sys.argv[3],
    "provider": sys.argv[4],
    "project": sys.argv[5],
    "terminal": sys.argv[6],
    "started_at": time.strftime("%Y-%m-%dT%H:%M:%S")
}
MAX_NUMBER = 2**63 - 1  # 与菜单栏 Swift Int 的范围一致。

def atomic_write(target, text):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(target))
    try:
        with os.fdopen(fd, "w") as f:
            f.write(text)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, target)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)

def read_counter(target):
    try:
        with open(target) as f:
            text = f.read().strip()
    except FileNotFoundError:
        return None, False
    # IO 错误不能当空文件；格式损坏可由另一份有效副本恢复。
    except UnicodeError:
        return None, True
    if not text.isascii() or not text.isdecimal():
        return None, True
    try:
        value = int(text)
    except ValueError:
        return None, True
    return (value if 0 <= value <= MAX_NUMBER else None), True

try:
    os.makedirs(os.path.dirname(counter_path), exist_ok=True)
    # 锁独立文件：计数文件被原子替换后，锁仍由所有分配者共用。
    with open(counter_path + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(path) as f:
                data = json.load(f)
        except FileNotFoundError:
            data = []
        if not isinstance(data, list) or any(not isinstance(s, dict) for s in data):
            raise ValueError("会话登记文件格式错误，原文件保留")
        known_numbers = [s["num"] for s in data if "num" in s and s["num"] is not None]
        if any(type(n) is not int or not 1 <= n <= MAX_NUMBER for n in known_numbers):
            raise ValueError("会话登记包含非法编号，原文件保留")
        primary, primary_exists = read_counter(counter_path)
        backup, backup_exists = read_counter(counter_path + ".bak")
        valid = [n for n in (primary, backup) if n is not None]
        if not valid:
            if primary_exists or backup_exists or data:
                raise ValueError("编号及恢复副本不可用；请从备份恢复计数文件，拒绝从 1 重置")
            counter = 0
        else:
            counter = max(valid + known_numbers)
        if reuse_num:
            if not reuse_num.isascii() or not reuse_num.isdecimal():
                raise ValueError("复用编号必须为正整数")
            num = int(reuse_num)
        else:
            num = counter + 1
        if not 1 <= num <= MAX_NUMBER:
            raise ValueError("会话编号超出有效范围")
        high_water = max(counter, num)
        # 副本保存最新保留编号，而非上一版；中断最多跳号，不回退复用。
        atomic_write(counter_path + ".bak", str(high_water))
        atomic_write(counter_path, str(high_water))
        rec["num"] = num
        data = [s for s in data if s.get("pid") != rec["pid"]]
        data.append(rec)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        atomic_write(path, json.dumps(data, indent=2))
        # 启动记录（菜单栏管线区按「近 7 天启动次数」排序用；直连线路不经网关、网关账本里没有它们）。
        # 记录失败不影响会话登记；超过 2000 行时只留最近 1000 行。
        try:
            log_path = os.path.join(os.path.dirname(path), "ccpod-launch-log.jsonl")
            with open(log_path, "a") as lf:
                lf.write(json.dumps({"at": int(time.time()), "provider": rec["provider"]}) + "\n")
            with open(log_path) as lf:
                lines = lf.readlines()
            if len(lines) > 2000:
                atomic_write(log_path, "".join(lines[-1000:]))
        except OSError:
            pass
        print(num)
except (OSError, ValueError) as exc:
    print(f"ccpod 会话登记失败：{exc}", file=sys.stderr)
    sys.exit(1)
PYEOF
}

set_terminal_title() {
  printf '\033]2;%s\007' "$1"
}

unregister_session() {
  local pid="$1"
  [[ -f "$CCPOD_SESSIONS_FILE" ]] || return 0
  require_cmd python3
  python3 - "$CCPOD_SESSIONS_FILE" "$pid" "$CCPOD_COUNTER_FILE" <<'PYEOF'
import fcntl, json, os, sys, tempfile, time


def take_registry_lock(lock_path, timeout=3.0):
    """与 register_session、菜单栏 SessionManager 共用同一把锁。
    三个写表方任意两个并发做 read→modify→整份替换都会 last-writer-wins 抹掉对方。
    有界等待：锁被卡住的进程占着时宁可退化成无锁写，也不能把退出 trap 拖死
    （那会让终端一直不返回）。返回的 fd 由调用方负责关闭。"""
    try:
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
    except OSError:
        return None
    deadline = time.time() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.time() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.05)

path, pid, counter_path = sys.argv[1], int(sys.argv[2]), sys.argv[3]
lock_fd = take_registry_lock(counter_path + ".lock")
try:
    try:
        data = json.load(open(path))
    except Exception:
        sys.exit(0)
    kept = [s for s in data if s.get("pid") != pid]
    if len(kept) == len(data):
        sys.exit(0)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as f:
        json.dump(kept, f, indent=2)
    os.replace(tmp, path)
finally:
    if lock_fd is not None:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)
PYEOF
}

cleanup_dead_sessions() {
  [[ -f "$CCPOD_SESSIONS_FILE" ]] || return 0
  require_cmd python3
  python3 - "$CCPOD_SESSIONS_FILE" "$CCPOD_COUNTER_FILE" <<'PYEOF'
import fcntl, json, os, sys, tempfile, time


def take_registry_lock(lock_path, timeout=3.0):
    """与 register_session、菜单栏 SessionManager 共用同一把锁。
    三个写表方任意两个并发做 read→modify→整份替换都会 last-writer-wins 抹掉对方。
    有界等待：锁被卡住的进程占着时宁可退化成无锁写，也不能把退出 trap 拖死
    （那会让终端一直不返回）。返回的 fd 由调用方负责关闭。"""
    try:
        fd = os.open(lock_path, os.O_RDWR | os.O_CREAT | os.O_APPEND, 0o600)
    except OSError:
        return None
    deadline = time.time() + timeout
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd
        except OSError:
            if time.time() >= deadline:
                os.close(fd)
                return None
            time.sleep(0.05)

path, counter_path = sys.argv[1], sys.argv[2]
lock_fd = take_registry_lock(counter_path + ".lock")
try:
    try:
        data = json.load(open(path))
    except Exception:
        sys.exit(0)
    alive = []
    for s in data:
        try:
            os.kill(s["pid"], 0)
            alive.append(s)
        except OSError:
            pass
    if len(alive) != len(data):
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
        with os.fdopen(fd, "w") as f:
            json.dump(alive, f, indent=2)
        os.replace(tmp, path)
finally:
    if lock_fd is not None:
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)
PYEOF
}

# ─── 会话收尾：reap 子孙 + 幂等注销 + 信号 trap（ccgo / ccstart 共用）─────
# 三件事必须按这个顺序、且**只真正执行一次**。早先两个脚本的信号 handler 都写成
# `trap - EXIT HUP TERM; 清理; exit`：清理期间（reap 最长 ~1.5s）再来一个信号，
# 就按默认动作直接打死脚本，注销永不执行 → 登记表留下僵尸行（实测复现：
# 关终端窗的 HUP 叠加系统补的 TERM）。僵尸行 + pid 复用 = 菜单栏可能杀掉无辜进程。
# 现在 handler 不摘 trap，改用标志位保证幂等：第二个信号进来直接返回，清理一定跑完。

ccpod_reap_descendants() {
  # SIGTERM 直系子进程（claude 等），最多等 1.5s 再 SIGKILL，避免孤儿。
  # 调用方脚本顶部有 set -e；pgrep 没命中时 rc=1 会让 handler 中途夭折，故都 || true 兜底。
  local kids i stragglers
  kids="$(pgrep -P "$$" 2>/dev/null || true)"
  [[ -z "$kids" ]] && return 0
  kill -TERM $kids 2>/dev/null || true
  for i in 1 2 3 4 5 6; do
    [[ -z "$(pgrep -P "$$" 2>/dev/null || true)" ]] && return 0
    sleep 0.25
  done
  stragglers="$(pgrep -P "$$" 2>/dev/null || true)"
  if [[ -n "$stragglers" ]]; then kill -KILL $stragglers 2>/dev/null || true; fi
  return 0
}

ccpod_cleanup_registered_session() {
  # 幂等：注销过就把变量清空，EXIT 与信号 handler 重复触发也只会真注销一次
  [[ -n "${CCPOD_REGISTERED_PID:-}" ]] || return 0
  local _pid="$CCPOD_REGISTERED_PID"
  CCPOD_REGISTERED_PID=""
  unregister_session "$_pid" || true
  return 0
}

ccpod_signal_cleanup() {
  [[ "${CCPOD_CLEANING:-0}" == 1 ]] && return 0
  CCPOD_CLEANING=1
  ccpod_reap_descendants || true
  ccpod_cleanup_registered_session || true
  case "${1:-}" in
    HUP)  exit 129 ;;
    TERM) exit 143 ;;
    *)    exit 0 ;;
  esac
}

ccpod_install_signal_traps() {
  trap ccpod_cleanup_registered_session EXIT
  trap 'ccpod_signal_cleanup HUP' HUP
  trap 'ccpod_signal_cleanup TERM' TERM
}
