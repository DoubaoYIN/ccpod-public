#!/usr/bin/env python3
"""ccmodel-probe — 用真实 Claude Code 客户端对「某个地址上的某个模型」发一次最小请求，如实报告结果。

菜单栏 App 的「新模型自动上架」每轮调它；人也可以在终端用同一条路径手动复现：

    CCPOD_PROBE_API_KEY=<key> scripts/ccmodel-probe.py --base-url <线路地址> --model <模型名>

输出恒为一行 JSON：
    {"local_error": null, "rc": 0, "timed_out": false, "seconds": 3.4, "claude": "/…/claude", "stdout": "<claude 的 json 输出>"}
本机问题（找不到 claude、没给 key、临时目录建不了）→ local_error 有内容、退出码 3；
其余情况退出码 0（claude 自己成功与否看 rc 和 stdout，由调用方判定）。

为什么必须隔离（2026-10-05 实测，PITFALLS #45）：
  - 不给一次性的 CLAUDE_CONFIG_DIR，~/.claude/settings.json 的 env 块会把 ANTHROPIC_BASE_URL 盖回本机网关：
    上游的 key 被送去网关、401、默认重试 11 次，看起来像卡死；
  - 被杀时还会在全局 ~/.claude/sessions 里留一个一直「忙碌」的会话文件。
所以：env 只留白名单、配置目录用完即删、重试关掉、超时就连进程组一起杀。

key 只从环境变量 CCPOD_PROBE_API_KEY 读（不走命令行参数，ps 里看不到），不写进任何输出。
"""
import argparse
import glob
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

PROMPT = "只回复 ok"
STDOUT_LIMIT = 20000


def find_claude(explicit):
    """图形程序的 PATH 里通常没有 claude（装在 nvm / homebrew 下），所以自己找。"""
    candidates = [explicit, os.environ.get("CCPOD_CLAUDE_BIN"), shutil.which("claude")]
    home = os.path.expanduser("~")
    candidates += [os.path.join(home, ".local/bin/claude"), os.path.join(home, ".claude/local/claude"),
                   "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
                   os.path.join(home, ".bun/bin/claude"), os.path.join(home, ".volta/bin/claude")]

    def version(path):
        return [int(n) for n in re.findall(r"[0-9]+", path.split("/versions/node/")[-1].split("/")[0])]
    candidates += sorted(glob.glob(os.path.join(home, ".nvm/versions/node/*/bin/claude")), key=version, reverse=True)
    for path in candidates:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return os.path.abspath(path)
    return None


def emit(payload, code):
    print(json.dumps(payload, ensure_ascii=False))
    sys.exit(code)


def main():
    parser = argparse.ArgumentParser(description="用真实 Claude Code 客户端发一次最小请求")
    parser.add_argument("--base-url", required=True, help="ANTHROPIC_BASE_URL：线路自己的地址，或本机网关地址")
    parser.add_argument("--model", required=True, help="模型名（直连上游用裸名；经网关用 线路/模型）")
    parser.add_argument("--timeout", type=float, default=60)
    parser.add_argument("--claude", help="claude 可执行文件路径（默认自动找）")
    args = parser.parse_args()
    base = {"local_error": None, "rc": None, "timed_out": False, "seconds": 0.0, "claude": None, "stdout": ""}

    key = os.environ.get("CCPOD_PROBE_API_KEY", "").strip()
    if not key:
        emit({**base, "local_error": "没有给 key（环境变量 CCPOD_PROBE_API_KEY 为空）"}, 3)
    claude = find_claude(args.claude)
    if not claude:
        emit({**base, "local_error": "找不到 claude 可执行文件（可用 --claude 或环境变量 CCPOD_CLAUDE_BIN 指定）"}, 3)
    base["claude"] = claude
    try:
        config_dir = tempfile.mkdtemp(prefix="ccmodel-probe.")
    except OSError as e:
        emit({**base, "local_error": f"临时目录建不了：{e}"}, 3)

    # 只给白名单里的变量：调用方环境里的会话编号、网关地址、别的 key 一个都不带进去
    env = {
        "HOME": os.path.expanduser("~"),
        "PATH": os.path.dirname(claude) + ":/usr/bin:/bin",
        "CLAUDE_CONFIG_DIR": config_dir,
        "CLAUDE_CODE_MAX_RETRIES": "0",
        "ANTHROPIC_BASE_URL": args.base_url,
        "ANTHROPIC_API_KEY": key,
    }
    command = [claude, "-p", "--bare", "--model", args.model, "--no-session-persistence",
               "--tools", "", "--output-format", "json", PROMPT]
    started = time.time()
    process = None

    def _terminate(signum, frame):
        # 抛 SystemExit 让 finally 跑起来：杀掉 claude 进程组 + 删临时目录（P2-4，否则被 SIGTERM 时会漏清理）
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)
    try:
        process = subprocess.Popen(command, env=env, cwd=config_dir, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                   start_new_session=True)
        try:
            out, _ = process.communicate(timeout=args.timeout)
        except subprocess.TimeoutExpired:
            base["timed_out"] = True
            try:
                os.killpg(process.pid, signal.SIGKILL)   # 连它起的子进程一起杀
            except OSError:
                pass
            out, _ = process.communicate()
        text = out.decode("utf-8", errors="replace")[:STDOUT_LIMIT].replace(key, "***")
        emit({**base, "rc": process.returncode, "seconds": round(time.time() - started, 1), "stdout": text}, 0)
    except OSError as e:
        emit({**base, "local_error": f"claude 起不来：{e}"}, 3)
    finally:
        if process is not None and process.poll() is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except OSError:
                pass
        shutil.rmtree(config_dir, ignore_errors=True)


if __name__ == "__main__":
    main()
