#!/usr/bin/env bash
# ccmodel-probe.py 的隔离与超时：全程用假的 claude 桩，不发任何真实请求。
set -euo pipefail
repo="$(cd "$(dirname "$0")/../.." && pwd)"
probe="$repo/scripts/ccmodel-probe.py"
[[ -x "$probe" ]] || { echo "FAIL 找不到可执行的 $probe"; exit 1; }
scratch="$(mktemp -d)"
# macOS 自带的 bash 3.2：只要挂了 EXIT 钩子，脚本因 set -u（引用了没定义的变量）崩掉时退出码是 0，
# 在钩子里读 $? 也是 0（2026-10-05 用三行脚本复现过）。所以用「跑到了最后」的标记来判，不信退出码。
finished=0
trap 'rm -rf "$scratch"; if [[ "$finished" != 1 ]]; then echo "FAIL 测试脚本中途退出，没有跑完"; exit 1; fi' EXIT
fails=0
check() {  # check <说明> <python 表达式，变量 d = 解析后的输出>
  if python3 -c "import json,os,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if ($2) else 1)" "$scratch/out.json"; then
    echo "  ok   $1"
  else
    echo "  FAIL $1 —— 输出: $(cut -c1-300 "$scratch/out.json")"; fails=$((fails + 1))
  fi
}

# 桩 1：把自己看到的环境、工作目录、参数记到旁边的文件里（并故意把 key 回显一遍）。
# 用 bash 写：/usr/bin/python3 是 Xcode 的转发壳，会往自己环境里塞 CPATH/SDKROOT 等，看不出调用方到底给了什么。
cat > "$scratch/claude-echo" <<'STUB'
#!/bin/bash
side="$(dirname "$0")"
compgen -e | grep -v -x -e _ -e PWD -e SHLVL -e OLDPWD | sort > "$side/seen-env"   # 去掉 bash 自己加的
pwd -P > "$side/seen-cwd"
printf '%s\n' "$CLAUDE_CONFIG_DIR" > "$side/seen-config"
printf '%s\n' "$@" > "$side/seen-args"
[ -t 0 ] && echo tty > "$side/seen-stdin" || echo notty > "$side/seen-stdin"
printf '%s|%s\n' "$CLAUDE_CODE_MAX_RETRIES" "$ANTHROPIC_BASE_URL" > "$side/seen-misc"
printf '{"is_error": false, "result": "ok key=%s"}\n' "$ANTHROPIC_API_KEY"
STUB
# 桩 2：卡住不动（并再起一个子进程），用来测超时连进程组一起杀
cat > "$scratch/claude-hang" <<'STUB'
#!/bin/bash
echo $$ > "$CLAUDE_CONFIG_DIR/../hang.pid" 2>/dev/null || true
sleep 300 &
echo $! > "$(dirname "$0")/hang-child.pid"
sleep 300
STUB
# 桩 3：上游拒绝的形态（2026-10-05 实测 yescode/claude-fable-5：rc=1、is_error=true、api_error_status=403）
cat > "$scratch/claude-403" <<'STUB'
#!/bin/bash
echo '{"type":"result","is_error":true,"api_error_status":403,"result":"API Error: 403 model not allowed. Allowed models: claude-fable-5-1, claude-opus-5-5"}'
exit 1
STUB
chmod +x "$scratch"/claude-*

echo "— 隔离 —"
CCPOD_SESSION_NUM=999 CLAUDE_CODE_SESSION_ID=leak ANTHROPIC_AUTH_TOKEN=leak CCPOD_PROBE_API_KEY=sk-test-SECRETSECRET1234 \
  "$probe" --base-url https://up.example/api --model demo-5-5 --claude "$scratch/claude-echo" > "$scratch/out.json"
check "退出码 0、rc=0、没超时、没有本机错误" "d['rc']==0 and d['timed_out'] is False and d['local_error'] is None"
seen() { cat "$scratch/seen-$1"; }
same() {  # same <说明> <实际> <期望>
  if [[ "$2" == "$3" ]]; then echo "  ok   $1"; else echo "  FAIL $1 —— 实际: $2"; fails=$((fails + 1)); fi
}
same "子进程只看到 6 个白名单变量" "$(seen env | tr '\n' ' ')" "ANTHROPIC_API_KEY ANTHROPIC_BASE_URL CLAUDE_CODE_MAX_RETRIES CLAUDE_CONFIG_DIR HOME PATH "
if grep -q -x -e CCPOD_SESSION_NUM -e CLAUDE_CODE_SESSION_ID -e ANTHROPIC_AUTH_TOKEN "$scratch/seen-env"; then
  echo "  FAIL 调用方的会话变量漏进去了: $(seen env | tr '\n' ' ')"; fails=$((fails + 1))
else echo "  ok   调用方的会话变量没漏进去（CCPOD_SESSION_NUM / CLAUDE_CODE_SESSION_ID / ANTHROPIC_AUTH_TOKEN）"; fi
config="$(seen config)"
case "$config" in *ccmodel-probe.*) echo "  ok   配置目录是一次性的临时目录（${config}）" ;; *) echo "  FAIL 配置目录不是临时目录: $config"; fails=$((fails + 1)) ;; esac
case "$config" in "$HOME/.claude"*) echo "  FAIL 配置目录落在了 ~/.claude 下: $config"; fails=$((fails + 1)) ;; *) echo "  ok   配置目录不在 ~/.claude 下" ;; esac
same "工作目录就是那个临时目录" "$(seen cwd)" "$(cd "$(dirname "$config")" && pwd -P)/$(basename "$config")"
if [[ -n "$config" && ! -e "$config" ]]; then echo "  ok   用完之后临时目录已删除"; else echo "  FAIL 临时目录还在: $config"; fails=$((fails + 1)); fi
same "重试关掉、地址原样传入" "$(seen misc)" "0|https://up.example/api"
same "参数形态" "$(seen args | tr '\n' '~')" "-p~--bare~--model~demo-5-5~--no-session-persistence~--tools~~--output-format~json~只回复 ok~"
same "标准输入不是终端" "$(seen stdin)" "notty"
check "key 被桩回显了也不出现在输出里（替换成 ***）" "'SECRETSECRET' not in open(sys.argv[1]).read() and 'key=***' in d['stdout']"

echo "— 上游拒绝的形态原样带回 —"
CCPOD_PROBE_API_KEY=k "$probe" --base-url https://up.example --model m --claude "$scratch/claude-403" > "$scratch/out.json"
check "rc=1 且 stdout 里有 api_error_status 403 和 Allowed models" "d['rc']==1 and json.loads(d['stdout'])['api_error_status']==403 and 'Allowed models' in d['stdout']"

echo "— 超时 —"
started=$(date +%s)
CCPOD_PROBE_API_KEY=k "$probe" --base-url https://up.example --model m --claude "$scratch/claude-hang" --timeout 2 > "$scratch/out.json"
elapsed=$(( $(date +%s) - started ))
check "超时如实标记 timed_out=true" "d['timed_out'] is True"
if [[ "$elapsed" -le 15 ]]; then echo "  ok   2 秒超时在 ${elapsed} 秒内返回（没有等满 300 秒）"; else echo "  FAIL 超时没生效，等了 ${elapsed} 秒"; fails=$((fails + 1)); fi
child="$(cat "$scratch/hang-child.pid" 2>/dev/null || true)"
if [[ -z "$child" ]]; then echo "  FAIL 桩没有记下子进程号，这条检查没法做"; fails=$((fails + 1))
elif kill -0 "$child" 2>/dev/null; then echo "  FAIL 桩起的子进程 $child 还活着（进程组没杀干净）"; kill -9 "$child" 2>/dev/null || true; fails=$((fails + 1))
else echo "  ok   桩起的子进程 $child 也被一起杀掉了"; fi
if compgen -G "${TMPDIR:-/tmp}/ccmodel-probe.*" >/dev/null; then echo "  FAIL 超时后留下了临时目录: $(compgen -G "${TMPDIR:-/tmp}/ccmodel-probe.*" | head -3)"; fails=$((fails + 1)); else echo "  ok   超时后没有留下临时目录"; fi

echo "— SIGTERM：脚本自己收 SIGTERM 也要杀干净 + 删临时目录 —"
rm -f "$scratch/hang-child.pid"
CCPOD_PROBE_API_KEY=k "$probe" --base-url https://up.example --model m --claude "$scratch/claude-hang" --timeout 30 > "$scratch/sigterm-out.json" 2>/dev/null &
probe_pid=$!
child=""
for _ in $(seq 1 100); do
  if [[ -s "$scratch/hang-child.pid" ]]; then child="$(cat "$scratch/hang-child.pid")"; [[ -n "$child" ]] && break; fi
  sleep 0.1
done
if [[ -z "$child" ]]; then
  echo "  FAIL 桩没起来，SIGTERM 测试没法做"; fails=$((fails + 1))
else
  kill -TERM "$probe_pid" 2>/dev/null
  wait "$probe_pid" 2>/dev/null || true   # probe 被 SIGTERM 后退出码 143，set -e 下不能让它把测试脚本带崩
  if kill -0 "$child" 2>/dev/null; then
    echo "  FAIL SIGTERM 后桩子进程 $child 还活着（进程组没杀干净）"; kill -9 "$child" 2>/dev/null || true; fails=$((fails + 1))
  else
    echo "  ok   SIGTERM 后桩子进程 $child 已死"
  fi
  if compgen -G "${TMPDIR:-/tmp}/ccmodel-probe.*" >/dev/null; then echo "  FAIL SIGTERM 后留下临时目录: $(compgen -G "${TMPDIR:-/tmp}/ccmodel-probe.*" | head -3)"; fails=$((fails + 1)); else echo "  ok   SIGTERM 后没留下临时目录"; fi
fi

echo "— 本机问题 —"
set +e
env -u CCPOD_PROBE_API_KEY "$probe" --base-url https://up.example --model m --claude "$scratch/claude-echo" > "$scratch/out.json"; code=$?
set -e
check "没给 key → local_error 明说" "'没有给 key' in (d['local_error'] or '')"
if [[ "$code" -eq 3 ]]; then echo "  ok   没给 key → 退出码 3"; else echo "  FAIL 没给 key 的退出码是 ${code}（应为 3）"; fails=$((fails + 1)); fi
if [[ -e /opt/homebrew/bin/claude || -e /usr/local/bin/claude ]]; then
  echo "  SKIP 「找不到 claude」这条没测：系统目录里装着 claude，没法造出找不到的环境"
else
  mkdir -p "$scratch/emptyhome"
  set +e
  env -i HOME="$scratch/emptyhome" PATH=/usr/bin:/bin CCPOD_PROBE_API_KEY=k python3 "$probe" --base-url https://up.example --model m > "$scratch/out.json"; code=$?
  set -e
  check "空的 HOME 和最小 PATH → local_error 说找不到 claude" "'找不到 claude' in (d['local_error'] or '')"
  if [[ "$code" -eq 3 ]]; then echo "  ok   找不到 claude → 退出码 3"; else echo "  FAIL 找不到 claude 的退出码是 ${code}（应为 3）"; fails=$((fails + 1)); fi
fi

finished=1
if [[ "$fails" -eq 0 ]]; then echo "ccmodel_probe: 全部通过"; else echo "ccmodel_probe: $fails 项失败"; exit 1; fi
