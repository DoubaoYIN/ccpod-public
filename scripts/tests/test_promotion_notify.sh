#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$repo/menubar/.build"
scratch="$(mktemp -d "$repo/menubar/.build/promotion-notify-tests.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# 🔴 源文件显式点名，不许通配：同目录下 50 个 .swift 大量依赖 SwiftUI，
# 独立编译必炸（同 test_promotion_store.sh:7-8 的口径）。
# 🔴 计划 :2969-2971 漏了 SecretResolver.swift（PromotionRadar.swift 里
# SecretRedactor 有多个调用点，定义在 SecretResolver.swift）→ 照计划必
# `cannot find 'SecretRedactor' in scope`。放在第一位，与 Task 5 通道一致。
swiftc "$repo/menubar/Sources/CCPodMenuBar/SecretResolver.swift" \
  "$repo/menubar/Sources/CCPodMenuBar/PromotionRadar.swift" \
  "$repo/menubar/Sources/CCPodMenuBar/PromotionNotifyPolicy.swift" \
  "$repo/scripts/tests/promotion_notify.swift" -o "$scratch/check"
"$scratch/check"
