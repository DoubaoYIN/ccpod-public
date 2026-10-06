#!/usr/bin/env bash
# ccpod-key — 线路密钥保险柜
#
# 为什么要它：ccpod 要发布给别人用。如果加一条线路 = 把 api_key 明文写进
# ~/.claude/providers/<line>.json，那么这份明文会跟着备份、同步、截图、误提交一起出去，
# 而且文件权限稍微宽一点（实测抓到过 644）本机任何进程都能读走。
#
# 这个工具把 key 放进 macOS 钥匙串，配置文件里只留一行"去钥匙串取"的引用（${exec}）。
# 约定与 scripts/lib/common.sh 的 get_provider_env、菜单栏的 SecretResolver 完全一致。
set -euo pipefail

usage() {
  cat <<'EOF'
ccpod-key — 线路密钥保险柜（key 进钥匙串，配置文件只留 $exec 引用）

用法:
  ccpod-key set <线路名>        把某条线路的 key 存进钥匙串（静默输入，不回显）
  ccpod-key use <线路名>        把该线路 json 里已有的明文 key 搬进钥匙串，并改成 ${exec}（幂等）
  ccpod-key list                列出钥匙串里 ccpod-* 条目（只显示名字，绝不显示值）
  ccpod-key doctor              扫所有配置文件，报告还有哪些地方躺着明文 key

说明:
  · 钥匙串条目名: ccpod-line-<线路名>（管理密钥用 -mgmt 后缀）
  · 搬家是幂等的：已经是 $exec 的不会重复搬
  · 全程不打印 key，只显示指纹（sha256 前 12 位）供你核对
EOF
}

case "${1:-}" in
  ""|-h|--help) usage; exit 0 ;;
  set|use|list|doctor) ;;
  *) usage; exit 1 ;;
esac

python3 - "$@" <<'PYEOF'
import hashlib
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
PROV_DIR = os.path.join(HOME, ".claude", "providers")
CCPOD_DIR = os.path.join(HOME, ".ccpod")
USER = os.environ.get("USER", "")
KEY_FIELDS = ("ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "MANAGEMENT_API_KEY")
# ⚠️ 正则只能覆盖"已知形状"的密钥，实测漏过 cr_ 前缀（Yescode 那把 67 字符的明文
# 因此躲过了搬家与三个 doctor，"0 明文"的结论是假的）。所以对 **JSON 配置文件**改用
# 字段判据：凭据形状的字段里只要是字面量字符串就算明文，不管它长什么样。
SECRET_RE = re.compile(
    r"sk-[A-Za-z0-9_\-]{12,}|ark-[a-f0-9\-]{16,}|cr_[A-Za-z0-9]{16,}"
    r"|Bearer\s+[A-Za-z0-9_\-.]{16,}")
CRED_FIELD_RE = re.compile(r"(api[_-]?key|auth[_-]?token|access[_-]?token|secret|password)", re.I)


def find_literal_credentials(obj, path=""):
    """递归找出"凭据形状的字段 + 字面量值"，与密钥前缀无关"""
    out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            here = f"{path}/{k}" if path else k
            if isinstance(v, str) and len(v) >= 16 and CRED_FIELD_RE.search(k):
                out.append(here)
            else:
                out += find_literal_credentials(v, here)
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            out += find_literal_credentials(v, f"{path}[{i}]")
    return out


def die(msg, code=1):
    print(msg, file=sys.stderr)
    sys.exit(code)


def fingerprint(secret):
    return hashlib.sha256(secret.encode()).hexdigest()[:12]


def keychain_set(service, secret):
    r = subprocess.run(
        ["security", "add-generic-password", "-a", USER, "-s", service,
         "-w", secret, "-U", "-T", "/usr/bin/security"],
        capture_output=True, text=True)
    if r.returncode != 0:
        die(f"❌ 写钥匙串失败（{service}）: {r.stderr.strip()}")


def keychain_get(service):
    r = subprocess.run(["security", "find-generic-password", "-a", USER, "-s", service, "-w"],
                       capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else None


def exec_ref(service):
    """与 common.sh / SecretResolver 同一套写法：sh -c 展开 ${USER}，失败输出空"""
    # 不带 -a "$USER"：GUI/launchd 启动的进程环境里 USER 可能不存在，
    # 那时 security 会静默取不到 → 线路无声失效。服务名 ccpod-* 已足够唯一，
    # 而每个用户有各自的 login keychain，不会串号。
    return {"$exec": f'security find-generic-password -s {service} -w 2>/dev/null'}


def save(path, obj):
    with open(path, "w") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.chmod(path, 0o600)


def service_for(line, field):
    return f"ccpod-line-{line}" + ("-mgmt" if field == "MANAGEMENT_API_KEY" else "")


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception as exc:
        die(f"❌ 读不了 {path}: {exc}")


def cmd_set(line):
    """静默读入 key → 写钥匙串 → 确保 json 用 $exec 引用它"""
    import getpass
    path = os.path.join(PROV_DIR, f"{line}.json")
    obj = read_json(path) if os.path.exists(path) else {"env": {}}
    secret = getpass.getpass(f"粘贴 {line} 的 api_key（输入不回显）: ").strip()
    if not secret:
        die("❌ 没输入内容")
    service = service_for(line, "ANTHROPIC_API_KEY")
    keychain_set(service, secret)
    if keychain_get(service) != secret:
        die("❌ 钥匙串回读不一致，已中止（配置文件未改动）")
    env = obj.setdefault("env", {})
    field = "ANTHROPIC_AUTH_TOKEN" if "ANTHROPIC_AUTH_TOKEN" in env else "ANTHROPIC_API_KEY"
    env[field] = exec_ref(service)
    save(path, obj)
    print(f"✅ {line}: key 已进钥匙串（{service}，指纹 {fingerprint(secret)}）")
    print(f"   {path} 里的 {field} 现在只是引用，不含明文")


def cmd_use(line):
    """把 json 里已有的明文 key 搬进钥匙串（幂等）"""
    path = os.path.join(PROV_DIR, f"{line}.json")
    if not os.path.exists(path):
        die(f"❌ 没有这条线路: {path}")
    obj = read_json(path)
    env = obj.get("env") or {}
    moved = 0
    for field in KEY_FIELDS:
        value = env.get(field)
        if not isinstance(value, str) or not value:
            continue                      # 已经是 $exec 或没有这个字段
        service = service_for(line, field)
        keychain_set(service, value)
        if keychain_get(service) != value:
            die(f"❌ {field} 钥匙串回读不一致，已中止（配置文件未改动）")
        env[field] = exec_ref(service)
        moved += 1
        print(f"  ✅ {field} → 钥匙串 {service}（指纹 {fingerprint(value)}）")
    if not moved:
        print(f"ℹ️  {line} 没有明文 key 需要搬（可能已经是 ${exec}）")
        return
    obj["env"] = env
    save(path, obj)
    if SECRET_RE.search(open(path, encoding="utf-8").read()):
        die(f"❌ 搬完后 {path} 里仍有明文，请人工检查")
    print(f"✅ {line}: 搬走 {moved} 把，文件里已无明文")


def cmd_list():
    out = subprocess.run(["security", "dump-keychain"], capture_output=True, text=True).stdout
    names = sorted({m.group(1) for m in re.finditer(r'"svce"<blob>="(ccpod-[^"]+)"', out)})
    if not names:
        print("（钥匙串里没有 ccpod-* 条目）")
        return
    print(f"钥匙串里的 ccpod 条目（共 {len(names)} 个，只显示名字）:")
    for name in names:
        value = keychain_get(name) or ""
        print(f"  {name:<32} 指纹 {fingerprint(value) if value else '(空)'}  长度 {len(value)}")


def cmd_doctor():
    bad = 0
    drift_count = 0
    scanned = 0
    roots = [PROV_DIR, CCPOD_DIR]
    for root in roots:
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            path = os.path.join(root, name)
            if not os.path.isfile(path):
                continue
            if not name.endswith((".json", ".log", ".jsonl", ".tmp", ".bak")) \
               and ".bak." not in name:
                continue
            try:
                raw = open(path, "rb").read()
            except OSError:
                continue
            scanned += 1
            text = raw.decode("utf-8", "replace")
            hits = len(SECRET_RE.findall(text))
            detail = ""
            if name.endswith(".json"):
                try:
                    fields = find_literal_credentials(json.loads(text))
                except Exception:
                    fields = []
                if fields:
                    hits += len(fields)
                    detail = "（凭据字段是字面量: " + ", ".join(fields[:3]) + "）"
            if not hits:
                continue
            bad += 1
            perm = oct(os.stat(path).st_mode & 0o777)
            print(f"  ❌ {path}  明文 key {hits} 处{detail}  权限 {perm}")
    # $exec 形式一致性：三处实现（common.sh / SecretResolver / 本工具）曾各自漂移过
    # （一处带 -a "$USER"、一处不带、一处要求恰好单键），漂移的后果是"命令行能启动、
    # 菜单栏显示无 key"。这里机械钉死唯一正确形式，谁写歪了 doctor 就报。
    canon = re.compile(r"^security find-generic-password -s [A-Za-z0-9_.-]+ -w 2>/dev/null$")
    drift = []
    for root in roots:
        if not os.path.isdir(root):
            continue
        for name in sorted(os.listdir(root)):
            if not name.endswith(".json"):
                continue
            path = os.path.join(root, name)
            try:
                obj = json.load(open(path, encoding="utf-8"))
            except Exception:
                continue
            stack = [(obj, "")]
            while stack:
                cur, cur_path = stack.pop()
                if isinstance(cur, dict):
                    if "$exec" in cur:
                        cmd = cur["$exec"]
                        if not isinstance(cmd, str) or not canon.match(cmd):
                            drift.append(f"{path}:{cur_path or '$exec'}")
                    for k, v in cur.items():
                        stack.append((v, f"{cur_path}/{k}" if cur_path else k))
                elif isinstance(cur, list):
                    for i, v in enumerate(cur):
                        stack.append((v, f"{cur_path}[{i}]"))
    if drift:
        # 单独计数：漂移和"躺着明文"是两类问题，混进同一个计数器会让摘要说谎
        # （刚才就出现过：唯一的问题是 $exec 形式漂移，摘要却说"1 个文件里还躺着明文 key"）
        drift_count = len(drift)
        for d in drift:
            print(f"  ❌ $exec 形式不合规（应为 security find-generic-password -s <service> -w 2>/dev/null）: {d}")

    sqlite = os.path.join(HOME, ".claude-code-router", "config.sqlite")
    if os.path.exists(sqlite):
        raw = open(sqlite, "rb").read()
        hits = len(SECRET_RE.findall(raw.decode("utf-8", "replace")))
        perm = oct(os.stat(sqlite).st_mode & 0o777)
        print(f"  ℹ️  CCR config.sqlite: {hits} 把 key（网关自己的库，架构级集中点）权限 {perm}")
    if bad or drift_count:
        if bad:
            print(f"\n⚠️  {bad} 个文件里还躺着明文 key。搬进钥匙串: ccpod-key use <线路名>")
        if drift_count:
            print(f"\n⚠️  {drift_count} 处 $exec 形式不合规（三处实现会因此语义漂移）。"
                  f"规范形式: security find-generic-password -s <service> -w 2>/dev/null")
        sys.exit(1)
    print(f"✅ 扫了 {scanned} 个配置文件：没有明文 key，{drift_count} 处形式漂移")


sub = sys.argv[1]
if sub == "set":
    len(sys.argv) == 3 or die("用法: ccpod-key set <线路名>")
    cmd_set(sys.argv[2])
elif sub == "use":
    len(sys.argv) == 3 or die("用法: ccpod-key use <线路名>")
    cmd_use(sys.argv[2])
elif sub == "list":
    cmd_list()
elif sub == "doctor":
    cmd_doctor()
PYEOF
