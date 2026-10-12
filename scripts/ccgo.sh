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
  ccgo <provider> [<project>] --model <模型> --effort <档位>
                               只这一次：换成管线清单里的别的模型 / 思考强度（low…max），不改线路文件
  ccgo --help, -h              显示帮助

每个窗口独立：env 注入，不改 settings.json。

EXAMPLES
  ccgo easy                    easyclaude + cwd
  ccgo off                     official + cwd
  ccgo easy analytics          easyclaude + 最近含 "analytics" 的项目
  ccgo off ccpod               official + 最近含 "ccpod" 的项目
  ccgo my-relay /Users/yourname --resume aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee
  ccgo off ccpod --effort max  official + ccpod，这一次用最高思考强度
EOF
}

main() {
  case "${1:-}" in
    ""|-h|--help) usage; exit 0 ;;
  esac

  require_cmd claude "https://github.com/anthropics/claude-code"

  local name workdir resume_id handoff_dir project_arg model_override effort_override has_project=""
  name="$(resolve_provider "$1")"
  shift
  # 第二个参数是项目（可省略）；之后全是选项，顺序任意。
  # 用 has_project 而不是「project_arg 非空」判断：菜单栏项目列表为空时会传空串，那种情况要照旧走项目查找
  if [[ $# -gt 0 && "$1" != --* ]]; then
    project_arg="$1"
    has_project=1
    shift
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --resume|--handoff|--model|--effort)
        [[ $# -ge 2 && -n "${2:-}" ]] || die "参数 ${1} 缺值（用法见 ccgo --help）"
        case "$1" in
          --resume) resume_id="$2" ;;
          --handoff) handoff_dir="$2" ;;
          --model) model_override="$2" ;;
          --effort) effort_override="$2" ;;
        esac
        shift 2
        ;;
      *) die "参数无效: ${1}（用法见 ccgo --help）" ;;
    esac
  done
  if [[ -n "${resume_id:-}" && -n "${handoff_dir:-}" ]]; then
    die "--resume 和 --handoff 不能同时用"
  fi
  # 启动时一次性的模型 / 思考强度：先校验，再做任何副作用（记项目偏好、同步配置目录）
  check_launch_overrides "$name" "${model_override:-}" "${effort_override:-}" \
    || die "启动参数无效（原因见上一行），没有启动"

  if [[ -n "$has_project" ]]; then
    if [[ -d "$project_arg" ]]; then
      workdir="$project_arg"
    else
      workdir="$(find_project_by_fragment "$project_arg")" \
        || die "找不到项目含 '$project_arg'"
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
  ccpod_env_out="$(get_provider_env "$name" "${model_override:-}")" \
    || die "取线路 env 失败: ${name}（钥匙串不可用或 provider 配置有误）——拒绝以无 key 状态启动"
  eval "$ccpod_env_out"
  prepare_provider_claude_config "$name"
  local -a claude_args=()
  local ccpod_args_out
  # 同上：进程替换 < <(...) 失败时静默丢掉 --model 等参数，会话会以错误的模型启动
  ccpod_args_out="$(get_provider_claude_args "$name" "${model_override:-}" "${effort_override:-}")" \
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
