#!/usr/bin/env bash
# ccdoctor — Diagnose CCPod install/runtime version drift.

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
REPO_DIR="$(cd -P "$SCRIPT_DIR/.." && pwd)"
APP_PATH="${CCPOD_APP_PATH:-/Applications/CCPod.app}"
BUILD_APP_PATH="$REPO_DIR/menubar/build/CCPod.app"
EXEC_NAME="CCPodMenuBar"

ok() { printf '✅ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*"; }
FAILURES=0
bad() {
  printf '❌ %s\n' "$*"
  FAILURES=$((FAILURES + 1))
}

plist_value() {
  local plist="$1" key="$2"
  [[ -f "$plist" ]] || return 1
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

app_summary() {
  local label="$1" app="$2"
  local plist="$app/Contents/Info.plist"
  local bin="$app/Contents/MacOS/$EXEC_NAME"
  echo
  echo "$label"
  if [[ ! -d "$app" ]]; then
    warn "不存在: $app"
    return
  fi
  local version build commit time hash
  version="$(plist_value "$plist" CFBundleShortVersionString)"
  build="$(plist_value "$plist" CFBundleVersion)"
  commit="$(plist_value "$plist" CCPodGitCommit)"
  time="$(plist_value "$plist" CCPodBuildTime)"
  hash="$(shasum -a 256 "$bin" 2>/dev/null | awk '{print $1}')"
  echo "  path: $app"
  echo "  version: ${version:-unknown}"
  echo "  build: ${build:-unknown}"
  echo "  commit: ${commit:-unknown}"
  echo "  built: ${time:-unknown}"
  echo "  sha256: ${hash:-missing}"
}

echo "ccpod doctor"
echo
if [[ -f "$REPO_DIR/VERSION" ]]; then
  echo "VERSION: $(tr -d '[:space:]' < "$REPO_DIR/VERSION")"
else
  warn "缺少 VERSION 文件"
fi
echo "repo: $REPO_DIR"
# dirty 判定必须与 menubar/build.sh 一致（都用 status --porcelain）：
# 原来这里用 git diff --quiet，漏掉已 staged 与未跟踪文件，会把脏树报成干净
if [[ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]]; then
  echo "git: $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)-dirty"
else
  echo "git: $(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
fi

echo
echo "运行中进程"
running_pids=()
while IFS= read -r pid; do
  [[ -n "$pid" ]] && running_pids+=("$pid")
done < <(pgrep -x "$EXEC_NAME" || true)
expected_running_path="$APP_PATH/Contents/MacOS/$EXEC_NAME"
installed_build_time="$(plist_value "$APP_PATH/Contents/Info.plist" CCPodBuildTime)"
installed_build_time="${installed_build_time//$'\n'/}"
if [[ "${#running_pids[@]}" -eq 0 ]]; then
  warn "未运行 $EXEC_NAME"
else
  if [[ "${#running_pids[@]}" -gt 1 ]]; then
    bad "检测到多个 $EXEC_NAME 进程，请保留一个菜单栏 App 实例"
  fi
  for pid in "${running_pids[@]}"; do
    [[ -n "$pid" ]] || continue
    path="$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^ *//')"
    echo "  pid $pid: ${path:-unknown}"
    if [[ -n "$path" && "$path" != "$expected_running_path" ]]; then
      bad "运行中的 App 不是安装版: $path"
    fi

    # AGENTS.md:30 要求 ccdoctor 必须能检查"运行中 App"的版本/commit/build time/hash。
    # 只比路径不够：替换 .app 之后旧进程仍在跑**旧映像**，本项目历史上真出过这事
    # （用户原话"安装的和实际运行的和你设计的完全不相同"）。macOS 没法对运行中的映像取 hash，
    # 等价判据 = **进程启动时间不早于安装版的 CCPodBuildTime**：早于它就说明进程是在这次构建
    # 之前起来的，跑的必然是旧映像。etime 格式稳定（[[dd-]hh:]mm:ss），不受 locale 影响，
    # 比解析 lstart 的本地化日期可靠。
    # 注：曾试过比对进程 txt 段的 inode，但 `lsof -Fn` 只输出 p/f/n、**不含 inode**，
    # 那条判据会静默变成空值被跳过（等于没写）——别再按这个思路加回来，除非先验证 lsof 真给了 i 字段。
    if [[ -n "$path" && "$path" == "$expected_running_path" ]]; then
      elapsed="$(ps -p "$pid" -o etime= 2>/dev/null | tr -d ' ')"
      if [[ -n "$installed_build_time" && -n "$elapsed" ]]; then
        if ! python3 - "$installed_build_time" "$elapsed" <<'PYEOF'
import re, sys, datetime
bt, el = sys.argv[1], sys.argv[2]
try:
    built = datetime.datetime.strptime(bt, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc)
except Exception:
    sys.exit(0)      # build time 解析不了就不判，宁可漏报也不误报
m = re.match(r"^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$", el)
if not m:
    sys.exit(0)
d, h, mi, sec = (int(x) if x else 0 for x in m.groups())
started = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=d, hours=h, minutes=mi, seconds=sec)
sys.exit(0 if started >= built - datetime.timedelta(seconds=5) else 1)
PYEOF
        then
          bad "运行中的 App 启动于本次构建之前（build=${installed_build_time}，已运行 ${elapsed}）——跑的是旧映像，请重启"
        fi
      fi
    fi
  done
fi

app_summary "已安装 App" "$APP_PATH"
app_summary "本地构建 App" "$BUILD_APP_PATH"

echo
installed_bin="$APP_PATH/Contents/MacOS/$EXEC_NAME"
build_bin="$BUILD_APP_PATH/Contents/MacOS/$EXEC_NAME"
if [[ -f "$installed_bin" && -f "$build_bin" ]]; then
  installed_hash="$(shasum -a 256 "$installed_bin" | awk '{print $1}')"
  build_hash="$(shasum -a 256 "$build_bin" | awk '{print $1}')"
  if [[ "$installed_hash" == "$build_hash" ]]; then
    ok "安装版与 build 产物一致"
  else
    bad "安装版与 build 产物不一致，请运行: $REPO_DIR/menubar/build.sh --install"
  fi
fi

installed_version="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleShortVersionString)"
expected_version="$(tr -d '[:space:]' < "$REPO_DIR/VERSION" 2>/dev/null || true)"
if [[ -n "$expected_version" && "$installed_version" == "$expected_version" ]]; then
  ok "安装版本匹配 VERSION"
elif [[ -n "$expected_version" ]]; then
  bad "安装版本 ${installed_version:-unknown} != VERSION $expected_version"
fi

# 应用图标：缺了程序坞/通知横幅显示系统的「网格」占位图（2026-10-05 前一直如此）
icon_name="$(plist_value "$APP_PATH/Contents/Info.plist" CFBundleIconFile || true)"
if [[ -n "$icon_name" && -s "$APP_PATH/Contents/Resources/${icon_name%.icns}.icns" ]]; then
  ok "安装版带应用图标 (${icon_name%.icns}.icns)"
else
  bad "安装版缺应用图标（CFBundleIconFile=${icon_name:-无}），请运行: $REPO_DIR/menubar/build.sh --install"
fi

# 提交标签检查：安装版跑的 App 是否含当前源码。
# 为什么需要这条（2026-10-02 实测踩到）：上面三条检查只比「安装版 vs build 产物 hash」
# 和「版本 vs VERSION」，**没有一条比 commit**。当**构建早于提交**时（多会话共用工作树
# 时必然发生：构建于 23:12 的脏树，那批改动次日 10:48 才提交），安装版标签停在旧 HEAD
# `fe9a45c-dirty`，代码已前进到 `de6b4c9`，而三条检查全绿——"运行的二进制是否含最新改动"
# 无法证明却报健康。这是本项目最贵的病（构建了但跑的不是你以为的那份），必须机械拦住。
#
# 判据（第一性原理）：要问的**不是**「标签字符串等不等于 HEAD」，而是
# **「在跑的 App 含不含当前源码」**。所以标签不等时再看一步：
# 从安装版 commit 到 HEAD，`menubar/` 下有没有改动？
#   - 没有（只动了文档/脚本）→ App 不受影响，通过（否则每次文档提交都误报）
#   - 有 → 真的可能跑着旧代码，判死
# 解析不了（无 git / 标签 unknown / 该 commit 不在仓库里）时只 warn 不判死——
# 宁可漏报也不误报，与上面运行时长那条的取舍一致。
head_short="$(git -C "$REPO_DIR" rev-parse --short HEAD 2>/dev/null || true)"
installed_commit="$(plist_value "$APP_PATH/Contents/Info.plist" CCPodGitCommit || true)"
installed_commit="${installed_commit//$'\n'/}"
installed_commit_bare="${installed_commit%-dirty}"
if [[ -z "$head_short" ]]; then
  warn "读不到当前 HEAD，跳过提交标签比对"
elif [[ -z "$installed_commit" || "$installed_commit" == unknown* ]]; then
  warn "安装版无 commit 标签，跳过比对"
elif [[ "$installed_commit_bare" == "$head_short" ]]; then
  ok "安装版 commit 标签匹配 HEAD ($head_short)"
elif ! git -C "$REPO_DIR" rev-parse --verify --quiet "${installed_commit_bare}^{commit}" >/dev/null 2>&1; then
  warn "安装版 commit 标签 ${installed_commit} 在仓库里找不到对应提交，跳过比对"
elif [[ -z "$(git -C "$REPO_DIR" diff --name-only "${installed_commit_bare}..${head_short}" -- menubar/ 2>/dev/null)" ]]; then
  ok "安装版 commit ${installed_commit_bare} 落后 HEAD ${head_short}，但 menubar/ 源码无改动（不影响 App）"
else
  bad "安装版 commit 标签 ${installed_commit} 落后 HEAD ${head_short} 且 menubar/ 源码已变更——跑的不一定是这份代码，请运行: $REPO_DIR/menubar/build.sh --install"
fi

echo
echo "会话 Registry"
sessions_file="$HOME/.claude/ccpod-sessions.json"
if [[ ! -f "$sessions_file" ]]; then
  warn "不存在: $sessions_file"
else
  python3 - "$sessions_file" <<'PY'
import json
import os
import subprocess
import sys

path = sys.argv[1]
try:
    sessions = json.load(open(path, encoding="utf-8"))
except Exception as exc:
    print(f"❌ 读取失败: {exc}")
    raise SystemExit(0)

def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False

def pgid(pid):
    try:
        return subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "pgid="],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
    except Exception:
        return ""

def ppid(pid):
    try:
        out = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "ppid="],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return int(out) if out else 0
    except Exception:
        return 0

def is_orphan(pid):
    # ccgo bash 的直接父进程是 zsh/login；终端窗口被关后 zsh 死掉，
    # ccgo 被 init/launchd（pid=1）收养。所以判据就是：直接 ppid == 1。
    # 注意：不能爬整条 PPID 链——macOS GUI 进程（Ghostty 等）的 ppid 也是 1。
    return ppid(pid) == 1

orphans = []
live_ghostty = 0
for s in sessions:
    pid = s.get("pid")
    is_alive = alive(pid)
    if is_alive and s.get("terminal") == "ghostty":
        live_ghostty += 1
    status = "alive" if is_alive else "dead"
    num = s.get("num", "?")
    tty = s.get("tty", "?")
    provider = s.get("provider", "?")
    project = os.path.basename(s.get("project", "") or "?")
    group = pgid(pid) if is_alive else ""
    orphan = is_alive and is_orphan(pid)
    if orphan:
        orphans.append((num, pid, group))
        status = f"alive 🧟 orphan"
    suffix = f", pgid {group}" if group else ""
    print(f"  #{num} pid {pid} [{status}{suffix}] {tty} {provider}·{project}")

visible_ghostty = None
if live_ghostty:
    script = 'tell application "Ghostty" to count terminals'
    try:
        out = subprocess.check_output(
            ["osascript", "-e", script],
            text=True,
            stderr=subprocess.DEVNULL,
            timeout=2,
        ).strip()
        visible_ghostty = int(out)
    except Exception:
        pass

if visible_ghostty is not None:
    print(f"  Ghostty 可见 terminals: {visible_ghostty}")
    if live_ghostty > visible_ghostty:
        print(
            "⚠️  registry 中活着的 Ghostty 会话多于 UI 可见 terminal；"
            "通常是窗口关闭后留下的旧进程。可在 CCPod 关闭对应 #，"
            "或执行 kill -TERM -<pgid> 清理。"
        )

if orphans:
    print()
    print(f"🧟 检测到 {len(orphans)} 个孤儿会话（终端窗口已关，进程被 init 接管）：")
    for num, pid, group in orphans:
        print(f"  #{num} pid={pid} pgid={group}")
    print("  一键清理：")
    for _, _, group in orphans:
        if group:
            print(f"    kill -TERM -{group}")
    print("  或在 CCPod 菜单栏点击对应 # 旁的 🧟 图标。")
PY
fi

# ─── 网关静默换模型 ──────────────────────────────────────────
# CCR 对认不出的模型名（不带前缀的 claude-opus-5、已下架的 aigocode/claude-opus-5）不报错，
# 静默转给 profile 默认模型并返回 200——会话里照样显示 "Opus"（2026-10-05 实测）。
# 启动脚本已把档位钉在本管线（scripts/lib/line_models.py），这里从 CCR 账本兜底看有没有漏网的。
# 只读账本；历史事件只 warn 不判死（24 小时窗口，否则一次测试会让安装连续一天失败）。
echo
echo "网关路由"
usage_db="$HOME/.claude-code-router/app-data/usage.sqlite"
if [[ ! -f "$usage_db" ]] || ! command -v sqlite3 >/dev/null 2>&1; then
  warn "读不到 CCR 账本，跳过（$usage_db）"
else
  since="$(date -u -v-24H +%Y-%m-%dT%H:%M:%S)"
  swapped="$(sqlite3 -readonly "$usage_db" "select model || ' → ' || logical_model || '  ×' || count(*) || '  最近 ' || max(created_at)
    from usage_events where created_at >= '$since' and logical_model like '%/%' and model != 'unknown'
      and logical_model not like '%/' || model group by model, logical_model order by max(created_at) desc" 2>&1)" \
    || swapped="__ERR__ $swapped"
  if [[ "$swapped" == __ERR__* ]]; then
    warn "查 CCR 账本失败：${swapped#__ERR__ }"
  elif [[ -n "$swapped" ]]; then
    warn "近 24 小时有请求被网关换成了别的模型（请求的 → 实际用的）："
    sed 's/^/     /' <<<"$swapped"
  else
    ok "近 24 小时没有请求被网关静默换模型"
  fi
fi

# ─── 模型清单对账 ────────────────────────────────────────────
# 2026-10-05 事故：yescode 的 Fable 5.1 一直能用却没人用上——网关里的模型清单是手抄的，上游上新没人对账；
# 反过来清单里也躺着从没通过的名字（key 白名单没放行）。两头都只读、只 warn：
#  ① 清单里近 7 天从没返回过 200 的模型（管线文件 × CCR 账本，本机就能算）；
#  ② 上游已有、清单里还没有的同系列新模型（读菜单栏 App 每轮留下的记录；ccdoctor 自己不联网、不碰密钥）；
#  ③ 自动上架的进展（读 App 的状态文件）：被上游拒绝的、没测出结果的、已加入清单但路由还没确认的。
echo
echo "模型清单对账"
onboard_record="${CCPOD_MODEL_ONBOARD_RECORD:-$HOME/.claude/ccpod-model-onboard-round.json}"
onboard_providers="${CCPOD_PROVIDERS_DIR:-$HOME/.claude/providers}"
onboard_state="${CCPOD_MODEL_ONBOARD_STATE:-$HOME/.claude/ccpod-model-onboard.json}"
python3 - "$onboard_providers" "${CCPOD_CCR_USAGE_DB:-$HOME/.claude-code-router/app-data/usage.sqlite}" "$onboard_record" "$onboard_state" <<'ONBOARD_PY' || warn "模型清单对账没跑成（见上面的报错）"
import datetime, glob, json, os, sqlite3, sys
providers_dir, usage_db, record, state_path = sys.argv[1:5]
ok = lambda m: print("✅ " + m)
warn = lambda m: print("⚠️  " + m)

# ① 清单里从没通过的
lines = {}
for path in sorted(glob.glob(os.path.join(providers_dir, "*.json"))):
    try:
        data = json.load(open(path))
    except Exception:
        continue
    if data.get("source") == "gateway" and isinstance(data.get("gateway_models"), list):
        lines[str(data.get("gateway_provider"))] = [str(m) for m in data["gateway_models"]]
if not os.path.isdir(providers_dir):
    warn(f"读不到线路目录，跳过（{providers_dir}）")
elif not lines:
    warn(f"没有找到网关管线文件，跳过（{providers_dir}）")
elif not os.path.isfile(usage_db):
    warn(f"读不到 CCR 账本，跳过「从没通过的模型」（{usage_db}）")
else:
    since = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=7)).strftime("%Y-%m-%dT%H:%M:%S")
    try:
        con = sqlite3.connect(f"file:{usage_db}?mode=ro", uri=True, timeout=2)
        alive = {r[0] for r in con.execute(
            "select distinct logical_model from usage_events where status_code = 200 and created_at >= ?", (since,))}
        con.close()
    except Exception as e:
        alive = None
        warn(f"查 CCR 账本失败：{e}")
    if alive is not None:
        dead = [(p, m) for p, models in sorted(lines.items()) for m in models if f"{p}/{m}" not in alive]
        total = sum(len(v) for v in lines.values())
        if dead:
            warn(f"清单里有 {len(dead)}/{total} 个模型近 7 天从没返回过 200（可能是上游没放行，也可能只是没人用过）：")
            for p, m in dead:
                print(f"     {p}/{m}")
        else:
            ok(f"清单里的 {total} 个模型近 7 天都返回过 200")

# ② 上游有、清单里没有的同系列新模型
if not os.path.isfile(record):
    warn(f"新模型检查还没有跑过（没有记录文件 {record}；菜单栏 App 启动约 10 分钟后会跑第一轮）")
else:
    try:
        data = json.load(open(record))
        at = datetime.datetime.fromisoformat(str(data["at"]).replace("Z", "+00:00"))
        rows = data["lines"]
    except Exception as e:
        warn(f"新模型检查的记录读不懂（{record}）：{e}")
    else:
        age_h = (datetime.datetime.now(datetime.timezone.utc) - at).total_seconds() / 3600
        when = f"{at.astimezone().strftime('%m-%d %H:%M')}（{age_h:.0f} 小时前）"
        if data.get("failure"):
            warn(f"上一轮新模型检查没做成（{when}）：{data['failure']}")
        else:
            found = [(r.get("provider"), m) for r in rows for m in r.get("candidates") or []]
            failed = [(r.get("provider"), r.get("error")) for r in rows if r.get("error")]
            if found:
                warn(f"上游有 {len(found)} 个同系列新模型还没上架（{when} 的检查）：")
                for p, m in found:
                    print(f"     {p}/{m}")
            else:
                ok(f"上游没有发现比清单更新的同系列模型（{when} 检查了 {len(rows)} 条线路）")
            for p, e in failed:
                warn(f"{p} 的上游模型目录没拉到：{e}")
            if data.get("aborted"):
                warn(f"上一轮新模型实测中止（本机问题，不是模型的问题）：{data['aborted']}")
            if data.get("mode") == "dry-run":
                would = [f"{w.get('provider')}/{w.get('model')}" for w in data.get("would_write") or []]
                warn("自动上架正处于干跑：照常实测，但不写网关" + (f"；本应上架 {'、'.join(would)}" if would else "")
                     + "（关掉：defaults delete com.ccpod.menubar modelOnboardDryRun）")
            elif data.get("mode") == "discover-only":
                warn("自动上架已关闭，只发现不上架（打开：defaults delete com.ccpod.menubar modelOnboardDisabled）")
            if age_h > 24:
                warn(f"新模型检查的记录已经 {age_h:.0f} 小时没更新（正常每 6 小时一轮）")

# ③ 自动上架的进展
if not os.path.isfile(state_path):
    ok(f"自动上架还没有实测过任何新模型（没有状态文件 {state_path}）")
else:
    try:
        entries = json.load(open(state_path))["entries"]
        if not isinstance(entries, dict):
            raise ValueError("entries 不是对象")
    except Exception as e:
        warn(f"自动上架的状态文件读不懂（{state_path}）：{e}——App 在它修好之前不会再实测、不会上架")
    else:
        now = datetime.datetime.now().timestamp()
        def retry(e):
            left = float(e.get("nextRetryAt") or 0) - now
            return "下一轮再试" if left <= 0 else (f"{left / 86400:.0f} 天后再试" if left >= 86400 else f"{max(1, left / 3600):.0f} 小时后再试")
        groups = {}
        for key, e in sorted(entries.items()):
            groups.setdefault(e.get("state"), []).append((key, e))
        for key, e in groups.get("unconfirmed", []):
            warn(f"{key} 已加入清单但路由未确认（没有回滚）：{e.get('note') or ''}")
        for key, e in groups.get("approved", []):
            warn(f"{key} 直连实测已通过，还没写进清单（干跑中，或今天的写入次数用完了）")
        for key, e in groups.get("rejected", []):
            note = " ".join(str(e.get("note") or "").split())[:300]
            warn(f"{key} 被上游拒绝（{e.get('lastStatus')}，第 {e.get('hardFails')} 次），{retry(e)}" + (f"：{note}" if note else ""))
        for key, e in groups.get("unsure", []):
            warn(f"{key} 没测出结果（{e.get('note') or '原因未知'}），{retry(e)}")
        for key, e in groups.get("removed", []):
            print(f"     {key} 上架后被删掉过，不再自动加回")
        done = [k for k, _ in groups.get("listed", [])]
        if done:
            ok(f"自动上架并确认了 {len(done)} 个新模型：{'、'.join(done)}")
        if not entries:
            ok("自动上架的状态文件是空的（还没有候选被实测过）")

# ④ 网关自带的「自动拉模型」：开着会绕过自动上架的实测（只增不删、不实测就并进清单）
try:
    from urllib.parse import urlparse, parse_qs
    import urllib.request
    svc = json.load(open(os.path.expanduser("~/.claude-code-router/service.json")))
    pu = urlparse(svc["url"])
    origin = f"{pu.scheme}://{pu.hostname}:{pu.port}"
    token = parse_qs(pu.query)["ccr_web_token"][0]
    req = urllib.request.Request(origin + "/api/ccr/rpc",
        data=json.dumps({"method": "getConfig", "args": []}).encode(),
        headers={"content-type": "application/json", "x-ccr-web-auth": token})
    cfg = json.load(urllib.request.urlopen(req, timeout=10)).get("value", {})
    flags = ("autoFetchModels", "autoRefreshModels", "autoFetchKnownModels", "autoRefreshKnownModels")
    opened = []
    for pr in cfg.get("Providers", []) or []:
        on = [f for f in flags if pr.get(f)]
        if on:
            opened.append(f"{pr.get('name')}（{'、'.join(on)}）")
    if opened:
        warn("网关自带的「自动拉模型」开着（" + "；".join(opened)
             + "）——它不实测就把上游新模型全加进清单，会绕过自动上架的实测，建议在网关控制台关掉")
    else:
        ok("网关自带的「自动拉模型」都是关着的")
except Exception as e:
    warn(f"读不到网关配置，没法检查「自动拉模型」开关（{e}）——不确定是否开着，不当通过")
ONBOARD_PY

# ─── 密钥卫生 ────────────────────────────────────────────────
# ccpod 是要发布给别人用的，所以"密钥落在哪、权限多宽"必须能被用户自己一键查出来。
# 判据：任何**含明文密钥**的文件必须 600/400，存放它们的目录必须 700。
# 正则含 sk-/ark-/cr_ 三种已知前缀；注意正则只能覆盖已知形状，字段级判据见 ccpod-key doctor。
# 宽权限意味着本机其他用户或任意进程都能把 key 读走（实测抓到过一个 644 的 provider json）。
echo
echo "密钥卫生"
secret_files=0
secret_bad=0
scan_secret_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  grep -aqE 'sk-[A-Za-z0-9_-]{12,}|ark-[a-f0-9-]{16,}|cr_[A-Za-z0-9]{16,}' "$f" 2>/dev/null || return 0
  secret_files=$((secret_files + 1))
  local perm
  perm="$(stat -f '%Lp' "$f" 2>/dev/null)"
  case "$perm" in
    600|400) return 0 ;;
    *) bad "含明文密钥但权限过宽（${perm}，应为 600）: $f"
       secret_bad=$((secret_bad + 1)) ;;
  esac
}
for f in "$HOME"/.claude/providers/*.json "$HOME"/.ccpod/*.json "$HOME"/.ccpod/*.log \
         "$HOME"/.ccpod/*.jsonl "$HOME"/.claude-code-router/config.sqlite; do
  scan_secret_file "$f"
done
for d in "$HOME/.claude/providers" "$HOME/.ccpod"; do
  [[ -d "$d" ]] || continue
  perm="$(stat -f '%Lp' "$d" 2>/dev/null)"
  if [[ "$perm" != "700" ]]; then
    bad "凭证目录权限过宽（${perm}，应为 700）: $d"
    secret_bad=$((secret_bad + 1))
  fi
done
if [[ "$secret_bad" -eq 0 ]]; then
  ok "含明文密钥的 $secret_files 个文件权限均为 600，凭证目录均为 700"
fi

# ─── 保持唤醒（可选功能）────────────────────────────────────────
# 未授权安装是合法状态（功能可选），只提示不计 FAILURES；
# 装了一半（helper 在但 sudoers 缺/看门狗没加载）才算问题。
echo
echo "保持唤醒"
SLEEP_HELPER=/usr/local/libexec/ccpod-sleep-switch
SLEEP_SUDOERS=/etc/sudoers.d/ccpod-sleep-switch
SLEEP_AGENT=com.ccpod.sleep-switch-watchdog
if [[ ! -e "$SLEEP_HELPER" && ! -e "$SLEEP_SUDOERS" ]]; then
  ok "未授权安装（可选功能，菜单栏 App 内可一键授权）"
else
  [[ -x "$SLEEP_HELPER" ]] || bad "helper 缺失或不可执行: $SLEEP_HELPER"
  [[ -f "$SLEEP_SUDOERS" ]] || bad "sudoers 规则缺失: $SLEEP_SUDOERS"
  if sleep_status="$(sudo -n "$SLEEP_HELPER" status 2>/dev/null)"; then
    [[ "$sleep_status" =~ ^[01]$ ]] || bad "helper status 输出异常: $sleep_status"
  else
    bad "sudo -n helper status 失败（sudoers 可能失效），修复: sudo $REPO_DIR/scripts/sleep-switch/provision-sleep-switch.sh install"
  fi
  if launchctl print "gui/$(id -u)/$SLEEP_AGENT" >/dev/null 2>&1; then
    ok "helper/sudoers/看门狗齐备，当前 SleepDisabled=${sleep_status:-未知}"
  else
    bad "看门狗 LaunchAgent 未加载，修复: sudo $REPO_DIR/scripts/sleep-switch/provision-sleep-switch.sh install"
  fi
fi

if [[ "$FAILURES" -gt 0 ]]; then
  echo
  printf '❌ ccdoctor 发现 %s 个安装/运行一致性问题\n' "$FAILURES"
  exit 1
fi
