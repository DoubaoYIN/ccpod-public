"""网关管线的模型档：让会话里所有可能发出的模型名都落在本管线上。

为什么需要（2026-10-05 实测，CCR usage_events 取证）：CCR 对认不出的模型名**不报错**，
静默转给 profile 默认模型（glm/glm-5.3）并返回 200——
  - 管线会话里子代理/`/model opus`/后台小模型发的是不带前缀的 claude-opus-5、claude-sonnet-5、
    claude-haiku-4-5-20251001（Claude Code 内置档位名），全部落到 GLM；
  - 已下架的模型（旧别名文件里的 aigocode/claude-opus-5）同样落到 GLM。
会话里显示的仍是 "Opus"，用户无从察觉。所以启动时把五个档位都钉到本管线的模型上，
并校验主模型还在管线里。

子代理档（2026-10-09，CCR 3.1.1 源码 + 抓包 + 账本取证）是唯一的例外：CCR 对 Claude Code 派出的子代理请求
（计费头 cc_is_subagent=true）**故意不看客户端指定的模型**，没配子代理专用模型就一律送 profile 主模型——
钉在本管线的 Opus 照样被换成 GLM，而会话记录里仍写 Opus。用户拍板（10-09）：子代理默认走全局默认模型
（裸敲 `claude` 用的那个，即主 settings.json env 的 ANTHROPIC_MODEL，去掉 [1m] 后缀），由 ccgo 写进
CLAUDE_CODE_SUBAGENT_MODEL——请求本身就写 GLM，到哪都是 GLM，标签天然真实，不依赖网关怎么识别子代理。
只对网关管线生效（直连线路的端点不认 `厂商/模型` 这种网关命名）；线路 env 里自己写了这个键就按线路的来。
⚠️ 绝不能写进任何 settings.json 的 env：那会盖掉所有管线并热加载进运行中的会话（PITFALLS #24b/#56），
ccdoctor 会查。

被 common.sh 的 get_provider_env / get_provider_claude_args 导入；纯函数，tests 直接调用。
"""
import datetime
import json
import os
import re
import sqlite3

TIER_KEYS = ("ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
             "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
             "ANTHROPIC_SMALL_FAST_MODEL")
SUBAGENT_KEY = "CLAUDE_CODE_SUBAGENT_MODEL"

# 自动压缩窗口安全网（2026-10-09，PITFALLS #58）：Claude Code 2.1.289 把 opus/fable 当 1M 窗口，压缩点从 16.8 万
# 悄悄挪到 97 万；缓存一冷（5 分钟无请求 TTL 到期），下一次请求要把全量上下文重新预填，首字节超过网关首字节期限
# 就被掐（524）、原样重试也过不去。10-10 晚实测（yescode/fable，#296）：Cloudflare 闸刀 ≈120s（115.9s 成功、≥125.3s 全灭），
# 冷预填速度 1.2–1.4k token/s（12 万 84s 过、~15 万 126s 必死）→ 生死线 ≈14 万 token，30 万默认兜底根本护不住。
# 触发点公式（10-10 claude.exe 静态取证 + #301 三次压缩动态实证）：触发 = 窗口 − 33000（20k 输出预留 + 13k 缓冲）。
# 窗口必须双侧约束：压缩后残余（实测 ~6.0–6.4 万）+ 工作余量 < 触发点，且触发点+单轮增量 < 生死线。
# 100000 曾在 #301 引发 thrashing（触发 6.7 万 vs 残余 6.4 万，每轮即压）→ 10-10 二次校准为 120000
#（触发 8.7 万，余量 ~2.3 万；稳态冷读 ≤ ~10.2 万 ≈ worst-case 89s < 115.9s 实测成功上限）。
# 线路文件 "auto_compact_window" 可改（整数）或 "off"（不注入），别名线路跟所属管线。
# 30 万默认只留给官方直连线路（预填快）。主方案仍是无损清旧工具输出（scripts/ccpod-rescue.py）+ 缓存热时交接。
# 按会话注入进程 env，绝不写 settings.json（#24b/#56）。代价：该会话里 /autocompact 被锁（环境变量优先级最高）。
AUTO_COMPACT_KEY = "CLAUDE_CODE_AUTO_COMPACT_WINDOW"
AUTO_COMPACT_DEFAULT = 300000
AUTO_COMPACT_MIN, AUTO_COMPACT_MAX = 100000, 1000000  # Claude Code 接受的范围
FAST_WORDS = ("flash", "fast", "mini", "lite", "highspeed")


def _version(model):
    return [int(n) for n in re.findall(r"[0-9]+", model)]


def _bare(model):
    return re.sub(r"\[1m\]$", "", model, flags=re.I)


def best(models, word=None, exclude=()):
    """同一家族里版本最高的那个；word=None 表示「不是快速版」的全部模型。"""
    pool = [m for m in models
            if (word is None or word in m.lower())
            and not any(x in m.lower() for x in exclude)]
    return max(pool, key=_version) if pool else None


USAGE_DB = os.path.expanduser("~/.claude-code-router/app-data/usage.sqlite")
ALIVE_DAYS = 7


def alive_models(provider, db=None):
    """CCR 账本里近 7 天真返回过 200 的模型（不带前缀）；账本读不了 → None（不知道）。

    为什么不信模型清单：yescode 清单里 4 个模型只有 opus-5-5 放行，sonnet/haiku/fable 一律 403
    （2026-10-05 账本 + 实测）。把 haiku 档钉到 yescode/claude-haiku-4-5 = 子代理和后台任务全挂。
    只读打开，不碰 CCR 配置。
    """
    db = db or os.environ.get("CCPOD_CCR_USAGE_DB") or USAGE_DB
    if not os.path.isfile(db):
        return None
    since = (datetime.datetime.now(datetime.timezone.utc)
             - datetime.timedelta(days=ALIVE_DAYS)).strftime("%Y-%m-%dT%H:%M:%S")
    try:
        con = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=1)
        try:
            rows = con.execute("select distinct logical_model from usage_events "
                               "where status_code = 200 and created_at >= ? and logical_model like ?",
                               (since, provider.replace("%", "") + "/%")).fetchall()
        finally:
            con.close()
    except sqlite3.Error:
        return None
    return {_bare(r[0].split("/", 1)[1]) for r in rows if r[0] and "/" in r[0]}


def tiers(models, main, alive=None):
    """每个档位 → 本管线里对应的模型（不带前缀）。缺这一档就退到主模型，绝不出管线
    （子代理档是唯一例外，见 subagent_model()）。
    alive = 近期真通过的模型集合；给了就只从里面挑（主模型除外，它是用户/管线定的）。"""
    if alive is not None:
        models = [m for m in models if m in alive]
    opus = best(models, "opus") or main
    # 快速版优先同家族（qwen3.8-max → qwen3.8-flash）：跨家族比版本号没有意义
    family = (re.match(r"[a-z]+", main.lower()) or [""])[0]
    fast = [m for m in models if any(w in m.lower() for w in FAST_WORDS)]
    same = [m for m in fast if m.lower().startswith(family)] if family else []
    haiku = best(models, "haiku") or best(same or fast) or main
    return {
        "ANTHROPIC_DEFAULT_OPUS_MODEL": opus,
        "ANTHROPIC_DEFAULT_FABLE_MODEL": best(models, "fable") or opus,
        "ANTHROPIC_DEFAULT_SONNET_MODEL": best(models, "sonnet") or main,
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": haiku,
        "ANTHROPIC_SMALL_FAST_MODEL": haiku,
    }


def global_default_model(settings_path):
    """全局默认模型（裸敲 `claude` 用的那个）→ (厂商/模型 或 None, 警告或 None)。

    来源 = 主 settings.json env 的 ANTHROPIC_MODEL（CCR 接管时按 profile 主模型写入），去掉 [1m] 后缀。
    键不存在（没接管网关的机器）→ (None, None) 静默；有键但不是 厂商/模型 形态 → (None, 警告)。"""
    data = _load(settings_path)
    env = data.get("env") if isinstance(data, dict) else None
    raw = env.get("ANTHROPIC_MODEL") if isinstance(env, dict) else None
    if not isinstance(raw, str) or not raw.strip():
        return None, None
    value = _bare(raw.strip())
    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._:-]+", value):
        return None, (f"全局默认模型 {raw!r}（{settings_path} env.ANTHROPIC_MODEL）不是 厂商/模型 形态，"
                      f"子代理档未设：子代理会按网关的兜底走")
    return value, None


def subagent_model(providers_dir):
    """子代理档 → (厂商/模型 或 None, 警告或 None)。主 settings.json 与 providers 目录同级
    （$CCPOD_CLAUDE_DIR/settings.json）。"""
    settings_path = os.path.join(os.path.dirname(os.path.abspath(providers_dir)), "settings.json")
    return global_default_model(settings_path)


def _load(path):
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else None
    except (OSError, ValueError):
        return None


def plan(data, providers_dir, usage_db=None):
    """→ None（不是网关管线 / 管线缺模型清单，原样启动）
       或 {"route": "厂商/模型", "tiers": {env 键: "厂商/模型"}, "notice": str|None}"""
    source = data.get("source")
    if source not in ("gateway", "gateway-alias"):
        return None
    pipeline = data
    if source == "gateway-alias":
        pid = data.get("pipeline_id")
        pipeline = _load(os.path.join(providers_dir, f"{pid}.json")) if pid else None
        if pipeline is None:
            return None
    provider = pipeline.get("gateway_provider") or data.get("gateway_provider")
    models = pipeline.get("gateway_models")
    if not provider or not isinstance(models, list) or not models \
            or not all(isinstance(m, str) and m for m in models):
        return None

    env = data.get("env") if isinstance(data.get("env"), dict) else {}
    args = data.get("claude_args") if isinstance(data.get("claude_args"), list) else []
    route = env.get("ANTHROPIC_MODEL") if isinstance(env.get("ANTHROPIC_MODEL"), str) else None
    if "--model" in args and args.index("--model") + 1 < len(args):
        route = args[args.index("--model") + 1]

    prefix = provider + "/"
    current = _bare(route[len(prefix):]) if route and route.startswith(prefix) else None
    notice = None
    if current not in models:
        fallback = pipeline.get("gateway_model")
        if fallback not in models:
            fallback = best(models, exclude=FAST_WORDS + ("haiku",)) or models[0]
        if route:
            notice = f"原模型 {route} 已不在管线 {provider} 里（网关会把它静默转给别家），改用 {prefix}{fallback}"
        route, current = prefix + fallback, fallback
    env_tiers = {k: prefix + v for k, v in tiers(models, current, alive_models(provider, usage_db)).items()}
    # 子代理档走全局默认模型，不钉本管线（见文件头）；调用方对线路 env 用 setdefault，线路自己写了就按线路的
    sub, sub_warning = subagent_model(providers_dir)
    if sub:
        env_tiers[SUBAGENT_KEY] = sub
    notices = [n for n in (notice, sub_warning) if n]
    return {"route": route, "tiers": env_tiers, "notice": "；".join(notices) or None}


def auto_compact_window(data, providers_dir):
    """线路的自动压缩窗口 → (字符串数值 或 None=不注入, 警告或 None)。别名线路自己没设就跟所属管线。"""
    value = data.get("auto_compact_window")
    if value is None and data.get("source") == "gateway-alias" and data.get("pipeline_id"):
        value = (_load(os.path.join(providers_dir, f"{data['pipeline_id']}.json")) or {}).get("auto_compact_window")
    if value is None:
        return str(AUTO_COMPACT_DEFAULT), None
    if value == "off":
        return None, None
    if isinstance(value, bool) or not isinstance(value, int) or not AUTO_COMPACT_MIN <= value <= AUTO_COMPACT_MAX:
        return str(AUTO_COMPACT_DEFAULT), (f"线路的 auto_compact_window={value!r} 无效"
                                           f"（只认 {AUTO_COMPACT_MIN}–{AUTO_COMPACT_MAX} 的整数或 \"off\"），按默认 {AUTO_COMPACT_DEFAULT}")
    return str(value), None


def rewrite_model_arg(args, route):
    out = list(args)
    if "--model" in out and out.index("--model") + 1 < len(out):
        out[out.index("--model") + 1] = route
    return out


EFFORTS = ("low", "medium", "high", "xhigh", "max")


def effort(data, providers_dir):
    """线路的默认思考强度 → (档位或 None, 警告或 None)。别名线路自己没设就跟所属管线。

    启动时走 `--effort` 参数而不是 CLAUDE_CODE_EFFORT_LEVEL：环境变量会锁死会话里的 /effort
    （PITFALLS #44），写进 settings.json env 后还删不掉——已热加载进运行中会话的 process.env（#56）。
    """
    value = data.get("effort")
    if value is None and data.get("source") == "gateway-alias" and data.get("pipeline_id"):
        value = (_load(os.path.join(providers_dir, f"{data['pipeline_id']}.json")) or {}).get("effort")
    if value is None:
        return None, None
    if value not in EFFORTS:
        return None, f"线路的 effort={value!r} 无效（只认 {'/'.join(EFFORTS)}），已忽略"
    return value, None


def apply_overrides(data, providers_dir, model=None, effort=None):
    """启动时一次性的覆盖（ccgo --model / --effort，菜单栏「启动新会话」）→ 改过的副本；非法输入直接 SystemExit。

    只管这一次启动，不写任何文件（设计：docs/superpowers/specs/2026-10-09-launch-model-effort-design.md）。
    模型只许是本管线清单里的：CCR 对认不出的模型名静默换成 GLM（见文件头）。模型 ID 本身可能带 /
    （zenmux 的 x-ai/grok-4.7），所以先按整串比对清单，比不上再试着去掉「厂商/」前缀。
    """
    out = dict(data)
    if model:
        pipeline = data
        if data.get("source") == "gateway-alias" and data.get("pipeline_id"):
            pipeline = _load(os.path.join(providers_dir, f"{data['pipeline_id']}.json")) or {}
        provider = pipeline.get("gateway_provider") or data.get("gateway_provider")
        models = pipeline.get("gateway_models")
        if data.get("source") not in ("gateway", "gateway-alias") or not provider \
                or not isinstance(models, list) or not models:
            raise SystemExit(f"--model {model}：这条线路不是网关管线（或缺模型清单），模型是固定的，启动时不能换")
        name = model
        if _bare(name) not in models and name.startswith(provider + "/"):
            name = name[len(provider) + 1:]
        if _bare(name) not in models:
            raise SystemExit(f"--model {model} 不在管线 {provider} 的清单里：{', '.join(models)}")
        route = f"{provider}/{name}"
        args = list(data["claude_args"]) if isinstance(data.get("claude_args"), list) else []
        if "--model" in args and args.index("--model") + 1 < len(args):
            args[args.index("--model") + 1] = route
        else:
            args += ["--model", route]
        out["claude_args"] = args
        env = dict(data["env"]) if isinstance(data.get("env"), dict) else {}
        env["ANTHROPIC_MODEL"] = route
        out["env"] = env
    if effort:
        if effort not in EFFORTS:
            raise SystemExit(f"--effort {effort!r} 无效（只认 {'/'.join(EFFORTS)}）")
        args = out.get("claude_args")
        if isinstance(args, list):
            kept, skip = [], False
            for a in args:
                if skip:
                    skip = False
                elif a == "--effort":
                    skip = True
                elif not a.startswith("--effort="):
                    kept.append(a)
            out["claude_args"] = kept
        out["effort"] = effort
    return out
