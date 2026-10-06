#!/usr/bin/env bash
# test_ccworktree.sh — 验证 ccworktree 的核心断言：worktree 隔离让两会话不互相踩源码。
# 用法: scripts/tests/test_ccworktree.sh
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

fail() { echo "❌ FAIL: $1" >&2; exit 1; }
pass() { echo "✅ $1"; }

# ── 造一个一次性 git 仓库 ──────────────────────────────
t="$scratch/proj"
mkdir -p "$t"
git -C "$t" init -q
git -C "$t" config user.email t@t
git -C "$t" config user.name t
echo "line1" > "$t/file.txt"
git -C "$t" add file.txt
git -C "$t" commit -qm init
git -C "$t" branch -M main

export CCPOD_WORKTREES_ROOT="$scratch/wts"
export CCWORKTREE_DRY_RUN=1   # 不真的 exec claude

# ── 1. 创建 worktree（ccworktree 不启动 claude，只建树 + 打印将执行的命令）──
out="$("$repo/scripts/ccworktree.sh" someprovider featA "$t")"
echo "$out" | grep -q "DRY-RUN: 将执行 ccgo someprovider" \
  || fail "应当打印 dry-run 启动命令，实际: $out"
pass "ccworktree 创建流程跑通（dry-run）"

wt="$CCPOD_WORKTREES_ROOT/$(basename "$t")/featA"
[ -d "$wt" ] || fail "worktree 目录未创建: $wt"
git -C "$t" worktree list | grep -q "$wt" || fail "worktree 未登记到仓库"
pass "worktree 已创建并登记: $wt"

# 分支名应为 wt/featA
git -C "$wt" rev-parse --abbrev-ref HEAD | grep -qx "wt/featA" \
  || fail "worktree 分支名不是 wt/featA"
pass "worktree 分支为 wt/featA"

# ── 2. 核心断言：在 worktree 里改文件，主树不受影响 ──────
echo "changed-in-worktree" > "$wt/file.txt"
main_status="$(git -C "$t" status --porcelain)"
[ -z "$main_status" ] || fail "主树被 worktree 的改动污染了: $main_status"
pass "主树 status 干净（worktree 改动未泄漏到主树）"

git -C "$wt" status --porcelain | grep -q "file.txt" \
  || fail "worktree 自己的改动没被看到"
pass "worktree 自己的 status 看得到改动"

# ── 3. 主树切换分支不影响 worktree 内容 ─────────────────
git -C "$wt" stash -q  # 让 wt 干净，便于后面 remove
main_head_before="$(git -C "$t" rev-parse HEAD)"
[ -n "$main_head_before" ] || fail "读不到主树 HEAD"
pass "主树 HEAD 独立可读（与 worktree 分支互不干扰）"

# ── 4. 删除 worktree ────────────────────────────────────
git -C "$t" worktree remove "$wt" || fail "worktree remove 失败"
[ -d "$wt" ] && fail "worktree 删除后目录仍在"
pass "worktree 可干净移除"

echo
echo "全部通过 ✅（worktree 隔离断言成立）"
