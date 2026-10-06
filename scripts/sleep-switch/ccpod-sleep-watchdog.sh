#!/bin/bash
# ccpod-sleep-watchdog — 「合盖保持唤醒」安全兜底（LaunchAgent 每 60s 调一次）。
# disablesleep=1 且（接 AC 或电量低于阈值）→ sudo -n 调 helper off + 通知。
# 可选参数 1：电量阈值（默认 20；测试时传 99 可在非低电环境触发低电分支）。
# 注意：launchd 环境 PATH 极简，本脚本内一律绝对路径。
set -u

HELPER=/usr/local/libexec/ccpod-sleep-switch
SUDO=/usr/bin/sudo
MIN_BATT="${1:-20}"

[ -x "$HELPER" ] || exit 0

# 开关没开就直接退（绝大多数情况）。sudo 失败说明授权被拆，记日志后安静退出。
status="$("$SUDO" -n "$HELPER" status 2>/dev/null)"
rc=$?
if [ $rc -ne 0 ]; then
  echo "$(date '+%F %T') watchdog: sudo -n helper status 失败(rc=$rc)，授权可能已卸载" >&2
  exit 0
fi
[ "$status" = "1" ] || exit 0

batt="$(/usr/bin/pmset -g batt)"

# 只在电池供电且低电时自动关（2026-10-06 修正）：
# helper 改用 -a 后开关状态跨拔插持久，「AC 下自动关」会把用户在桌前打开的开关
# 偷偷关掉，拔线后合盖即睡眠。插着电保持唤醒无耗电风险，真风险只有低电。
reason=""
case "$batt" in
  *"AC Power"*) : ;;  # AC：不动
  *)
    pct="$(printf '%s\n' "$batt" | /usr/bin/sed -n 's/.*[^0-9]\([0-9][0-9]*\)%.*/\1/p' | /usr/bin/head -1)"
    if [ -n "$pct" ] && [ "$pct" -lt "$MIN_BATT" ]; then
      reason="电量 ${pct}% 低于阈值 ${MIN_BATT}%"
    fi
    ;;
esac
[ -n "$reason" ] || exit 0

if "$SUDO" -n "$HELPER" off; then
  echo "$(date '+%F %T') watchdog: 自动关闭保持唤醒（${reason}）"
  /usr/bin/osascript -e "display notification \"已自动关闭保持唤醒（${reason}）\" with title \"CCPod\" sound name \"Glass\"" || true
else
  echo "$(date '+%F %T') watchdog: 需要关闭（${reason}）但 sudo -n helper off 失败" >&2
fi
