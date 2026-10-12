#!/usr/bin/env bash
# nightwatch-hook.py 离线单测：全程 mktemp 沙箱（NIGHTWATCH_HOME），不碰真实 ~/.claude/nightwatch，
# 不装 hook、不改 settings。每条断言 grep 正面文本（验证纪律 1/2：失败与通过必须输出不同的东西）。
# 注：JSON fixture 一律用单引号常量——嵌进 ${1:-...} 默认值的 `}` 会被 bash 参数展开的括号匹配吃掉（实测）。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
hook="$repo/scripts/nightwatch/nightwatch-hook.py"
[[ -f "$hook" ]] || { echo "FAIL 找不到 $hook"; exit 1; }
[[ -f "$repo/scripts/cchandoff.py" ]] || { echo "FAIL 找不到 cchandoff.py（脱敏依赖）"; exit 1; }

scratch="$(mktemp -d)"
# macOS bash 3.2：挂了 EXIT 钩子后 set -u 崩溃退出码可能是 0（2026-10-05 复现过），用「跑到了最后」标记判。
finished=0
trap 'rm -rf "$scratch"; if [[ "$finished" != 1 ]]; then echo "FAIL 测试脚本中途退出，没有跑完"; exit 1; fi' EXIT
fails=0
ok()   { echo "  ok   $1"; }
fail() { echo "  FAIL $1"; fails=$((fails + 1)); }

export NIGHTWATCH_HOME="$scratch/home"
export NIGHTWATCH_CCHANDOFF_DIR="$repo/scripts"
mkdir -p "$NIGHTWATCH_HOME/asks" "$NIGHTWATCH_HOME/morning"
chmod 700 "$NIGHTWATCH_HOME"

DEFAULT_INPUT='{"questions":[{"question":"测试题：继续吗？","header":"测试","options":[{"label":"A"}],"multiSelect":false}]}'

# 灌 mode.json（ccnight 的写入格式）
set_mode() {  # set_mode <json>
  printf '%s' "$1" > "$NIGHTWATCH_HOME/mode.json"
  chmod 600 "$NIGHTWATCH_HOME/mode.json"
}
# 生成一次 PreToolUse AskUserQuestion payload（可带自定义 tool_input / session_id）
ask_payload() {  # ask_payload [tool_input_json] [session_id] → stdout
  local input="${1:-}"
  [[ -n "$input" ]] || input="$DEFAULT_INPUT"
  local sid="${2:-aaaa1111-2222-3333-4444-555566667777}"
  printf '{"hook_event_name":"PreToolUse","session_id":"%s","cwd":"/tmp/x","tool_name":"AskUserQuestion","tool_input":%s}' "$sid" "$input"
}
run_hook() {  # stdin → hook；stdout 存 $scratch/out，stderr 存 $scratch/err
  python3 "$hook" > "$scratch/out" 2>"$scratch/err"
}
# 依赖 ask 文件的断言统一走这里，文件缺失时逐个 FAIL 而不是让 set -e 打断脚本
check_ask_file() {  # check_ask_file <文件>
  local f="$1"
  if [[ ! -f "$f" ]]; then fail "ask 文件不存在: $f（后续断言跳过）"; return; fi
  grep -q "^attempt: 1$" "$f" && ok "front-matter attempt: 1" || fail "attempt 应为 1: $(grep attempt "$f" || true)"
  grep -q "^tool: AskUserQuestion$" "$f" && ok "front-matter tool" || fail "front-matter 缺 tool"
  grep -q "测试题：继续吗" "$f" && ok "问题正文在场" || fail "问题正文缺失"
  [[ "$(stat -f '%Lp' "$f")" == "600" ]] && ok "ask 文件权限 600" || fail "ask 权限应 600，实际 $(stat -f '%Lp' "$f")"
}

echo "== 1. off（mode.json 缺失/off）→ passthrough 零输出"
rm -f "$NIGHTWATCH_HOME/mode.json"
ask_payload | run_hook
[[ ! -s "$scratch/out" ]] && ok "缺失 mode.json → 空输出" || fail "缺失 mode.json 应空输出，实际: $(cat "$scratch/out")"
set_mode '{"mode":"off"}'
ask_payload | run_hook
[[ ! -s "$scratch/out" ]] && ok "mode=off → 空输出" || fail "mode=off 应空输出，实际: $(cat "$scratch/out")"
[[ "$(ls "$NIGHTWATCH_HOME/asks" | wc -l | tr -d ' ')" == "0" ]] && ok "off 态不落盘 asks" || fail "off 态不该产生 ask 文件"

echo "== 2. on → deny JSON + 引导词 + 落盘 attempt:1"
expires=$(( $(date +%s) + 3600 ))
set_mode "{\"mode\":\"on\",\"since\":$(date +%s),\"expiresAt\":$expires,\"idleMin\":20,\"reason\":\"测试\"}"
ask_payload | run_hook
grep -q '"permissionDecision": "deny"' "$scratch/out" && ok "输出 deny" || fail "应输出 permissionDecision:deny，实际: $(cat "$scratch/out" ) err: $(cat "$scratch/err")"
grep -q "夜间守门人" "$scratch/out" && ok "reason 含「夜间守门人」" || fail "reason 缺「夜间守门人」: $(cat "$scratch/out")"
grep -q "不要再次调用 AskUserQuestion/ExitPlanMode" "$scratch/out" && ok "第 1 档引导词在场" || fail "第 1 档引导词缺失"
grep -q 'updatedInput\|"allow"' "$scratch/out" && fail "🔴 红线违规：输出含 allow/updatedInput" || ok "红线：无 allow/updatedInput"
ask_file="$(ls "$NIGHTWATCH_HOME/asks"/*.md 2>/dev/null | head -1 || true)"
[[ -n "$ask_file" ]] && ok "ask 文件已落盘: $(basename "$ask_file")" || fail "ask 文件未落盘"
check_ask_file "${ask_file:-/nonexistent}"
[[ "$(stat -f '%Lp' "$NIGHTWATCH_HOME/asks")" == "700" ]] && ok "asks 目录权限 700" || fail "asks 目录权限应为 700"
grep -q '"event": "ask_denied"' "$NIGHTWATCH_HOME/events.jsonl" && ok "events 记 ask_denied" || fail "events 缺 ask_denied"
[[ "$(stat -f '%Lp' "$NIGHTWATCH_HOME/events.jsonl")" == "600" ]] && ok "events.jsonl 权限 600" || fail "events.jsonl 权限应 600"

echo "== 3. 同一问题第 2/3/4 次 → 递进引导词"
ask_payload | run_hook
grep -q "第二次拦截" "$scratch/out" && ok "第 2 次含「第二次拦截」" || fail "第 2 次应含「第二次拦截」: $(cat "$scratch/out")"
ask_payload | run_hook
grep -q "第三次拦截" "$scratch/out" && ok "第 3 次含「第三次拦截」" || fail "第 3 次应含「第三次拦截」: $(cat "$scratch/out")"
ask_payload | run_hook
grep -q "第三次拦截" "$scratch/out" && ok "第 4 次仍封在第三档（无越界档位）" || fail "第 4 次应仍为「第三次拦截」"
uniq_suffix="$(ls "$NIGHTWATCH_HOME/asks" | sed -E 's/^[0-9]{8}-[0-9]{6}-[0-9]{3}-//' | sort -u | wc -l | tr -d ' ')"
[[ "$uniq_suffix" == "1" ]] && ok "同 sid+hash 后缀唯一（attempt 走计数不撞名）" || fail "意外出现多个 sid-hash 后缀: $uniq_suffix"
grep -q '"attempt": 2' "$NIGHTWATCH_HOME/events.jsonl" && ok "events 有 attempt:2" || fail "events 缺 attempt:2"
grep -q '"attempt": 3' "$NIGHTWATCH_HOME/events.jsonl" && ok "events 有 attempt:3" || fail "events 缺 attempt:3"

echo "== 4. ExitPlanMode 变体引导词"
printf '{"hook_event_name":"PreToolUse","session_id":"bbbb1111-0000","cwd":"/tmp/x","tool_name":"ExitPlanMode","tool_input":{}}' | run_hook
grep -q "计划审批冻结" "$scratch/out" && ok "ExitPlanMode → 计划变体引导词" || fail "ExitPlanMode 应给计划变体: $(cat "$scratch/out")"
grep -q "把完整计划作为回复文本输出" "$scratch/out" && ok "变体含「计划输出进回复文本」" || fail "变体缺回复文本指令"

echo "== 5. 非目标工具 → passthrough"
printf '{"hook_event_name":"PreToolUse","session_id":"aaaa1111","cwd":"/tmp/x","tool_name":"Bash","tool_input":{"command":"ls"}}' | run_hook
[[ ! -s "$scratch/out" ]] && ok "Bash 不拦（零输出）" || fail "Bash 不该被拦: $(cat "$scratch/out")"

echo "== 6. redact import 失败 → fail-open（不 deny 不落盘）+ errors.log"
rm -rf "$scratch/home2"; mkdir -p "$scratch/home2/asks"
# 观测前提（验证纪律 4）：home2 必须是 on 态，否则走 off 分支根本到不了 redact import
printf '{"mode":"on","expiresAt":%s}' "$(( $(date +%s) + 3600 ))" > "$scratch/home2/mode.json"
ask_payload > "$scratch/payload6.json"
(
  export NIGHTWATCH_HOME="$scratch/home2"
  export NIGHTWATCH_CCHANDOFF_DIR=/nonexistent
  python3 "$hook" < "$scratch/payload6.json" > "$scratch/out2" 2>"$scratch/err2"
)
[[ ! -s "$scratch/out2" ]] && ok "redact 失败 → 空输出（fail-open）" || fail "redact 失败应空输出: $(cat "$scratch/out2")"
[[ "$(ls "$scratch/home2/asks" | wc -l | tr -d ' ')" == "0" ]] && ok "redact 失败 → 不落盘（绝不写未脱敏文本）" || fail "redact 失败竟落盘了"
grep -q "redact import 失败" "$scratch/home2/errors.log" && ok "errors.log 记录失败原因" || fail "errors.log 缺记录"

echo "== 7. 脱敏：假 key 进问题 → 落盘只有 REDACTED"
fake_key="sk-AbCdEf123456789012345678"
ask_payload "{\"questions\":[{\"question\":\"key 是 $fake_key 对吗？\"}]}" "cccc2222-0000" | run_hook
grep -q "夜间守门人" "$scratch/out" && ok "含 key 的问题同样被 deny" || fail "含 key 问题未被拦"
key_file="$(grep -l 'REDACTED' "$NIGHTWATCH_HOME/asks"/*.md 2>/dev/null | head -1 || true)"
[[ -n "$key_file" ]] && ok "ask 文件含 ***REDACTED***" || fail "ask 文件未见 REDACTED"
if grep -rq "$fake_key" "$NIGHTWATCH_HOME/asks" "$NIGHTWATCH_HOME/events.jsonl"; then
  fail "🔴 原文 key 泄漏进落盘文件"
else
  ok "asks/ 与 events.jsonl 均不含原文 key"
fi
[[ -n "$key_file" ]] && { grep -q 'sk-AbCdEf\*\*\*REDACTED\*\*\*' "$key_file" && ok "脱敏保留前缀可辨识（cchandoff 同款模式）" || fail "脱敏格式异常: $(grep REDACTED "$key_file" | head -1)"; }

echo "== 8. on 过期 → 自愈 off + mode_expired 事件 + passthrough"
past=$(( $(date +%s) - 10 ))
set_mode "{\"mode\":\"on\",\"expiresAt\":$past}"
ask_payload > "$scratch/payload8.json"
run_hook < "$scratch/payload8.json"
[[ ! -s "$scratch/out" ]] && ok "过期 on → 空输出（不误拦）" || fail "过期 on 应 passthrough: $(cat "$scratch/out")"
grep -q '"mode": "off"' "$NIGHTWATCH_HOME/mode.json" && ok "mode.json 已原子翻成 off" || fail "mode.json 未自愈: $(cat "$NIGHTWATCH_HOME/mode.json")"
grep -q '"event": "mode_expired"' "$NIGHTWATCH_HOME/events.jsonl" && ok "events 记 mode_expired" || fail "events 缺 mode_expired"

echo "== 9. Notification / StopFailure → 只记事件零输出"
printf '{"hook_event_name":"Notification","session_id":"eeee4444","cwd":"/tmp/x","message":"Claude needs your permission to use Bash"}' | run_hook
[[ ! -s "$scratch/out" ]] && ok "Notification 零输出" || fail "Notification 应零输出: $(cat "$scratch/out")"
grep -q '"event": "notification"' "$NIGHTWATCH_HOME/events.jsonl" && ok "events 记 notification" || fail "events 缺 notification"
grep -q "needs your permission" "$NIGHTWATCH_HOME/events.jsonl" && ok "notification snippet 在场" || fail "notification snippet 缺失"
printf '{"hook_event_name":"StopFailure","session_id":"ffff5555","cwd":"/tmp/x","reason":"rate_limit","message":"403 余额不足"}' | run_hook
[[ ! -s "$scratch/out" ]] && ok "StopFailure 零输出" || fail "StopFailure 应零输出"
grep -q '"event": "stop_failure"' "$NIGHTWATCH_HOME/events.jsonl" && ok "events 记 stop_failure" || fail "events 缺 stop_failure"
grep -q "403 余额不足" "$NIGHTWATCH_HOME/events.jsonl" && ok "stop_failure snippet 在场" || fail "stop_failure snippet 缺失"

echo "== 10. 脏输入 → 一律 exit 0 零输出（fail-open）"
printf 'not-json{{{' | run_hook
[[ ! -s "$scratch/out" ]] && ok "非 JSON stdin → 空输出" || fail "非 JSON 应空输出"
printf '' | run_hook
[[ ! -s "$scratch/out" ]] && ok "空 stdin → 空输出" || fail "空 stdin 应空输出"
set_mode 'CORRUPTED{{{'
ask_payload | run_hook
[[ ! -s "$scratch/out" ]] && ok "mode.json 损坏 → 视为 off 空输出" || fail "mode.json 损坏应 passthrough"

echo "== 11. 并发写：8 路同时 gate 无异常"
set_mode "{\"mode\":\"on\",\"expiresAt\":$(( $(date +%s) + 3600 ))}"
rm -f "$NIGHTWATCH_HOME/events.jsonl"
for i in 1 2 3 4 5 6 7 8; do
  (
    rc=0
    ask_payload "{\"questions\":[{\"question\":\"并发题 $i\"}]}" "sid0000$i-0000" | run_hook || rc=$?
    echo "$rc" > "$scratch/rc$i"
  ) &
done
wait
bad_rc=0
for i in 1 2 3 4 5 6 7 8; do [[ "$(cat "$scratch/rc$i" 2>/dev/null || echo missing)" == "0" ]] || bad_rc=1; done
[[ "$bad_rc" == "0" ]] && ok "8 路全部 exit 0" || fail "并发出现非零退出码"
n_events="$(grep -c 'ask_denied' "$NIGHTWATCH_HOME/events.jsonl" || true)"
[[ "$n_events" == "8" ]] && ok "events 恰好 8 行 ask_denied（O_APPEND 原子）" || fail "events 应 8 行，实际 $n_events"
python3 - "$NIGHTWATCH_HOME/events.jsonl" <<'PYEOF' && ok "8 行全部是合法 JSON（无撕裂行）" || fail "events 有撕裂行"
import json, sys
bad = 0
for line in open(sys.argv[1]):
    try:
        json.loads(line)
    except Exception:
        bad += 1
sys.exit(1 if bad else 0)
PYEOF

echo
finished=1
if [[ "$fails" == "0" ]]; then
  echo "✅ test_nightwatch 全部通过"
else
  echo "❌ test_nightwatch $fails 处失败"
  exit 1
fi
