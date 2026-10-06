#!/usr/bin/env bash
# ccgo — switch provider and launch Claude Code in one shot.
#   Each window gets its own provider via env injection (not settings.json).
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

usage() {
  cat <<'EOF'
ccgo — 切换线路并启动 Claude Code

USAGE
  ccgo <provider>              在当前目录启动
  ccgo <provider> <project>    在最近使用过、路径含 <project> 的目录启动
  ccgo <provider> <project> --resume <session-id>
  ccgo <provider> <project> --handoff <handoff-dir>
  ccgo --help, -h              显示帮助

每个窗口独立：env 注入，不改 settings.json。

EXAMPLES
  ccgo easy                    easyclaude + cwd
  ccgo off                     official + cwd
  ccgo easy analytics          easyclaude + 最近含 "analytics" 的项目
  ccgo off ccpod               official + 最近含 "ccpod" 的项目
  ccgo my-relay /Users/yourname --resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
EOF
}

main() {
  case "${1:-}" in
    ""|-h|--help) usage; exit 0 ;;
  esac

  require_cmd claude "https://github.com/anthropics/claude-code"

  local name workdir resume_id handoff_dir
  name="$(resolve_provider "$1")"

  if [[ $# -ge 4 && "${3:-}" == "--resume" ]]; then
    resume_id="$4"
  elif [[ $# -ge 4 && "${3:-}" == "--handoff" ]]; then
    handoff_dir="$4"
  elif [[ $# -gt 2 ]]; then
    die "参数无效；恢复会话请使用: ccgo <provider> <project> --resume <session-id> 或 --handoff <handoff-dir>"
  fi

  if [[ $# -ge 2 ]]; then
    if [[ -d "$2" ]]; then
      workdir="$2"
    else
      workdir="$(find_project_by_fragment "$2")" \
        || die "找不到项目含 '$2'"
    fi
  else
    workdir="$(pwd)"
  fi
  [[ -d "$workdir" ]] || die "目录不存在: $workdir"

  # Remember this project's provider preference
  remember_project_provider "$workdir" "$name"

  # Inject provider env vars into this shell (inherited by exec claude)
  # 不能写成 eval "$(get_provider_env …)"：取 key 失败（钥匙串上锁/条目缺失/无 GUI 上下文）时
  # 子进程 stdout 为空、退出码被命令替换吃掉，eval "" 返回 0，set -e 不触发 —— claude 会以
  # 无 key 状态启动并回落到 settings.json 的 apiKeyHelper，正是 common.sh 注释里声称要防的
  # 静默降级。改成赋值式捕获，失败即 die（赋值形式的命令替换失败会正常传播退出码）。
  local ccpod_env_out
  ccpod_env_out="$(get_provider_env "$name")" \
    || die "取线路 env 失败: ${name}（钥匙串不可用或 provider 配置有误）——拒绝以无 key 状态启动"
  eval "$ccpod_env_out"
  prepare_provider_claude_config "$name"
  local -a claude_args=()
  local ccpod_args_out
  # 同上：进程替换 < <(...) 失败时静默丢掉 --model 等参数，会话会以错误的模型启动
  ccpod_args_out="$(get_provider_claude_args "$name")" \
    || die "取线路 claude 参数失败: $name"
  while IFS= read -r arg; do
    [[ -n "$arg" ]] && claude_args+=("$arg")
  done <<< "$ccpod_args_out"

  # Register session (cleanup stale ones first)
  cleanup_dead_sessions
  local cur_tty cur_terminal
  cur_tty="$(tty 2>/dev/null || true)"
  [[ "$cur_tty" == "not a tty" || -z "$cur_tty" ]] && cur_tty="unknown"
  cur_terminal="$(detect_terminal)"
  local session_num
  session_num="$(register_session $$ "$cur_tty" "$name" "$workdir" "$cur_terminal")"
  unset CCPOD_REUSE_NUM   # 一次性请求，用完即清（见 register_session 注释）
  CCPOD_REGISTERED_PID="$$"
  # reap + 幂等注销 + 不摘 trap 的信号处理，统一在 common.sh（ccstart 也用同一套）
  ccpod_install_signal_traps

  local project_name provider_label
  project_name="$(basename "$workdir")"
  provider_label="$(get_provider_display_name "$name")"
  set_terminal_title "#${session_num} ${provider_label} · ${project_name}"

  export CCPOD_SESSION_NUM="$session_num"
  export CCPOD_PROVIDER="$name"

  info "✅ #${session_num} ${provider_label} · $workdir"
  cd "$workdir"
  if [[ -n "${handoff_dir:-}" ]]; then
    local prompt_file="$handoff_dir/bootstrap-prompt.md"
    [[ -f "$prompt_file" ]] || die "handoff prompt 不存在: $prompt_file"
    local prompt_text
    prompt_text="$(cat "$prompt_file")"
    if (( ${#claude_args[@]} > 0 )); then
      claude "${claude_args[@]}" "$prompt_text" || true
    else
      claude "$prompt_text" || true
    fi
  elif [[ -n "${resume_id:-}" ]]; then
    if (( ${#claude_args[@]} > 0 )); then
      claude "${claude_args[@]}" --resume "$resume_id" || true
    else
      claude --resume "$resume_id" || true
    fi
  else
    if (( ${#claude_args[@]} > 0 )); then
      claude "${claude_args[@]}" || true
    else
      claude || true
    fi
  fi

  # claude exited — check if menu bar app left a pending switch request
  run_pending_switch
}

main "$@"
