#!/usr/bin/env bash
# release.sh — Build, install, tag, and optionally create a GitHub release.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
VERSION_FILE="$REPO_DIR/VERSION"
CREATE_GITHUB_RELEASE=0
SKIP_INSTALL=0

info() { printf '✅ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*" >&2; }
die() { printf '❌ %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") <version> [--github-release] [--skip-install]

Example:
  scripts/release.sh 0.3.0 --github-release
EOF
}

version="${1:-}"
[[ -n "$version" ]] || { usage >&2; exit 2; }
shift || true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --github-release) CREATE_GITHUB_RELEASE=1 ;;
    --skip-install) SKIP_INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9._-]+)?$ ]] \
  || die "版本号不合法: $version"

cd "$REPO_DIR"
# 脏树不许发布：build.sh 会把 `-dirty` 写进产物的 commit 标记，产物就说不清是哪份代码构建的。
# 旧顺序是"先写 VERSION 再 build"，那时 VERSION 的改动还没提交 → **每次发布必然产出 -dirty**。
if [[ -n "$(git status --porcelain)" ]]; then
  die "工作区有未提交改动，请先提交或 stash 再发布（git status --porcelain 有输出）"
fi

printf '%s\n' "$version" > "$VERSION_FILE"
# 先提交 VERSION 再构建：构建时工作区干净，写进 Info.plist 的 commit 就是这次发布提交本身
git add "$VERSION_FILE"
git commit -m "发布 ${version}"
info "已提交 VERSION=${version}（$(git rev-parse --short HEAD)）"

if [[ "$SKIP_INSTALL" -eq 1 ]]; then
  "$REPO_DIR/menubar/build.sh"
else
  "$REPO_DIR/menubar/build.sh" --install
fi

# ccdoctor 不过就不打 tag：否则会出现"tag 指向一个校验失败的产物"
"$REPO_DIR/scripts/ccdoctor.sh" || die "ccdoctor 未通过，发布中止（tag 未创建）"

# 不再硬编码 git add 文件清单：旧清单既会漏掉新增文件，又会把用户暂存区里
# 无关的改动一并卷进发布提交。release.sh 唯一的改动就是 VERSION，其余代码必须提前提交
# （上面的脏树检查已经保证了这一点）。
git tag "v$version"
info "已创建 tag v$version"

if [[ "$CREATE_GITHUB_RELEASE" -eq 1 ]]; then
  command -v gh >/dev/null 2>&1 || die "缺少 gh CLI"
  archive="$REPO_DIR/menubar/build/CCPod-${version}.zip"
  ditto -c -k --keepParent "$REPO_DIR/menubar/build/CCPod.app" "$archive"
  gh release create "v$version" "$archive" --title "v$version" --generate-notes
  info "已创建 GitHub Release v$version"
fi
