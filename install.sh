#!/usr/bin/env bash
# install.sh — install ccpod commands into the user's PATH
#
# Creates symlinks in ~/.local/bin pointing into this repo.
# Copies provider templates into ~/.claude/providers/ (without overwriting
# existing user configs).
#
# Idempotent — safe to run multiple times.

set -euo pipefail

REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${CCPOD_BIN_DIR:-$HOME/.local/bin}"
CLAUDE_DIR="${CCPOD_CLAUDE_DIR:-$HOME/.claude}"
PROV_DIR="$CLAUDE_DIR/providers"

info()  { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m⚠\033[0m  %s\n' "$*" >&2; }
die()   { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

# ─── 1. Deps check ─────────────────────────────────────────
command -v jq      >/dev/null 2>&1 || die "缺少 jq (安装: brew install jq)"
command -v python3 >/dev/null 2>&1 || die "缺少 python3"

# ─── 2. Ensure directories exist ───────────────────────────
mkdir -p "$BIN_DIR" "$PROV_DIR"
# 凭证目录必须 700：里面是各条线路的 api_key
chmod 700 "$PROV_DIR" 2>/dev/null || true
# 顺带把历史遗留的宽权限 provider 文件收紧（老版本用裸 cp 装的会是 644）
find "$PROV_DIR" -maxdepth 1 -type f -name '*.json' ! -perm 600 -exec chmod 600 {} + 2>/dev/null || true

# ─── 3. Link scripts ───────────────────────────────────────
link_cmd() {
  local name="$1"
  local src="${2:-$REPO_DIR/scripts/${name}.sh}"
  local dst="$BIN_DIR/$name"

  [[ -f "$src" ]] || die "缺少脚本: $src"
  chmod +x "$src"

  if [[ -L "$dst" ]]; then
    local current
    current="$(readlink "$dst")"
    if [[ "$current" == "$src" ]]; then
      info "已链接: $dst"
      return
    fi
    warn "覆盖旧链接: $dst → $current"
    rm -f "$dst"
  elif [[ -e "$dst" ]]; then
    die "$dst 已存在且不是符号链接，请手动删除后再试"
  fi

  ln -s "$src" "$dst"
  info "链接: $dst → $src"
}

for cmd in ccuse ccstart ccnow ccgo ccdoctor ccpod-key ccworktree; do
  link_cmd "$cmd"
done
# 已退役的命令：脚本删了，旧链接会变成悬空链接，顺手清掉（只清指向本仓库的）
for cmd in ccgoal; do
  dst="$BIN_DIR/$cmd"
  if [[ -L "$dst" && "$(readlink "$dst")" == "$REPO_DIR/scripts/${cmd}.sh" ]]; then
    rm -f "$dst"
    info "移除已退役命令的旧链接: $dst"
  fi
done
link_cmd cchandoff "$REPO_DIR/scripts/cchandoff.py"

# ─── 4. Copy provider templates (never overwrite) ──────────
copy_provider() {
  local src_name="$1"
  local dst_name="$2"
  local src="$REPO_DIR/providers/$src_name"
  local dst="$PROV_DIR/$dst_name"

  [[ -f "$src" ]] || die "缺少模板: $src"

  if [[ -f "$dst" ]]; then
    info "保留现有: $dst"
  else
    cp "$src" "$dst"
    info "复制: $dst"
  fi
  # provider json 可能含明文 api_key（用户自己加的那几条就是），一律收紧到 600。
  # 裸 cp 会按 umask 落成 644 = 本机任何用户/进程都能读走密钥。
  chmod 600 "$dst"
}

copy_provider "official.json"           "official.json"

# ─── 4b. line-check 运行时副本（源在网关实验室项目，装一份到 ~/.claude/bin）───
# 菜单栏"线路"卡依赖它；实验室项目不存在时跳过（App 内有优雅降级）。
LAB_LINECHECK="$HOME/projects/model-gateway/scripts/line-check.py"
if [[ -f "$LAB_LINECHECK" ]]; then
  mkdir -p "$CLAUDE_DIR/bin"
  cp "$LAB_LINECHECK" "$CLAUDE_DIR/bin/line-check.py"
  info "复制: line-check.py → ~/.claude/bin/"
else
  info "跳过 line-check（未找到网关实验室项目）"
fi

# ─── 4c. claude-rename（会话改名 / 自动标题）───
# 菜单栏会话卡的「重命名」按钮直接调它，所以它是产品依赖，必须随安装一起落地。
# 仓库是唯一编辑源，这里无条件覆盖（与 line-check.py 同一套"仓库存源码、装运行时副本"模式）。
if [[ -f "$REPO_DIR/scripts/claude-rename" ]]; then
  mkdir -p "$CLAUDE_DIR/bin"
  cp "$REPO_DIR/scripts/claude-rename" "$CLAUDE_DIR/bin/claude-rename"
  chmod +x "$CLAUDE_DIR/bin/claude-rename"
  info "复制: claude-rename → ~/.claude/bin/"
else
  warn "缺少 $REPO_DIR/scripts/claude-rename — 菜单栏的重命名按钮会报找不到工具"
fi

# ─── 5. Approval Gate（2026-09-26 已下线）──────────────────
# 下线原因（用户拍板）：Claude Code 自带的权限体系已经够用，不需要我们再插一层；
# 而且这一层会把每次工具调用的命令、路径、参数摘要发给第三方模型判断，容易侵犯用户隐私。
# 所以这里不再注册 hook，反过来主动摘除历史安装留下的注册项——否则重装会把哨兵装回去。
# hooks/approval/ 代码、scripts/ccapproval.sh、scripts/approval-ralph.sh 已删除（git 历史里可取回）。
# ~/.ccpod/ 下的状态与审计日志**保留**（含历史明文 key，清理需用户授权）；
# ErrorDiagnosisService 仍会把 ~/.ccpod/approval-config.json 当兜底配置源，所以那个 json 别删。
# 下面这个路径只作为**字符串**用于匹配历史注册项，目录不存在也照样能摘干净。
CCPOD_DIR="${HOME}/.ccpod"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
APPROVAL_HOOK_DIR="$REPO_DIR/hooks/approval"

mkdir -p "$CCPOD_DIR"
info "目录: $CCPOD_DIR"

# 顺带清掉旧版装过的 ccapproval（闸门下线后它已无意义）
if [[ -L "$BIN_DIR/ccapproval" || -e "$BIN_DIR/ccapproval" ]]; then
  rm -f "$BIN_DIR/ccapproval"
  info "移除: $BIN_DIR/ccapproval（Approval Gate 已下线）"
fi

if [[ -f "$SETTINGS_FILE" ]]; then
  python3 - "$SETTINGS_FILE" "$APPROVAL_HOOK_DIR" <<'PYEOF'
import json, os, sys, tempfile
path, hook_dir = sys.argv[1], sys.argv[2]

def is_ccpod_approval(command):
    # 不能只匹配本次安装的 REPO_DIR：仓库挪过位置、或从另一个 clone 装过，
    # 历史注册项写的是当时的绝对路径，按当前路径匹配会静默漏摘 —— hook 继续跑、
    # 继续把工具调用内容外发。按目录名匹配才与安装位置无关。
    if not isinstance(command, str):
        return False
    return hook_dir in command or "/hooks/approval/" in command

try:
    data = json.load(open(path))
except Exception:
    sys.exit(0)
hooks = data.get("hooks")
if not isinstance(hooks, dict):
    sys.exit(0)

removed = set()
for event in ("PreToolUse", "PostToolUse"):
    groups = hooks.get(event)
    if not isinstance(groups, list):
        continue
    kept = []
    for group in groups:
        if not isinstance(group, dict):
            kept.append(group)
            continue
        handlers = group.get("hooks")
        if isinstance(handlers, list):
            survivors = [h for h in handlers
                         if not (isinstance(h, dict) and is_ccpod_approval(h.get("command")))]
            if len(survivors) != len(handlers):
                removed.add(event)
            if survivors:
                group["hooks"] = survivors
                kept.append(group)
            continue
        # 旧版 ccpod 写过的错误形状：{"type":"command","command":"…/pretool_hook.py"}
        if is_ccpod_approval(group.get("command")):
            removed.add(event)
            continue
        kept.append(group)
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)
if not hooks:
    data.pop("hooks", None)

if removed:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, path)
    print("已摘除历史注册的审批 hook: " + ", ".join(sorted(removed)))
PYEOF
  info "Approval Gate: 已下线（不再注册 hook，历史注册项已摘除）"
else
  warn "未找到 $SETTINGS_FILE — 跳过 hook 摘除"
fi

# ─── 6. PATH check ─────────────────────────────────────────
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR 不在 \$PATH 中，请添加: export PATH=\"$BIN_DIR:\$PATH\"" ;;
esac

echo
info "ccpod 安装完成。试试: ccuse --list"
echo
info "Approval Gate 已于 2026-09-26 下线：权限判断交回 Claude Code 自带体系"
info "下线原因与审查台账见 CHANGELOG 2026-09-26 条目"

# ─── 7. 安装之初就把风险讲清楚（用户要求：不能让人在不知情的前提下接受风险）───
cat <<'RISK'

┌─ ⚠️  使用前请知道这三件事 ─────────────────────────────────────┐
│                                                              │
│ 1. 你的**所有上游线路密钥**会集中在 CCR 网关的数据库里          │
│    (~/.claude-code-router/config.sqlite)。这是选它做统一路由   │
│    的代价：CCR 被入侵或坏更新 = 全部密钥一起暴露。**无法根治**，  │
│    只能减面（0600 权限、升级前备份、盲打验证）。                 │
│                                                              │
│ 2. ccpod 会读你的会话记录(~/.claude/projects/*.jsonl)与进程列表 │
│    用来显示标题、模型、活动时间——**只读，不联网、不上报**。       │
│    它也会向终端 TTY 注入命令（关闭会话 / 新窗口继承切线）。       │
│                                                              │
│ 3. 这个项目**没有经过第三方独立安全审计**。做过 3 轮对抗性自审   │
│    (修掉 17+ 项，含作者自己引入的 2 个高危)，但那是自审，        │
│    不是机构背书；也不公开用户数。                              │
│                                                              │
│ 密钥现状：钥匙串是唯一权威存放点，配置文件里只有 $exec 引用；    │
│ 含密钥的文件一律 600、目录 700；落盘与回显前自动脱敏。           │
│                                                              │
│ 随时自查（都只读）：                                           │
│   ccdoctor          # 安装/运行一致性 + 密钥卫生                │
│   ccpod-key doctor  # 配置文件里还有没有明文密钥                │
│   ccpod-key list    # 钥匙串条目（只显名字与指纹，不显密钥）      │
│                                                              │
│ 完整威胁模型与"出问题怎么办"：docs/SECURITY.md                 │
└──────────────────────────────────────────────────────────────┘
RISK
info "已安装。第一次用建议先看 docs/SECURITY.md"
