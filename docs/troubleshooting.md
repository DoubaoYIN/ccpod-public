# ccpod troubleshooting

记录重复出现、容易误判、依赖外部工具版本行为的故障。新问题优先补到这里，避免只靠聊天记录记忆。

## 记录规则

需要专门记录的情况：

- 同类问题出现第二次。
- 根因跨越多个边界，例如 shell、Claude Code、provider 配置、macOS 终端。
- 外部工具升级后行为变化，且旧判断可能失效。
- 修复涉及隐式状态目录、登录态、密钥、安装路径或版本路径。

记录时至少写清：

- 现象
- 触发条件
- 根因
- 修复位置
- 验证命令
- 防复发要点

## 2026-05-27: Claude Code Auth conflict 导致 API-key provider 打不开

### 现象

从菜单栏或终端启动：

```bash
ccgo Relay-A /Users/yourname/Documents/SecondBrain
```

Claude Code 进入后显示：

```text
Auth conflict: Both a token (claude.ai) and an API key (ANTHROPIC_API_KEY) are set.
```

用户体感是 claudecode 打不开或卡在首屏。

### 触发条件

- `~/.claude.json` 中存在 `oauthAccount`，说明当前机器登录过 `claude.ai`。
- 第三方 provider 配置注入 `ANTHROPIC_API_KEY`，例如 `Relay-A`。
- 当前命中的 Claude Code 是新版，例如 `2.1.112`。

### 为什么会重复出现

之前的“provider isolation”只隔离了每个窗口的 provider 环境变量，解决的是 `ANTHROPIC_*` 串线。

这次冲突来自 Claude Code 自己读取全局账号状态：

- `official` 需要 `claude.ai` OAuth 登录态。
- `Relay-A` / relay provider 需要 `ANTHROPIC_API_KEY`。
- Claude Code 2.1+ 同时看到 `oauthAccount` 和 API key 后，会明确报 `Auth conflict`。

所以这是“账号状态目录串线”，不是之前那种“环境变量串线”。

### 修复思路

API-key provider 启动 Claude Code 前，自动设置独立配置目录：

```bash
CLAUDE_CONFIG_DIR=~/.claude/provider-configs/<provider>
```

隔离目录会共享普通配置和本地历史：

- `settings.json`
- `settings.local.json`
- `CLAUDE.md`
- `plugins`
- `skills`
- `projects`
- `sessions`
- `tasks`
- `file-history`
- `plans`
- `paste-cache`
- `shell-snapshots`

但不会复制 `oauthAccount`。

同时会从全局 `~/.claude.json` 同步安全状态：

- `theme`
- `hasCompletedOnboarding`
- `lastOnboardingVersion`
- 项目信任和 onboarding 标记

这样可以同时避免两件事：

- API-key provider 不再撞上 `claude.ai` 登录态。
- 新隔离目录首次启动不再弹主题和项目 onboarding 向导。

### 修复位置

- `scripts/lib/common.sh`
  - `provider_has_api_auth_env`
  - `prepare_provider_claude_config`
  - `sync_provider_claude_state`
- `scripts/ccgo.sh`
- `scripts/ccstart.sh`

### 验证命令

语法检查：

```bash
bash -n scripts/lib/common.sh scripts/ccgo.sh scripts/ccstart.sh
```

确认 `official` 不启用隔离目录：

```bash
bash -c 'source scripts/lib/common.sh; name=$(resolve_provider official); eval "$(get_provider_env "$name")"; prepare_provider_claude_config "$name"; test -z "${CLAUDE_CONFIG_DIR:-}"'
```

确认 `Relay-A` 启用隔离目录，且没有 `oauthAccount`：

```bash
bash -c 'source scripts/lib/common.sh; name=$(resolve_provider Relay-A); eval "$(get_provider_env "$name")"; prepare_provider_claude_config "$name"; jq "{theme, hasCompletedOnboarding, hasOauth:(has(\"oauthAccount\")), projectCount:(.projects|length)}" "$CLAUDE_CONFIG_DIR/.claude.json"'
```

期望：

```json
{
  "theme": "auto",
  "hasCompletedOnboarding": true,
  "hasOauth": false,
  "projectCount": 5
}
```

启动验证：

```bash
ccgo Relay-A /Users/yourname/Documents/SecondBrain
```

期望直接进入 Claude Code 主界面，不再出现 `Auth conflict`。

### 防复发要点

- 不要把全局 `~/.claude.json` 原样软链或复制到 provider 隔离目录。
- 不要把 `oauthAccount`、token、密钥类字段写入仓库或隔离状态同步名单。
- Claude Code 升级后，如果认证行为变化，优先检查：
  - `claude --version`
  - `claude auth status`
  - `env | rg 'ANTHROPIC|CLAUDE_CONFIG_DIR|CLAUDE_.*KEY'`
  - `jq 'has("oauthAccount")' ~/.claude.json`

