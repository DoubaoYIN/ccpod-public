#!/usr/bin/env bash
# ccworktree — 在独立 git worktree 中启动 Claude Code（多会话并行隔离）。
# Part of ccpod。设计见 docs/ccpod-worktree-plan.md。
#
# 为什么需要：多个 ccgo 会话默认共用**同一棵工作树**，会互相覆盖未提交的改动、
# 互相被 git add -A/clean 扫走、并发 build.sh --install 装出混合态 App。
# worktree 给每个会话一份独立检出目录（共享 .git），把"防互踩"从纪律变成文件系统事实。
#
# 注意边界：worktree 隔离**源码**；`/Applications/CCPod.app` 与 ~/.claude 仍是共享的，
# 并发装机仍需串行（见文档第三、六节）。

set -euo pipefail

SCRIPT_DIR="$(
  src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    dir="$(cd -P "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd -P "$(dirname "$src")" && pwd
)"

source "$SCRIPT_DIR/lib/common.sh"

# worktree 根目录：集中放，且**放在仓库之外**——避免主树的 git status 把它当未跟踪文件
#（否则主树里一次 git add -A 反而会把 worktree 内容卷进去，与初衷相反）。
CCPOD_WORKTREES_ROOT="${CCPOD_WORKTREES_ROOT:-$HOME/.ccpod/worktrees}"

usage() {
  cat <<'EOF'
ccworktree — 在独立 git worktree 里启动 Claude Code（多会话并行隔离）

USAGE
  ccworktree <provider> <name> [repo]   创建/复用 worktree 并启动
  ccworktree list [repo]                列出本仓已有的 worktree
  ccworktree rm <name> [repo]           移除 worktree（不删分支）
  ccworktree --help, -h

说明
  - worktree 路径: $HOME/.ccpod/worktrees/<repo名>/<name>（可用 CCPOD_WORKTREES_ROOT 覆盖）
  - 分支: wt/<name>，基于当前 HEAD
  - 启动逻辑完全复用 ccgo（同一套 env 注入 / 登记 / 标题）

EXAMPLES
  ccworktree gw-kimi-e4f9c522 feat-quota
  ccworktree gw-glm-2bf548d8 hotfix-1 /Users/yourname/Projects/ccpod
  ccworktree list
  ccworktree rm feat-quota
EOF
}

resolve_repo() {
  local repo="${1:-}"
  if [[ -z "$repo" ]]; then
    repo="$(git rev-parse --show-toplevel 2>/dev/null)" \
      || die "当前目录不在 git 仓库内；请显式传入 <repo>"
  fi
  ( cd "$repo" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null ) \
    || die "不是 git 仓库: $repo"
}

wt_path() { # repo name
  printf '%s/%s/%s' "$CCPOD_WORKTREES_ROOT" "$(basename "$1")" "$2"
}

cmd_launch() {
  local provider="$1" name="$2" repo
  repo="$(resolve_repo "${3:-}")"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "name 只允许字母数字 . _ -（避免路径越界）: $name"

  local path; path="$(wt_path "$repo" "$name")"
  mkdir -p "$(dirname "$path")"

  if [[ -d "$path" ]]; then
    info "复用已有 worktree: $path"
  else
    git -C "$repo" worktree add -b "wt/$name" "$path" HEAD >/dev/null \
      || die "创建 worktree 失败（分支 wt/$name 可能已存在）"
    info "✅ 已创建 worktree: ${path}（分支 wt/${name}）"
  fi

  # 启动：复用 ccgo 全部逻辑（env 注入 / 登记 / 标题 / pending switch）
  if [[ "${CCWORKTREE_DRY_RUN:-}" == "1" ]]; then
    echo "DRY-RUN: 将执行 ccgo ${provider} ${path}"
    exit 0
  fi
  exec "$SCRIPT_DIR/ccgo.sh" "$provider" "$path"
}

cmd_list() {
  local repo; repo="$(resolve_repo "${1:-}")"
  echo "worktrees（${repo}）:"
  git -C "$repo" worktree list
}

cmd_rm() {
  local name="$1" repo; repo="$(resolve_repo "${2:-}")"
  local path; path="$(wt_path "$repo" "$name")"
  git -C "$repo" worktree remove "$path" \
    && info "已移除 worktree: ${path}（分支 wt/${name} 保留，需要的话: git -C ${repo} branch -d wt/${name}）"
}

main() {
  case "${1:-}" in
    ""|-h|--help) usage; exit 0 ;;
    list) shift; cmd_list "$@"; exit 0 ;;
    rm)   shift; [[ $# -ge 1 ]] || die "用法: ccworktree rm <name> [repo]"; cmd_rm "$@"; exit 0 ;;
  esac
  [[ $# -ge 2 ]] || { usage; exit 1; }
  require_cmd git
  cmd_launch "$@"
}

main "$@"
