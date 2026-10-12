# CCPod

> Claude Code 多线路指挥台 · A native macOS menu bar commander for Claude Code

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS](https://img.shields.io/badge/platform-macOS-blue)

如果你同时用 **Anthropic 官方订阅 + 多家中转站 / 国内厂商 Coding Plan**（GLM、Kimi、
DeepSeek、百炼、MiniMax、火山……），CCPod 帮你把它们管成一组「管线」：菜单栏一眼看全
所有会话在跑什么模型、每条线路还剩多少额度、一条线路挂了怎么快速切走。

## 功能

### 菜单栏 App（原生 Swift/SwiftUI）

- 🪟 **会话监控**：实时列出所有 Claude Code 会话（● 忙碌 / ○ 空闲 / ⏸ 等待输入），
  显示标题、所在管线、模型、最后活动时间；持久会话编号不重置
- 🔀 **多线路管理**：每条管线（provider）绑定网关线路 + 四档默认模型
  （opus/sonnet/haiku/背景任务），新会话自动携带，手动选择会被记住
- 📊 **额度面板**：自动识别网关软件类型（sub2api / new-api / Relay-Z / 各家官方直连），
  并行探测余额端点；美元/人民币/次数/百分比如实区分，透支也如实显示
- 🩺 **线路健康**：健康检查、测速、模型目录拉取、真实推理探测（`max_tokens: 1`），
  自动探测上架新模型并防「静默换模」（上游认不出的模型名偷偷换成默认模型还回 200）
- 🔔 **合盖保持唤醒**：电池供电合盖时保持联网，长任务不中断；带 sleep-switch 看门狗
- ✏️ **会话标题**：AI 标题 / 自定义重命名（走 Claude Code 官方标题机制）
- 🖥 **终端集成**：新窗口继承当前管线、向 TTY 注入切线命令、状态栏徽章文件
- 🌙 **优惠雷达** — 给线路填一个厂商公开定价页，每天自动抓一次「分时段定价 / 限时优惠」，
  菜单栏汇总提醒。只读公开页、只提醒，不改你的任何配置。

### CLI 工具集（装进 `~/.claude/bin/`）

| 命令 | 作用 |
|---|---|
| `ccstart` | 交互式选项目 + 管线，启动 Claude Code |
| `ccgo <管线> [项目关键词]` | 切管线 + 启动（支持 `--resume`） |
| `ccuse <名称前缀>` | 只切换当前环境（`ccuse off` 回官方 OAuth） |
| `ccnow` | 显示当前管线（`--badge` 输出徽章） |
| `ccworktree` | 每会话一个 git worktree 的并行隔离 |
| `ccdoctor` | 体检：运行中 App / 已装 App / 本地构建的版本、commit、hash 一致性 |
| `ccpod-key` | 密钥管理（`doctor` 机械校验 `$exec` 规范形态） |
| `cchandoff` | 跨管线会话交接包（脱敏、600 权限） |
| `claude-rename` | 会话改名工具（菜单栏重命名按钮的底层） |

### 密钥安全（设计进去的，不是后补的）

- 密钥**只存 macOS 钥匙串**；provider 配置文件里只允许
  `{"$exec": "security find-generic-password -s <service> -w 2>/dev/null"}` 引用形态
- 写盘文件强制 `600`、凭证目录 `700`；落盘/回显前自动脱敏（保留前 6 位打码）
- 读配置必须经 `SecretResolver`，`$exec` 解析失败直接报错，绝不静默回退
- 详见 [docs/SECURITY.md](docs/SECURITY.md)（安装前请读）

## 安装

```bash
git clone https://github.com/DoubaoYIN/ccpod-public.git
cd ccpod-public
./install.sh        # CLI 工具 + provider 模板；菜单栏 App 见下
```

菜单栏 App（可选，需要 Xcode Command Line Tools）：

```bash
cd menubar
./build.sh --install   # 构建 + 写版本 + 替换运行中实例 + 重启 + ccdoctor 体检
```

> 不要手动把 `CCPod.app` 拖进 `/Applications`——会绕过版本写入与重启流程。
> 怀疑版本错位就跑 `ccdoctor`。

## 快速上手

```bash
ccstart                     # 交互式：选项目 + 管线
ccnow --badge               # 🔵 my-relay
ccuse off                   # 切回官方 OAuth
```

provider 配置放 `providers/*.json`（参考 `relay.example.json`），env 支持
`$exec` 钥匙串引用。通过本地网关（如 [claude-code-router](https://github.com/musistudio/claude-code-router)）
聚合线路的用户，`providers/ccr.json` 已带默认模板。

## 开发

- `VERSION` 是唯一版本源；`menubar/build.sh` 负责写入版本/commit/build time
- 改动菜单栏 App 后必须 `cd menubar && ./build.sh --install` 并确认 `ccdoctor` 全 ✅
- 测试：`pytest scripts/tests/`、`bash scripts/tests/test_*.sh`、
  `swift scripts/tests/quota_parsers.swift`
- 架构：[docs/architecture.md](docs/architecture.md)；
  踩坑总库：[docs/lessons/PITFALLS.md](docs/lessons/PITFALLS.md)

## License

[MIT](LICENSE) © ccpod contributors
