# ccpod architecture

This document explains *why* ccpod is built the way it is.
For day-to-day usage, see the [README](../README.md).

## The core problem

Claude Code (CC) picks an auth method at startup by reading environment
variables from `~/.claude/settings.json`:

- **No `ANTHROPIC_*` env** → falls back to the OAuth refresh token stored
  in the keychain from `claude login`. This is the Pro/Max subscription path.
- **`ANTHROPIC_BASE_URL` + `ANTHROPIC_API_KEY` set** → routes all traffic
  through that endpoint. This is how you talk to a third-party relay.

The decision is made **at process start**. Once CC is running, flipping
these vars has no effect on the live process — CC has already chosen its
auth method.

So "switching between Pro/Max OAuth and a relay" without restarting is
fundamentally at odds with how CC reads its config. Any tool that claims
otherwise is doing one of the following.

## Three levels of "hot-switching"

### A-level — true in-process switch

The only way to genuinely redirect a running CC process is to sit between
CC and Anthropic as an HTTP proxy. CC makes requests to `localhost:<port>`,
the proxy decides per-request whether to forward to the real Anthropic
endpoint (OAuth path, refreshing the token as needed) or to the relay
(with the relay's API key), and CC never knows which one it hit.

**Why we don't ship A-level:**

1. **Anthropic's OAuth refresh flow is undocumented for third parties.**
   Implementing it means reverse-engineering the token refresh protocol
   and updating whenever Anthropic changes it. Fragile.
2. **Ban risk.** A proxy that doesn't perfectly mimic the official client's
   OAuth handshake — user-agent quirks, retry semantics, TLS fingerprint —
   is the kind of thing rate-limit heuristics flag. We will not put the
   user's subscription at risk.
3. **Complexity budget.** A hot proxy means a daemon, a TLS cert, a port
   to keep free, and a whole new failure mode. The shell-layer approach
   below covers 95% of the actual use case.

cc-switch has a "Proxy Takeover" mode that does A-level. Read their code
if you want to see what it takes — it's substantial.

### B+-level — scripted quit + resume/handoff

This is what ccpod ships.

1. `ccuse <provider>` writes the provider's `env` block into
   `~/.claude/settings.json` atomically (temp file + `mv`).
2. The user quits the current CC session with `/quit`.
3. If the provider did not change, ccpod can run `claude --resume <session-id>`.
4. If the provider changed, ccpod runs `cchandoff`, writes a portable bundle
   under `~/.claude/handoffs/`, then starts Claude Code with the bundle's
   `bootstrap-prompt.md`.

Raw cross-provider `--resume` is intentionally avoided. Claude Code transcripts
can contain `thinking` blocks with provider-sensitive `signature` fields; replaying
those fields through a different provider can fail before the model receives the
real user context.

**What survives the switch:**

- Same-provider resume: all transcript state that Claude Code can resume.
- Cross-provider handoff: visible messages, tool calls, tool results, git state,
  project memory, and a sanitized line-for-line transcript copy.
- The working directory and project memory.

**What is lost:**

- Any in-flight streaming response that hadn't completed.
- Live MCP server connections (they reconnect on resume).
- In-process background tasks (nothing in CC survives process death
  regardless of tool used).
- Hidden thinking is not portable memory and is not replayed across providers.

In practice: a short restart with portable conversation state intact. This is
what the "绝对不中断工作" requirement actually demands — a tool-assisted
restart, not an in-process switch.

### Known: "Auth conflict" warning when switching to a relay

When you `ccuse easy` and then launch `claude`, CC prints:

> ⚠ Auth conflict: Both a token (claude.ai) and an API key
> (ANTHROPIC_API_KEY) are set.

This is cosmetic. CC detects the OAuth token stored in the macOS
keychain (from your Pro/Max `claude login`) alongside the
`ANTHROPIC_API_KEY` we inject. It warns, but **prioritises the API key**
— you can confirm by the `API Usage Billing` label in the status line.

We cannot suppress this warning:
- There is no env var or config flag to disable the check
  ([anthropics/claude-code#9515](https://github.com/anthropics/claude-code/issues/9515),
  [#4733](https://github.com/anthropics/claude-code/issues/4733)).
- Running `claude /logout` would delete the OAuth token from the
  keychain, breaking `ccuse off` (you'd have to re-login every time you
  switch back to official).

The warning is harmless. Routing works correctly in both directions.

### B-level — manual

The user edits `settings.json` themselves, quits, re-launches. ccpod's
value over pure B-level is (a) atomic write vs hand-editing JSON, (b) a
registry of provider configs so you don't have to remember the exact env
keys, (c) per-project memory of which provider you used last.

## Data flow

```
┌────────────────┐    ccuse <name>    ┌────────────────────────┐
│ CLI user       │ ─────────────────▶ │ scripts/ccuse.sh       │
└────────────────┘                    │  1. jq merge env block │
                                      │  2. atomic rename      │
                                      │  3. write badge file   │
                                      │  4. record proj memory │
                                      └─────────┬──────────────┘
                                                │ writes
                                                ▼
                               ┌────────────────────────────────┐
                               │ ~/.claude/                     │
                               │   settings.json     (CC reads) │
                               │   current-provider  (sidecar)  │
                               │   ccpod-status.txt  (sidecar)  │
                               │   project-providers.json       │
                               └────────┬──────────────┬────────┘
                                        │              │
                        FSEvents watch  │              │  reads at startup
                                        ▼              ▼
                          ┌──────────────────┐   ┌──────────────┐
                          │ CCPod menu bar   │   │ claude CLI   │
                          │ (Swift)          │   │ (on relaunch)│
                          └──────────────────┘   └──────────────┘
```

## Why the shell layer owns the logic

The Swift menu bar app does **not** reimplement provider switching. When
the user clicks "switch to Relay-EC" in the menu bar, the Swift app
literally `Process`-launches `~/.local/bin/ccuse Relay-EC`.

Reasons:

- **Single source of truth.** One implementation to maintain, audit, and
  keep atomic. If we ever find a bug in the atomic-rename logic, we fix
  it once.
- **CLI is the real product.** Users who use the menu bar app still have
  `ccuse` available in scripts, shell aliases, CI, and the `ccstart`
  launcher. These need the CLI to work anyway.
- **Test surface.** Bash + jq is straightforward to smoke-test in a
  sandboxed `CCPOD_CLAUDE_DIR`. Swift testing would require a whole
  XCTest harness.

The Swift app's job is strictly UI: render state, dispatch intent.

## Provider config format

Each file under `~/.claude/providers/<name>.json` is a single JSON object
with one key, `env`:

```json
{
  "env": {
    "ANTHROPIC_BASE_URL": "https://...",
    "ANTHROPIC_API_KEY": "sk-..."
  }
}
```

To "clear" env (the official/OAuth path), the file contains `{"env": {}}`.
`ccuse` overwrites the entire `env` block in `settings.json` with this —
it does not merge. This is deliberate: leaving stale relay keys in place
when you think you're on OAuth is exactly the kind of bug that could
silently route your traffic to the wrong endpoint.

## Security posture

- **No real API keys in the repo.** `providers/Relay-EC.example.json`
  has a placeholder; `install.sh` copies it to
  `~/.claude/providers/Relay-EC.json` for the user to fill in.
  `.gitignore` blocks any `Relay-EC.json` / `*.local.json` /
  `*.secret.json` from being staged.
- **No network calls from ccpod itself** — except for balance queries.
  `BalanceService` makes read-only GET requests to the provider's own
  API to fetch usage/billing data. No data is sent to third parties.
- **Atomic writes** to `settings.json` prevent partial-write corruption
  if the process is killed mid-update.
- **Symlink install**: `~/.local/bin/{ccuse,ccstart,ccnow}` are symlinks
  into the repo clone, so `git pull` is the update mechanism. No
  privileged install, no system paths touched.

## Balance query architecture

The menu bar app queries each provider's remaining balance/quota so the
user can see at a glance how much budget is left — without visiting each
relay's web dashboard.

### Gateway auto-detection

Different relay backends expose different billing endpoints. Rather than
requiring the user to specify which backend their relay uses, ccpod
probes automatically:

```
First balance request for provider X
        │
        ├─ GET /v1/usage                              (sub2api)
        ├─ GET /v1/dashboard/billing/subscription      (new-api / one-api)
        └─ GET /api/v1/management/subscription/detail  (Relay-Z)
        │
        ▼  (first 200 OK wins)
  Save gateway type to ~/.claude/providers/X.json → {"gateway": "sub2api"}
        │
        ▼  (subsequent requests skip probing)
  Fetch balance via the detected endpoint
```

### Supported gateway families

| Family | Endpoint | Auth | Projects |
|--------|----------|------|----------|
| sub2api | `/v1/usage` | Bearer API Key | Sub2API / CRS2 |
| new-api | `/v1/dashboard/billing/*` | Bearer API Key | One API, New API, OneHub, Veloera, Neo-API, VoAPI |
| Relay-Z | `/api/v1/management/*` | Bearer Management Key | Relay-Z (commercial) |

The `gateway` field in the provider JSON is a cache — delete it and the
next balance request will re-probe. The `MANAGEMENT_API_KEY` env var is
read from the provider config for services (like Relay-Z) that require a
separate management credential.

### What doesn't have a balance API

Pure proxy projects (CLIProxyAPI, claude-code-mux, VibeProxy, codex-lb)
don't expose billing endpoints — they forward OAuth credentials from
subscriptions. Balance display is silently skipped for these.

### Gateway lines and host rules (2026-10-01)

After the CCR migration every launch entry is a `gw-*` file pointing at
`127.0.0.1:3456` with no upstream key, so the probe above had nothing to
query. Now:

- **Credentials for gateway lines** come from the CCR management RPC
  `getConfig` (`Providers[].api_base_url` + `api_key`, resolved through
  `SecretResolver`) — the same path the official web console uses.
  `config.sqlite` is never read. Keys live only in memory for one query;
  they are not cached, logged, written to the sidecar or shown in errors.
- **Result key = CCR provider name** (`glm`, `kimi`, …). `gw-*` files map
  back through their `gateway_provider` field. CCR lines are resolved
  before same-named provider files: APFS is case-insensitive, so
  `relay-d` would otherwise read the legacy `Relay-D.json`.
- **Host rule table first, blind probe last** (`QuotaAdapters.kind(for:)`,
  pure function, unit-tested):

| Host | Endpoint | Windows |
|------|----------|---------|
| `*.bigmodel.cn` / `z.ai` | `GET /api/monitor/usage/quota/limit` + `/api/biz/subscription/list` (bare key) | 5 hours / week (count) + plan name, billing cycle & renew price, renew date. No monthly window exists |
| `api.kimi.com` | `GET /coding/v1/usages` + `GET /coding/v1/me` (Bearer; me returns the member tier) | 5 hours / week (count) + booster-pack monthly top-up cap. The monthly allowance pool is app-only, not in the API |
| `*.deepseek.com` | `GET /user/balance` (Bearer) | CNY balance |
| `*.minimax.cn` / `*.minimaxi.com` | `GET /v1/token_plan/remains` (Bearer model key) | 5 hours / week, **percent only** — upstream exposes `*_remaining_percent`; the `count` fields are always 0 in this plan (community claims about their meaning are moot). `weekly_boost_permille` semantics unverified, not shown |
| `token-plan.*.aliyuncs.com` | `GetSubscriptionStats` via ModelStudio OpenAPI (RAM AK in keychain `ccpod-aliyun-ak-*`, ACS3 signature). Personal plans return empty Data — the credits API is team-only — so it degrades to console-only | link to console when no data |
| `relay-a.dev` | sub2api probe (`/v1/usage`). Only `/v1/messages` is client-restricted; the balance endpoint is open (2026-10-02 tested) | wallet (USD), or day/week windows when the subscription has quota left |
| `*.yes.vg` | `POST /api/v1/auth/login` (username/password from keychain `ccpod-relay-s-*`) → `GET /api/v1/user/balance`. The model key (`cr_`) is rejected for balance (403) | week window (USD) + subscription/PayGo balances; notIntegrated until credentials are configured |
| `relay-z.ai` | none — not integrated | — |
| anything else | the sub2api / new-api / Relay-Z probe above | — |

- Every `BalanceInfo` carries a `status` (`ok` / `restricted` /
  `notIntegrated` / `consoleOnly` / `failed`) so the UI never renders
  "unsupported", "failed" and "not checked yet" as the same blank.
- Windows carry a `unit` (`usd` / `cny` / `count`); GLM and Kimi report
  counts, not dollars.
- Same (host, key) is queried once per round (relay-d / relay-d-grok
  share an account).
- Sidecar `~/.claude/ccpod-quota.json` (mode 600) adds `status`, `unit`,
  `renewAt` and `tightest` (the most-used bounded window). The statusline
  looks it up by the session model id prefix (`glm/glm-5.3` → `glm`), then
  `CCPOD_PROVIDER`'s `gateway_provider`, then the provider name.
- Refresh: hourly for every CCR line plus active sessions (5 min after
  launch); opening the popover queries lines that have no data yet;
  ↻ in the 📊 panel forces one line.

## What ccpod is *not*

- Not a Claude Code fork or a wrapper CLI for the model itself.
- Not a proxy. Does not intercept, inspect, or modify any API traffic.
- Not a credentials manager. The OAuth token lives in the system keychain
  where `claude login` put it; the relay API key lives in a file the user
  controls.
- Not tied to any specific relay. The provider config format is generic —
  add another `<name>.json` and `ccuse <name>` switches to it.
