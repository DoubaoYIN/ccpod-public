#!/usr/bin/env bash
# ccstart — Interactive launcher for Claude Code
#   Pick a recent project, pick a provider, then launch `claude`.
#   Each window gets its own provider via env injection.
# Part of ccpod

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

gather_projects() {
  local d="$HOME/.claude/projects"
  [[ -d "$d" ]] || return 0
  ls -t1 "$d" 2>/dev/null | head -20 | while IFS= read -r enc; do
    local decoded
    decoded="$(echo "$enc" | sed 's|^-|/|; s|-|/|g')"
    [[ -d "$decoded" ]] && echo "$decoded"
  done
}

pick_working_dir() {
  local -a projects=()
  local line
  while IFS= read -r line; do
    projects+=("$line")
  done < <(gather_projects)

  if [[ ${#projects[@]} -eq 0 ]]; then
    read -r -p "工作目录路径: " workdir
    echo "$workdir"
    return
  fi

  echo "" >&2
  echo "最近项目:" >&2
  local i=1
  for p in "${projects[@]}"; do
    printf '  %d) %s\n' "$i" "$p" >&2
    ((i++))
  done
  printf '  %d) [手动输入]\n' "$i" >&2
  echo "" >&2

  local choice
  read -r -p "请选择 [1-$i]: " choice

  if [[ "$choice" == "$i" ]]; then
    local workdir
    read -r -p "工作目录路径: " workdir
    echo "$workdir"
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
    echo "${projects[$((choice-1))]}"
  else
    die "无效选择: $choice"
  fi
}

pick_provider() {
  local default_prov="$1"
  local -a providers=()
  local names name
  names="$(available_provider_names)" || die "读取线路列表失败"
  while IFS= read -r name; do
    [[ -n "$name" ]] && providers+=("$name")
  done <<< "$names"
  [[ ${#providers[@]} -gt 0 ]] || die "没有可用线路；请先同步网关模型或导入线路"

  echo "" >&2
  echo "线路 (默认: $(get_provider_display_name "$default_prov")):" >&2
  local i=1
  for p in "${providers[@]}"; do
    local badge
    badge="$(ccpod_format_badge "$p")"
    printf '  %d) %s\n' "$i" "$badge" >&2
    ((i++))
  done
  local choice
  read -r -p "请选择 [1-$((i-1))/回车默认]: " choice

  case "$choice" in
    "") echo "$default_prov" ;;
    *)
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice < i )); then
        echo "${providers[$((choice-1))]}"
      else
        die "无效选择: $choice"
      fi
      ;;
  esac
}

main() {
  echo "ccpod · 交互式启动"

  require_cmd claude "https://github.com/anthropics/claude-code"

  local workdir
  workdir="$(pick_working_dir)"
  [[ -n "$workdir" && -d "$workdir" ]] || die "目录不存在: $workdir"

  local default_prov
  default_prov="$(get_default_provider "$workdir")" || die "无法选择默认线路"

  local prov
  prov="$(pick_provider "$default_prov")"

  # Remember preference
  remember_project_provider "$workdir" "$prov"

  # Inject provider env vars
  # 赋值式捕获：eval "$(…)" 会把取 key 失败吞成 eval ""（rc=0），claude 随后无 key 启动
  # 并回落到 apiKeyHelper，属静默降级。详见 ccgo.sh 同款注释。
  local ccpod_env_out
  ccpod_env_out="$(get_provider_env "$prov")" \
    || die "取线路 env 失败: ${prov}（钥匙串不可用或 provider 配置有误）——拒绝以无 key 状态启动"
  eval "$ccpod_env_out"
  prepare_provider_claude_config "$prov"
  local -a claude_args=()
  local ccpod_args_out arg
  ccpod_args_out="$(get_provider_claude_args "$prov")" || die "取线路 claude 参数失败: $prov"
  while IFS= read -r arg; do
    [[ -n "$arg" ]] && claude_args+=("$arg")
  done <<< "$ccpod_args_out"

  # Register session
  cleanup_dead_sessions
  local cur_tty cur_terminal
  cur_tty="$(tty 2>/dev/null || true)"
  [[ "$cur_tty" == "not a tty" || -z "$cur_tty" ]] && cur_tty="unknown"
  cur_terminal="$(detect_terminal)"
  local session_num
  session_num="$(register_session $$ "$cur_tty" "$prov" "$workdir" "$cur_terminal")"
  unset CCPOD_REUSE_NUM   # 一次性请求，用完即清（见 register_session 注释）
  CCPOD_REGISTERED_PID="$$"
  # reap + 幂等注销 + 不摘 trap 的信号处理，统一在 common.sh（ccstart 也用同一套）
  ccpod_install_signal_traps

  local project_name provider_label
  project_name="$(basename "$workdir")"
  provider_label="$(get_provider_display_name "$prov")"
  set_terminal_title "#${session_num} ${provider_label} · ${project_name}"

  export CCPOD_SESSION_NUM="$session_num"
  export CCPOD_PROVIDER="$prov"

  echo ""
  info "✅ #${session_num} ${provider_label} · $workdir"
  cd "$workdir"
  if (( ${#claude_args[@]} > 0 )); then
    claude "${claude_args[@]}" || true
  else
    claude || true
  fi

  # claude exited — check if menu bar app left a pending switch request
  run_pending_switch
}

main "$@"
