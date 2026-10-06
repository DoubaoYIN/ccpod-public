#!/usr/bin/env bash
# build.sh — compile CCPodMenuBar and wrap it in a .app bundle.
#
# Outputs: menubar/build/CCPod.app

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="CCPod"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
EXEC_NAME="CCPodMenuBar"
SOURCE_PLIST="$SCRIPT_DIR/Resources/Info.plist"
INSTALL_DIR="${CCPOD_INSTALL_DIR:-/Applications}"
INSTALL_APP_DIR="$INSTALL_DIR/$APP_NAME.app"
INSTALL_APP=0
RESTART_APP=1

info() { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m⚠\033[0m  %s\n' "$*" >&2; }
fail() { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $(basename "$0") [--install] [--no-restart]

Options:
  --install     Install $APP_NAME.app into $INSTALL_DIR, replacing the running app
  --no-restart  Do not reopen the app after --install
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install|install) INSTALL_APP=1 ;;
    --no-restart) RESTART_APP=0 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

plist_set() {
  local key="$1" value="$2"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$APP_DIR/Contents/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Add :$key string $value" "$APP_DIR/Contents/Info.plist" >/dev/null
}

source_version() {
  local version_file="$REPO_DIR/VERSION"
  if [[ -f "$version_file" ]]; then
    tr -d '[:space:]' < "$version_file"
  else
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SOURCE_PLIST"
  fi
}

git_value() {
  git -C "$SCRIPT_DIR" "$@" 2>/dev/null || true
}

process_path() {
  local pid="$1"
  ps -p "$pid" -o comm= 2>/dev/null | sed 's/^ *//'
}

pid_is_alive() {
  local pid="$1"
  kill -0 "$pid" >/dev/null 2>&1
}

wait_for_pids_exit() {
  local deadline=$((SECONDS + 8))
  local pid
  while (( SECONDS < deadline )); do
    local alive=0
    for pid in "$@"; do
      [[ -n "$pid" ]] || continue
      if pid_is_alive "$pid"; then
        alive=1
        break
      fi
    done
    [[ "$alive" -eq 0 ]] && return 0
    sleep 0.2
  done
  return 1
}

wait_for_installed_app_start() {
  local expected="$INSTALL_APP_DIR/Contents/MacOS/$EXEC_NAME"
  local deadline=$((SECONDS + 8))
  local pid path
  while (( SECONDS < deadline )); do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      path="$(process_path "$pid")"
      [[ "$path" == "$expected" ]] && return 0
    done < <(pgrep -x "$EXEC_NAME" || true)
    sleep 0.2
  done
  return 1
}

run_doctor() {
  local doctor="$REPO_DIR/scripts/ccdoctor.sh"
  [[ -f "$doctor" ]] || return 0
  echo
  info "运行 ccdoctor 校验安装状态"
  bash "$doctor"
}

info "swift build -c release"
cd "$SCRIPT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/$EXEC_NAME"
[[ -f "$BIN_PATH" ]] || { echo "找不到二进制: $BIN_PATH" >&2; exit 1; }

info "打包 $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$EXEC_NAME"
cp "$SOURCE_PLIST" "$APP_DIR/Contents/Info.plist"

APP_VERSION="${CCPOD_VERSION:-$(source_version)}"
BUILD_NUMBER="${CCPOD_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
GIT_COMMIT="$(git_value rev-parse --short HEAD)"
if [[ -n "$(git_value status --porcelain)" ]]; then
  GIT_COMMIT="${GIT_COMMIT:-unknown}-dirty"
fi
BUILD_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

plist_set "CFBundleShortVersionString" "$APP_VERSION"
plist_set "CFBundleVersion" "$BUILD_NUMBER"
plist_set "CCPodGitCommit" "${GIT_COMMIT:-unknown}"
plist_set "CCPodBuildTime" "$BUILD_TIME"

# Ad-hoc code sign so macOS will run it without Gatekeeper blocking.
# 把安全说明随包分发：风险告知弹窗里的「打开完整安全说明」按钮靠它，
# 发布版（.zip 拖进 /Applications）没有仓库，必须自带
if [[ -f "$REPO_DIR/docs/SECURITY.md" ]]; then
  cp "$REPO_DIR/docs/SECURITY.md" "$APP_DIR/Contents/Resources/SECURITY.md"
fi

# 应用图标（程序坞 / 通知横幅 / 访达）；源图由 scripts/make-app-icon.swift 生成
cp "$SCRIPT_DIR/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo
info "构建完成: $APP_DIR ($APP_VERSION/$BUILD_NUMBER ${GIT_COMMIT:-unknown})"
echo
echo "运行: open \"$APP_DIR\""
echo "安装: $(basename "$0") --install"

if [[ "$INSTALL_APP" -eq 1 ]]; then
  info "安装到 $INSTALL_APP_DIR"
  old_pids=()
  while IFS= read -r pid; do
    [[ -n "$pid" ]] && old_pids+=("$pid")
  done < <(pgrep -x "$EXEC_NAME" || true)
  if [[ "${#old_pids[@]}" -gt 0 ]]; then
    pkill -TERM -x "$EXEC_NAME" || true
    if ! wait_for_pids_exit "${old_pids[@]}"; then
      warn "旧 $EXEC_NAME 进程未及时退出，强制结束"
      for pid in "${old_pids[@]}"; do
        if pid_is_alive "$pid"; then
          kill -KILL "$pid" >/dev/null 2>&1 || true
        fi
      done
      wait_for_pids_exit "${old_pids[@]}" || fail "无法停止旧 $EXEC_NAME 进程"
    fi
  fi
  rm -rf "$INSTALL_APP_DIR"
  ditto "$APP_DIR" "$INSTALL_APP_DIR"
  codesign --force --sign - "$INSTALL_APP_DIR" >/dev/null 2>&1 || true
  if [[ "$RESTART_APP" -eq 1 ]]; then
    open "$INSTALL_APP_DIR"
    wait_for_installed_app_start || fail "已安装但未检测到从 $INSTALL_APP_DIR 启动的新进程"
    info "已重启 $APP_NAME"
    run_doctor
  else
    warn "已安装但未重启"
  fi
fi
