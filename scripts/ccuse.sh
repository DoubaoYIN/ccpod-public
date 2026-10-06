#!/usr/bin/env bash
# ccuse — Switch between Claude Code providers
# Part of ccpod: https://github.com/<owner>/ccpod

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

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

usage() {
  cat <<'EOF'
ccuse — Set default Claude Code provider

USAGE
  ccuse <provider>       Set default provider (prefix OK)
  ccuse --list, -l       List available providers
  ccuse --help, -h       Show this help

Note: ccuse sets the default for ccstart/ccgo. It does NOT modify
settings.json. Each CC window gets its own provider via env injection.

EXAMPLES
  ccuse --list           查看已同步或导入的线路 ID
  ccuse ccr              使用网关默认模型
  ccuse ccr-bailian      使用百炼 Qwen3.8 Max
EOF
}

list_providers() {
  echo "Available providers:"
  local found=0 names name
  names="$(available_provider_names)" || die "读取线路列表失败"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    local marker=""
    if [[ -f "$CCPOD_CURRENT_FILE" ]] && [[ "$(cat "$CCPOD_CURRENT_FILE")" == "$name" ]]; then
      marker=" (current)"
    fi
    echo "  - $(ccpod_format_badge "$name") [$name]$marker"
    found=1
  done <<< "$names"
  if [[ $found -eq 0 ]]; then
    echo "  (没有可用线路；请先同步网关模型或导入线路)"
  fi
}

main() {
  case "${1:-}" in
    ""|-h|--help) usage; exit 0 ;;
    -l|--list)    list_providers; exit 0 ;;
  esac

  local name
  name="$(resolve_provider "$1")"

  [[ -d "$CCPOD_CLAUDE_DIR" ]] || mkdir -p "$CCPOD_CLAUDE_DIR"

  echo "$name" > "$CCPOD_CURRENT_FILE"
  ccpod_format_badge "$name" > "$CCPOD_STATUS_FILE"
  info "✅ 已设为默认: $(get_provider_display_name "$name") [$name]"

  # Smart-default B: remember this project's preferred provider
  if [[ -n "${CCPOD_PROJECT_DIR:-}" ]]; then
    remember_project_provider "$CCPOD_PROJECT_DIR" "$name"
  fi
}

main "$@"
