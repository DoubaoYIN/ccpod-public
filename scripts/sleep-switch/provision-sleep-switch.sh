#!/bin/bash
# provision-sleep-switch.sh — 「合盖保持唤醒」的一次性授权安装/卸载。
# 用法（需要 root）：sudo ./provision-sleep-switch.sh install|uninstall
# install 内容：helper → /usr/local/libexec、sudoers 免密规则（visudo 校验后生效）、
#               看门狗 LaunchAgent → ~/Library/LaunchAgents 并 bootstrap。
set -euo pipefail

REPO_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER_DST=/usr/local/libexec/ccpod-sleep-switch
SUDOERS=/etc/sudoers.d/ccpod-sleep-switch
AGENT_LABEL=com.ccpod.sleep-switch-watchdog
LOG_DIR="$REPO_DIR/.local/sleep-switch"

die() { printf '✗ %s\n' "$*" >&2; exit 1; }
info() { printf '✓ %s\n' "$*"; }

# 操作对象是 GUI 登录用户而不是 root：console 属主在 sudo/osascript 提权两种路径下都可靠
CONSOLE_USER="$(stat -f %Su /dev/console)"
CONSOLE_UID="$(id -u "$CONSOLE_USER")"
CONSOLE_HOME="$(eval echo "~$CONSOLE_USER")"
AGENT_DST="$CONSOLE_HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

cmd_install() {
  [[ $EUID -eq 0 ]] || die "需要 root：sudo $0 install"
  [[ -f "$REPO_DIR/scripts/sleep-switch/ccpod-sleep-switch" ]] || die "仓库里缺 helper 脚本"

  install -d -o root -g wheel -m 755 /usr/local/libexec
  install -o root -g wheel -m 755 "$REPO_DIR/scripts/sleep-switch/ccpod-sleep-switch" "$HELPER_DST"
  info "helper 已装到 $HELPER_DST"

  # sudoers：先写临时文件，visudo 校验通过才落位（写歪的 sudoers 会锁死全机 sudo）
  local tmp
  tmp="$(mktemp /tmp/ccpod-sudoers.XXXXXX)"
  printf '%%admin ALL=(root) NOPASSWD: %s\n' "$HELPER_DST" > "$tmp"
  chmod 440 "$tmp"
  visudo -c -f "$tmp" >/dev/null || { rm -f "$tmp"; die "sudoers 校验失败，未写入"; }
  install -o root -g wheel -m 440 "$tmp" "$SUDOERS"
  rm -f "$tmp"
  info "sudoers 规则已装到 $SUDOERS"

  # 看门狗 LaunchAgent：plist 里的仓库路径按本机实际位置渲染（模板用 __REPO_DIR__ 占位）
  install -d -o "$CONSOLE_USER" -g staff -m 755 "$CONSOLE_HOME/Library/LaunchAgents"
  install -d -o "$CONSOLE_USER" -g staff -m 700 "$LOG_DIR"
  sed "s|__REPO_DIR__|$REPO_DIR|g" "$REPO_DIR/scripts/launchd/$AGENT_LABEL.plist" > "$AGENT_DST"
  chown "$CONSOLE_USER":staff "$AGENT_DST"
  chmod 644 "$AGENT_DST"
  # 重复安装幂等：先 bootout（不存在也不报错）再 bootstrap
  sudo -u "$CONSOLE_USER" launchctl bootout "gui/$CONSOLE_UID/$AGENT_LABEL" 2>/dev/null || true
  sudo -u "$CONSOLE_USER" launchctl bootstrap "gui/$CONSOLE_UID" "$AGENT_DST"
  info "看门狗已加载（gui/$CONSOLE_UID/${AGENT_LABEL}，每 60s）"

  info "安装完成。验证：sudo -n $HELPER_DST status 应输出 0 或 1"
}

cmd_uninstall() {
  [[ $EUID -eq 0 ]] || die "需要 root：sudo $0 uninstall"
  # 顺序：先摘看门狗（防止它再触发），再恢复 disablesleep 0，最后删文件
  sudo -u "$CONSOLE_USER" launchctl bootout "gui/$CONSOLE_UID/$AGENT_LABEL" 2>/dev/null || true
  rm -f "$AGENT_DST" && info "看门狗已卸载"
  if [[ -x "$HELPER_DST" ]]; then
    "$HELPER_DST" off && info "已恢复 disablesleep 0"
  fi
  rm -f "$SUDOERS" && info "sudoers 规则已删"
  rm -f "$HELPER_DST" && info "helper 已删"
  info "卸载完成"
}

case "${1:-}" in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  *) die "usage: $0 install|uninstall" ;;
esac
