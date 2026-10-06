"""网关管线的模型档：让会话里所有可能发出的模型名都落在本管线上。

为什么需要（2026-10-05 实测，CCR usage_events 取证）：CCR 对认不出的模型名**不报错**，
静默转给 profile 默认模型（glm/glm-5.3）并返回 200——
  - 管线会话里子代理/`/model opus`/后台小模型发的是不带前缀的 claude-opus-5、claude-sonnet-5、
    claude-haiku-4-5-20251001（Claude Code 内置档位名），全部落到 GLM；
  - 已下架的模型（旧别名文件里的 aigocode/claude-opus-5）同样落到 GLM。
会话里显示的仍是 "Opus"，用户无从察觉。所以启动时把五个档位都钉到本管线的模型上，
并校验主模型还在管线里。

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
    """每个档位 → 本管线里对应的模型（不带前缀）。缺这一档就退到主模型，绝不出管线。
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
    return {"route": route,
            "tiers": {k: prefix + v for k, v in tiers(models, current, alive_models(provider, usage_db)).items()},
            "notice": notice}


def rewrite_model_arg(args, route):
    out = list(args)
    if "--model" in out and out.index("--model") + 1 < len(out):
        out[out.index("--model") + 1] = route
    return out
