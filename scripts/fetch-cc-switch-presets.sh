#!/bin/bash
# 定期拉取 cc-switch 最新 provider 预设，检测厂商端点/模型是否有变化。
#
# 背景：国内厂商（火山/腾讯/Kimi/智谱/百炼…）的端点、模型名、套餐会频繁变动，
# CCPod 模板（menubar/Sources/CCPodMenuBar/ProviderTemplate.swift）依赖这些信息。
# cc-switch（github.com/farion1231/cc-switch，14 万 star 且日更）是社区维护的
# 「厂商 Claude Code 接入预设」事实标准——用它作为交叉验证源，检测到变化即提醒。
#
# 用法：
#   scripts/fetch-cc-switch-presets.sh          # 手动跑一次
#   配合 launchd / crontab 定期执行（建议每日一次）
#
# 输出：
#   - 有变化：更新 .local/cc-switch-presets/ 快照并打印「📝 <file> 有变化」
#   - 无变化：打印「✅ 无变化」
# 快照存 .local/cc-switch-presets/（不提交 git），变化后需人工 diff 到 ProviderTemplate.swift 并实测。
set -euo pipefail

# launchd/cron 环境的 PATH 很干净（只有系统路径 /usr/bin:/bin），不含 brew 的 gh。
# 显式补上，否则 gh 找不到（实测：env -i 干净环境 gh 直接 No such file or directory）。
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$REPO_ROOT/.local/cc-switch-presets"
mkdir -p "$DIR"

FILES=(
  "src/config/claudeProviderPresets.ts:claudeProviderPresets.ts"
  "src/config/codingPlanProviders.ts:codingPlanProviders.ts"
)

changed=0
for entry in "${FILES[@]}"; do
  path="${entry%%:*}"
  name="${entry##*:}"
  tmp="$DIR/$name.tmp"
  if gh api "repos/farion1231/cc-switch/contents/$path" --jq '.content' 2>/dev/null | base64 -d > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    if [ -f "$DIR/$name" ] && cmp -s "$tmp" "$DIR/$name"; then
      rm -f "$tmp"   # 无变化
    else
      mv "$tmp" "$DIR/$name"
      echo "📝 $name 有变化（$(date '+%Y-%m-%d %H:%M')）——请 diff 到 ProviderTemplate.swift 并实测"
      changed=1
    fi
  else
    echo "⚠️ 拉取 $path 失败（检查 gh 登录态 / 网络）"
    rm -f "$tmp" 2>/dev/null || true
  fi
done

if [ "$changed" -eq 0 ]; then
  echo "✅ cc-switch 预设无变化（$(date '+%Y-%m-%d %H:%M')）"
fi
