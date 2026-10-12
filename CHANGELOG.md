# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Nightwatch 夜间守门人：无人值守时会话不停摆**（PITFALLS #59，`docs/nightwatch.md`）：`ccnight on` 后 PreToolUse hook 对
  AskUserQuestion / ExitPlanMode 输出 `deny`+引导词（模型收理由继续回合，不再像 #279 那样冻结 6 小时），问题脱敏落盘
  `~/.claude/nightwatch/asks/`，晨间 `ccnight morning` 聚合批答；Notification / StopFailure 只观测落盘。三红线：hook 永不代答
  （不输出 allow/updatedInput）、授权只可预先生产、push/装机/系统级夜间永久冻结待晨。hook 崩溃/超时 = fail-open 问题照弹
  回到现状不会更坏（真会话实测 UI 照常弹出）。安装 `scripts/nightwatch/install.sh`（幂等合并 3 组 hooks 进全局 settings，
  ccgo 启动整份同步自动传播到各线路）；自检 `ccnight doctor`（含 provider 残留检出）与 ccdoctor Nightwatch 节（未安装=中性）。
  离线单测 `scripts/tests/test_nightwatch.sh` 11 节 + 真 tmux 会话实测 deny 链/fail-open/防循环/HIDIdle/脱敏全过。
- **优惠雷达**：在「管线管理」里给某条 gateway 管线填一个厂商公开的定价/活动页网址，ccpod 每天 21:00 抓一次、
  21:30 汇总提醒。菜单栏 popover 一行说清「现在能省什么 / 哪页读不到」，面板窗口分「生效中 / 即将开始 / 已过期」三节，
  每条都带**原文摘录**和来源链接。
  - **只提醒，不动任何配置**：不切线路、不改 settings、不碰 CCR。面板里没有任何按钮会写配置文件。
  - 情报分两级：**A 类峰谷定价**（官方页字面写着、可核实）才弹通知；**B 类限时活动**（易变、信源杂）
    只在面板里露脸并标 ❓，**永远不弹通知**。
  - 失败可见：页级四态（`ok` / 抓不到 / 要 JavaScript / 读不出优惠）各有一句大白话和一份证据
    （HTTP 码、可见字符数、错误原文、`note`）。「今天没优惠」和「页读不到」在界面上绝不长一个样。
  - 出网口径：只做无头 HTTP GET，**不跑浏览器、不执行 JavaScript**，不带任何凭证。详见 `docs/SECURITY.md`。
  - 首条规则覆盖阿里云百炼的 DeepSeek 系列闲时 5 折（22:00–次日 08:00 北京时间）。规则在 `scripts/promo-rules.json`，
    改规则不用重编译 App。
  - 设计 `docs/superpowers/specs/2026-10-10-promotion-radar-design.md`；实现计划
    `docs/superpowers/plans/2026-10-10-promotion-radar.md`。
- **启动新会话时可选这一次的模型和思考强度**：「启动新会话」表单在「管线」下多一行「模型 / 思考」，默认跟管线走；
  选了别的只用于这一次（不写任何文件，启动后回到默认，会话菜单「重启」仍按管线默认）。实现是 `ccgo` 新增
  `--model` / `--effort`（`line_models.apply_overrides`）：模型必须在管线清单里、档位必须合法，否则在启动 claude
  之前就报错（PITFALLS #43）；直连线路只能改思考强度。不传参数时启动行为与改动前逐字节相同（本机全部线路比对过）。
  设计 `docs/superpowers/specs/2026-10-09-launch-model-effort-design.md`。⚠️ 表单点击未实机点验。
- **大上下文冷读 524 的两道防线**（PITFALLS #58，`docs/lessons/2026-10-09-large-context-cold-read-524.md`）：Claude Code 10-05 升到 2.1.289 后
  把 opus-5-5 / fable-5-1 当 1M 窗口，自动压缩点从 16.8 万悄悄挪到约 97 万；会话涨到 40 万后缓存一冷（闲置 > 5 分钟），下一次请求首字节
  超过中转站 Cloudflare 的 100 秒就被掐成 524，Claude Code 原样重试 10 次，窗口"卡死" 2–20 分钟（10-09 一天 24 次）。
  - `scripts/ccpod-rescue.py <session-id>`：**不经过模型**的解卡——把会话文件做一份副本，旧工具输出换成占位符（上下文 90% 是工具输出，
    用户原话 + 拍板 < 2%），新窗口 `--resume` 副本。实测 fable 42 万 → 19.3 万，12 秒返回，准确引用用户最后一句原话。只读原文件、副本 0600、不覆盖。
  - 自动压缩窗口安全网：ccgo 对所有线路按会话注入 `CLAUDE_CODE_AUTO_COMPACT_WINDOW=300000`（线路文件 `auto_compact_window` 可改或 `"off"`；
    线路 env 自己写了按线路的；绝不进 settings env）。这是兜底不是主方案——有损，且在该会话里锁住 `/autocompact`。只对新开的会话生效。
  - `ccdoctor` 新增「压缩窗口」段：settings env 里不许有该键；运行中的 claude 进程缺它的列出 pid（重启即可带上）；正面证据的手动取法。
  - 不采用：1 小时提示缓存（relay-a 实测不兑现）、定时保温（贵且同样靠中转站兑现）。
- **子代理默认走全局默认模型，不再被网关静默换掉**（`scripts/lib/line_models.py` 的 `subagent_model()`，PITFALLS #57）：
  CCR 3.1.1 对 Claude Code 子代理请求不看客户端指定的模型、一律送 profile 主模型（GLM），钉在本管线的 Opus 照样被换且会话里仍显示 Opus
  （09-26 起累计约 640 条，10-09 一天 435 条）。现在 ccgo 启动网关管线会话时把 `CLAUDE_CODE_SUBAGENT_MODEL` 写成主 settings 的
  全局默认模型（去掉 `[1m]`）：请求本身就写 GLM，标签天然真实。线路 env 自己写了该键按线路的来；直连线路不设；
  读不到或不是「厂商/模型」形态就不设并在终端提示。只对新开的会话生效。
  `ccdoctor` 新增两条：换模列表下面说明子代理来源；任何 settings 的 env 里出现该键就告警（会盖掉所有管线并热加载进运行中会话）。
- **菜单栏盯网关换模**（`RoutingLeakService` / `RoutingLeakPolicy`）：每半小时只读 CCR 账本，近 24 小时「请求模型 ≠ 实际路由」的
  真实会话请求在线路区常显一行橙字；新出现的最多每 6 小时推一次系统通知。这事从 09-26 就开始、两周没人看见，根因是 ccdoctor 要人手动跑。
- **管线默认思考强度**：管线管理里「默认模型」下面加「思考强度」（跟随全局 / low … max），存为线路文件的 `effort`；
  `ccgo`/`ccstart`/切线路重启都带 `--effort`（`scripts/lib/line_models.py` 的 `effort()`，别名线路跟所属管线）。
  刷新管线时保留该设置；非法值启动时在终端提示并忽略。刻意不用 `CLAUDE_CODE_EFFORT_LEVEL`：环境变量会锁死 `/effort`，
  写进 settings env 后还会残留在运行中的会话里（PITFALLS #56）。实测（2.1.289，本地截获 API 请求）：`--effort max/xhigh/low`
  原样出现在 `output_config.effort`；同一会话先 `/effort high` 再提问，`--effort max` 的请求变成 high，环境变量的仍是 max。
- **会话菜单「重启」**：原来「切换到 <当前线路>」点了什么都不做；现在对同线路写带 sessionId 的 pending，
  ccgo 以原线路 `--resume` 重启，套用线路当前的默认模型和思考强度、换掉旧进程的环境残留。会中断正在进行的回复。
  E2E 测试覆盖 pending → 重启 → 同号 → 带上新 `--effort`；菜单点击本身 ⚠️ 未实机点验。
- **点会话行直接切到那个终端窗口**（`TerminalAdapter.focusSession`）：弹窗里的会话行整行可点，
  iTerm2 / Terminal.app 按分屏的 `tty` 精确定位（`select` 分屏→标签页→窗口，先取消最小化，再 `activate`）；
  Ghostty 的分屏没有 tty 属性，按 session-hud hook 写上去的分屏标题匹配，兜底按工作目录且只认唯一命中。
  只对**在运行的**终端发脚本（`tell` 没在跑的 App 会把它拉起来），登记的终端优先、收编/直接启动行轮询其余终端；
  没有 TTY 的「后台」行不挂点击。行内的重命名/关闭按钮与线路菜单按设计各自响应（⚠️ 未实机点验）。
- **添加管线更顺手、同厂商多账号分得清**（`8efccee`，10-08）：弹窗线路区「➕ 添加」和「…」菜单「添加管线…」直接弹出添加表单；
  默认名 `厂商-计费模式`（`volcengine-payg`…，切计费模式跟着变，重名加 `-2`）；名称可写中文（存 `display_name`，ID 自动生成）；
  报错区固定在按钮上方、可滚动复制。管线管理每行显示 **key 指纹**（SHA256 前 6 位，`KeyFingerprint`），添加时提示
  「这把 key 已用在 X / 同厂商已有别的 key」（多账号多 key 的预案，PITFALLS #52）。删线路时连带删它专属的钥匙串条目
  `ccpod-line-<名>`（别的线路还在引用就不删）。火山 `ModelNotOpen` 译成「账号没开通该模型」。
- **弹窗「管线」区改名「线路状态」，并列出直连线路**（`8efccee`）：原来只列网关线路，火山/MiniMax/DeepSeek 这些直连线路看不到。
  排序按近 7 天**启动次数**（`scripts/lib/common.sh` 每次 ccgo 登记时追加一行到 `~/.claude/ccpod-launch-log.jsonl`），
  次数相同再比网关近 7 天请求数。报错默认收起，只挂 ⚠️，点开才看全文。错误诊断窗口顶部自动列出线路问题，可「填入诊断」。
  ⚠️ 界面**未实测**。
- **新模型发现（自动上架第一期，只发现不上架）**（`ModelOnboardPolicy` / `ModelOnboardService`）：每轮周期实测后顺带拉各线路的
  上游模型目录，找出「比网关清单里同系列更新」的模型，写进 `~/.claude/ccpod-model-onboard-round.json`（600），弹窗和 `ccdoctor`
  都会提示。带日期的变体、图像/语音/视频模型、预览版、版本号有歧义的（4.20 对 4.7）、清单里没有的新系列一律不算。
  这一期不改网关清单、不发模型请求。起因：10-05 发现 relay-s 的 Fable 5.1 一直可用却没进清单（清单是手抄副本、无人对账）；
  单测用当天 7 条线路的真实目录做夹具，断言旧清单能抓出 Fable 5.1 / Sonnet 5.5（`test_model_onboard.sh` 50 项）。
- **`ccdoctor` 新增「模型清单对账」**：列出清单里近 7 天从没返回过 200 的模型，以及上游已有而清单里还没有的同系列新模型。
  只提示，不影响 ccdoctor 的通过与否。
- **体检里的网关/设置问题行可以「点开去修」**（`LineCheckFixPolicy`）：网关没在运行 → 复制启动命令；
  入站鉴权失效、对话日志被打开 → 打开网关控制台；`settings.json` 指向旧代理或缺共用配置 → 在访达中显示该文件。
  没有对应修复入口的问题（盲打返回码异常、开机自启未装、取不到入站钥匙、不认识的新检查项）只给一句说明和
  「重新体检」，不做假按钮。单测 `test_line_check_fix.sh` 42 项，含对 `line-check.py` 措辞的防漂移断言。
  ⚠️ 界面与三个按钮的实机效果**未实测**；走查用演示数据入口 `CCPOD_LINECHECK_FIXTURE=<json>`（行名带「（演示数据）」）。
- **导入旧线路前先实测**（`ProviderImportPreflight`）：与手动新增同一道闸（`LinePreflight`）。实测没通过或缺地址/key/模型名的
  条目默认先不导入，结果区给「仍然导入这 N 条」并标注「已导入（未实测通过）」；本机网关线路不实测、照常可导入。
  单测 `test_preflight_import.sh` 11 组。⚠️ 导入窗口的实机走查**未实测**。

### Fixed
- **`ccdoctor` 读不到 CCR 账本时会崩**：`warn "…跳过（$usage_db）"` 变量紧跟全角括号（PITFALLS #10），
  bash 3.2 + `set -u` 下报 `usage_db�: unbound variable` 退出 127；改成 `${usage_db}`。只在没有账本/sqlite3 时触发，
  所以本机一直没暴露（公开版用户没装 CCR 就会撞上）。全仓 shell 扫描已清零。
- **线路状态审查修复**（10-09；审查清单先逐条对照代码复核，不成立的条目没动）：
  - 测通结论带上「多久以前测的」（`AgeText`，和额度更新时间用同一套说法；额度原来超过一天还写「50 小时前更新」）；
  - 周期实测「新结论盖旧结论」（`LineAutoProbePolicy.resultUpdate`）：测通了，之前的失败（含手动测出的）作废；还没通就刷新时间；
    本轮进行中手动测出的结论不碰；从没通过的线路（只认 Claude Code 客户端的中转站）不额外挂 ⚠️；
  - 周期实测总结点名没通的线路（「自动实测 5/7 通，没通：Relay-A、Relay-S」），原来只有「5/7 通」；
  - 测通超过 2 分钟被停时说「探测超时」，原来显示「探测输出解析失败」，像脚本坏了；
  - 「今日网关用量」每次展开都重新取：原来只取一次，之后一直是旧数，过了午夜还把昨天的数标成「今日」；
  - 网关体检没跑成时，直连线路和「重新体检 / 管线管理 / 添加」按钮照常显示（原来整块换成一句报错，按钮也一起没了）；
  - 「编辑此线路」直接弹出这条线路自己的编辑框（原来只打开整个管线管理窗口）；网关线路原来「设置」和「编辑此线路」
    两个按钮并排、去处不同，合成一个；
  - 直连线路的说明改成大白话（直连 = Claude Code 直接连厂商；「添加管线」加的都是直连）；网关线路展开后显示排序依据；
  - 错误诊断窗口也收直连线路的 ⚠️（原来只收测通失败）。
  单测：`test_line_auto_probe.sh` 新增 13 项、新增 `test_age_text.sh` 11 项，都做过变异测试（把代码改坏能报 FAIL）。⚠️ 界面**未实测**。
- **线路编辑器 / 档位编辑器保存时不再整份覆盖**（`EditorDelta`）：原来把窗口打开时的快照写回网关，窗口开着期间别处的改动会被
  静默回滚——新加的模型被抹掉、删掉的被复活、轮换过的 key 被改回旧的；档位编辑器还会把「没设置、只是界面默认显示第一项」的
  档位写进去。现在只把本窗口里实际改动的部分叠加到保存那一刻新鲜读到的配置上；什么都没改就不写网关
  （账本显示写网关的同一秒活会话吃过 502）。单测 `test_editor_delta.sh` 18 组。⚠️ 实机走查**未实测**。
- 体检「网关不在」那一行显示的启动命令被界面文字替换改坏（`com.yourname.ccr-gateway` → `com.yourname.网关-gateway`、
  `ccr start` → `网关 start`），照抄必失败。现在命令不混在体检文字里，由复制按钮按原文提供（单测断言原文出现）。

### Added
- **管线管理窗口顶部新增「默认档位」区**：主对话/Opus/Sonnet/Fable/Haiku 五档各一个下拉，
  选项为全部网关线路的 provider/model 组合，经 `saveConfig`+`applyProfile` RPC 保存即生效
  （复活此前零引用的 `LineSettingsEditor`，补 onSaved 接线）。语义=全局映射，
  故固定于窗口顶部而不挂在单条线路下。
- **线路设置的模型列表结构化**（替代"一行一个"文本框）：每行勾选保留/删除，
  徽标 🔒 档位·线路默认引用（禁删）/ ⚠️ 历史 alias 引用（删后旧命令会断）/
  🟢 新发现 / ⚫ 上游未返回 / 🟡 超代建议；支持手动添加行。
- **一键拉取上游模型列表**（`ModelCatalogFetcher`，GET 模型目录接口）：
  实测 **8 条线路全部可拉**——glm/relay-z/kimi/relay-d/relay-s/relay-d-grok 直连
  `{base}/v1/models`；百炼的 Anthropic 入口（/apps/anthropic）无目录接口，但同域名
  OpenAI 兼容入口 `/compatible-mode/v1/models` 用同一把 key 可拉 16 个
  （10-02 翻案：此前误判"百炼无接口"，gh search code 证实 qwen-code/cc-switch 均用
  compatible-mode 路径；`candidateURLs` 已内置该同胞路径候补，主地址失败自动试）。
  relay-a 403 翻案（官方文档）：`/v1/models` 是其公开目录接口、Bearer 即可调，
  实测 403 body 为 `INSUFFICIENT_BALANCE`——被拒因余额不足而非"只认真实 CC 客户端"
  （那条限制的是模型**调用**接口），充值/换分组后可拉；403 文案按文档口径区分
  余额不足与分组权限。glm 无 key 时 200+鉴权错误体的假成功由"必须解析出 data[].id"拦截；
  key 只进 Authorization/x-api-key 头，错误摘要脱敏。
  ⚠️ 目录 ≠ 能调用（百炼目录含图像/语音模型），界面固定标注。
- **「获取可用模型」：名单 ∩ 前门实测，只有真通的进列表**（`ModelProber`）：拉取名单后逐个在
  **线路自己的 Anthropic 端点**（前门）打与 Claude Code 同形态的最小请求（POST /v1/messages,
  max_tokens:1，并发 4，每模型约几十 token，仅手动触发）。用户规则（10-02 拍板）：
  **✅ 实测可用才进列表；❌ 不可用与 ⚠️ 未通过验证的一律剔除**（新发现的直接从列表移除；
  已有的取消勾选、保存后移出，被档位/线路默认锁住的除外——护栏兜底）。
  侧门名单只当候选不作数，能不能用只认前门实测（一一对应）。
  百炼实测：名单 16 个 → 前门可用 11 个（含配置外的 glm-5.3 / deepseek-v4-pro /
  qwen3.7-max/plus）、图像模型 400 拒、语音模型 500 按规则剔除。
- **超代清理建议**（`ModelPruneAdvisor`，纯函数）：按模型族（去版本号归并）以族内最新版本
  为锚，落后两代及以上标 🟡「建议清理」（用户规则：3.8 出了最多留到 3.7）；
  「按建议清理」一键取消勾选未锁 🟡。护栏为保存时硬约束——用新鲜配置重算，
  待删模型被档位/线路默认引用则整笔拦下（防编辑器开着时档位被改的竞态）；
  alias 引用仅软警告（实测本机 28 个 alias 文件几乎引用每个模型，硬锁=假功能）。
  验证：纯函数 23 项单测 + 护栏对真实配置 8 项断言 + 真网逐线路拉取 E2E。

- 网关按管线生成单个启动入口；模型列表收进「管线管理」的默认模型选择器，支持手动选择持久化，刷新不覆盖。
- 线路管理增加「导入」：旧 provider / CC Switch 配置默认不选，用户确认所选项目后写入；标注网关重复配置。
- **「添加线路」保存前闭环实测（`LinePreflight`）**：用与 Claude Code 完全相同的请求形态
  （`POST {base}/v1/messages`）打一次真实最小请求，一次验证四个物理事实——端点存在、协议匹配、
  key 有效、模型名可用，任一不成立就不落盘。上游错误翻译成可行动的人话：404 指向
  "地址不说 Anthropic 协议"（而非被 Claude Code 误译成"模型不存在"）、401 提示 key 与端点
  是否配套、余额单列、200+隐式映射时明示实际路由到的模型；key 绝不回显。
  表单新增模型名必填（此前该要素整体空缺）。
  验证：`scripts/tests/preflight.swift` 17 项单测 + 真网 E2E——两起事故的原始配置
  （DeepSeek `/v1` 端点、百炼国际端点+国内 key）全部在"添加"当场被拦。
  事故背景：DeepSeek 模板端点为 OpenAI 协议，请求 404 被 Claude Code 按 Anthropic 语义
  翻译成 `model_not_found`——"模型名称问题"实为端点协议错配的**误诊**；根因是录入链路
  只传递字符串、从不查询物理现实（开环配置），错误潜伏到使用时才爆发。
- **模板计费模式（`BillingPlan`）**：同一厂商"订阅 Plan / 按量付费"是两套端点 + 两套 key，
  互不通用（实测：Kimi Coding Plan key 打按量端点 401）。添加界面提供计费模式分段选择
  （当前 Kimi 双模式），单模式厂商显示计费标签；表单展示 key 来源提示（如"百炼 Coding Plan
  key（sk-sp- 前缀）"）帮用户认对 key；落盘新增 `billing_plan` 字段。

- **管线额度追踪**：每条管线行下显示一行「套餐 · 最紧窗口剩余 · 重置时间」，点 📊 展开
  「套餐现状」（全部窗口、续费日、更新时间、↻ 立即查询）+「今日网关用量」。
  网关管线经 CCR `getConfig` RPC 取上游凭证（09-25 迁 CCR 后 `gw-*` 没有上游 key，额度一直被静默跳过）；
  新增主机规则表：GLM Coding Plan（5 小时/本周 + 套餐名/续费日）、Kimi Coding（5 小时/本周）、
  DeepSeek 人民币余额；百炼（key 实测 `ConsoleNeedLogin`）、relay-a（key 仅限 Claude Code）、
  Relay-Z 不发请求，如实标注原因 + 链接。额度带单位（美元/人民币/次数），不再一律当美元。
  statusline 第 3 行按会话模型前缀（`glm/…`）认管线，显示最紧窗口或钱包余额。
  验证：`scripts/tests/test_quota_parsers.sh` 用 10-01 真实响应夹具断言具体数值。

- **额度计划信息做全（10-02）**：行内短标签双窗口（「5 小时剩 71% · 本周剩 47%」）；
  Kimi 经 `/coding/v1/me` 显示会员档位 + 加油包月充值上限；智谱显示计费周期与续费价
  （季付 · 续费 ¥1291.2/季）；sub2api 订阅模式（有余量返窗口、用尽自动切钱包）补夹具锁死。
  relay-a 翻案：余额接口 `/v1/usage` 不限客户端（限的只是模型接口），从「官网查看」
  改为实时钱包/订阅窗口。百炼接通 ModelStudio OpenAPI（RAM AK 进钥匙串 + ACS3 签名器，
  KAT 对官方期望值逐字节通过）；个人版无额度 API，如实降级「仅控制台」。Relay-S 逆向
  完成（账号密码登录换 JWT 查 `/api/v1/user/balance`，模型 key 被 403 明确拒绝），
  凭证未配置时显示「需配置」。管线区改为每次打开默认折叠。坑与甄别纪律：PITFALLS #33-#35。
- **厂商模板三连更（10-02，官方文档口径均标注未实测）**：火山模型大换血——doubao-seed 全系
  （evolving/2.1-pro/2.1-lite/2.0-mini）+ 聚合入口（一个 key 通吃 minimax-m3/glm-5.3/kimi-k3/
  deepseek-v4），notes 警告勿配 `/api/v3`（按量端点，不消耗套餐额度而直接产生费用）；
  MiniMax 升 M3（`[1m]` 后缀 1M 上下文，注明经 CCR 须裸名）+ M Plan 订阅/按量双模式 + 国内站
  端点；**新增腾讯云 TokenHub**（`api.lkeap.cloud.tencent.com/coding/anthropic`，
  tc-code-latest，Lite ¥40/Pro ¥200，glm-5 将于 10-09 下线）。
- **MiniMax 额度接入**（`QuotaAdapters.minimaxPlan`）：`GET /v1/token_plan/remains`（Bearer 模型 key，
  国内站 `.cn` / 国际站 `.io` 均可）。此前盲探三路都没识别 → 一直错标 `notIntegrated`；
  按搜索四标准点进去 + 真 key 实测才发现接口存在。**只取百分比字段**
  （`current_interval_remaining_percent` / `current_weekly_remaining_percent`）——实测该 plan 的
  count 字段**恒为 0**，社区对"已用还是剩余"的两种相反说法都不成立；为此新增 `QuotaUnit.percent`，
  避免明细行把百分比显示成「已用 1 / 100 **次**」。`weekly_boost_permille` 语义未核实故不展示。
  验证：真实响应夹具 + 10 项断言（全库 78 条全过）。

- **存量线路周期实测（第 3 层防线，`bd28fc6`）**：启动 10 分钟后、每 6 小时经网关逐模型
  `max_tokens=8` 实测；只在「上次通 → 这次确定失败（4xx）」时发一条系统通知，从没通过的线路不报，
  5xx/429/网络异常算拿不准、不改基线。popover 管线区显示上轮结果；系统通知被关时明写出来。
  实测：伪造基线 relay-a=通 → 提醒 [relay-a]；第二轮不重复提醒。见 PITFALLS #41/#42。
- **应用图标与程序坞（`4571eda`）**：手绘 App 图标（不再显示系统「网格」占位图，`menubar/scripts/make-app-icon.swift`
  生成）；开着带标题栏的窗口时出现在程序坞、可 ⌘Tab，全关退回纯菜单栏。`ccdoctor` 新增图标检查。
  ⚠️ 开窗进程序坞 / 关窗退回 / 点程序坞图标拉回窗口**未实测**（无窗口时不在程序坞已实测）。
- **`ccdoctor`「网关路由」段（`a660dec`）**：近 24 小时 CCR 账本里「请求的模型 ≠ 实际路由」逐条列出（只读、warn）。

### Changed
- **添加表单的 🔑 说明改成「第一句说填什么 key」+ 可展开**（`fc54ad0` + 本次）：表单默认只显示第一句（到第一个「。」），
  点「详细说明…」展开其余；换厂商、换计费模式重新收起。火山三种计费模式由 #270 改成大白话（为什么会出现 Kimi/GLM 等别家名字
  紧接着说明）；其余 19 条统一成同一格式，模型名、地址、实测日期原样保留，notes 里标了「未实测」的也写进表单可见的说明。
  起因：用户在火山表单里看到大段小字和 Kimi 字样看不懂（10-09）。⚠️ 界面未实测。
- 菜单栏图标换成 SF Symbol `terminal` + 会话数（0 个会话只显示图标）。
- 菜单栏使用管线名称；默认优先 Opus，其他管线按旗舰/版本规则选型。旧逐模型入口及历史网关入口隐藏兼容，保留原额度引用与在运行会话。
- 无密钥网关线路也使用隔离设置并保留 `apiKeyHelper`；`ccstart` 与 `ccgo` 均透传固定模型参数。
- 线路测速跟随线路模型，鉴权读取在后台执行；无凭据直连旧配置只在明确导入后进入启动列表。
- 模板端点与默认模型全面实测修正（2026-09-29/30 调查）：
  - DeepSeek → `/anthropic` + `deepseek-v4-pro`（官方 `/v1/models` 名单与真 key 实测双重验证；
    chat/reasoner/coder 为兼容别名，均映射 V4.1-Flash）
  - Kimi → `api.kimi.com/coding` + `kimi-k3`（Coding Plan 端点实测 5 个模型名全通；
    `api.moonshot.cn/anthropic` 保留为按量付费模式端点）
  - 百炼 → `token-plan.cn-beijing` + `qwen3.8-max`（真 key 探测矩阵证实该端点仅
    max/flash/3.6-flash，无 coder 型号）
  - 火山 → 国内版 `ark.cn-beijing.volces.com/api/coding` + `doubao-seed-code`
    （原国际版 BytePlus 端点与国内 Coding Plan key 不配套，同百炼模式）
  - GLM → `glm-5.3`（z.ai 国际站与 bigmodel 国内站同 key 双端点实测 200）
  - MiniMax → `MiniMax-M2.7`（文档调查，无 key 未实测）

### Security
- **错误诊断发给诊断模型之前先脱敏**（`SecretRedactor`，10-09）：原来只在存历史时脱敏，发出去的是原文；
  用户粘贴的报错、「填入诊断」带进去的线路报错都可能含 key。
- 沿用接续前的交接包脱敏修复：写盘前脱敏、目录 700 / 文件 600；补充 Relay-S、GLM 与本地网关 token 形状。
- 添加、编辑、导入共用钥匙串外置与原子写入；覆盖 API token 和嵌套凭据，新增入口不回显密钥。

### Fixed
- 🔴 **管线会话的子代理 / `/model opus` / 后台小模型被 CCR 静默换成 GLM（`a660dec`）**：Claude Code 内置档位名
  （`claude-opus-5`、`claude-sonnet-5`、`claude-haiku-4-5-…`）不带线路前缀，CCR 认不出就转给 profile 默认
  `glm/glm-5.3` 并返回 200；已下架模型（旧别名 `relay-a/claude-opus-5`）同样。账本 9-26～10-03 共 1532 次。
  现由 `scripts/lib/line_models.py` 在启动时把 OPUS/FABLE/SONNET/HAIKU/SMALL_FAST 五档钉到本管线，
  只挑近 7 天账本返回过 200 的模型、缺档退主模型；主模型已不在管线里就换成管线默认并在终端提示。
  实测：修前 relay-s 会话要 opus/sonnet/haiku 三次都落 `glm/glm-5.3`；修后三次都落 `relay-s/claude-opus-5-5`（200），
  Claude Code 2.1.289 上复测一致。启动测试 24 项，换回旧代码时相关 3 项失败。见 PITFALLS #43。
- **会话编号撞号（`b0bfca7`）**：`open -a` 把 `CCPOD_SESSION_NUM` 泄漏给新启动的终端，ccgo 又把它当「复用编号」请求；
  复用改走一次性的 `CCPOD_REUSE_NUM`（登记后立即 unset）。见 PITFALLS #9b。
- **`ccdoctor` 新增「安装版 commit 标签 vs HEAD」检查**（第四条）：原先只比「安装版 vs build 产物
  hash」与「版本 vs VERSION」，**没有任何一条比 commit**——所以「构建早于提交」时（多会话共用
  工作树必现：23:12 构建于脏树、改动次日 10:48 才提交），装机标签停在旧 `HEAD`、代码已前进，
  三条检查照样全绿，而"跑的二进制是否含最新改动"无法证明却报健康。现剥离 `-dirty` 后缀后与
  `rev-parse --short HEAD` 精确比对，不符即 `bad`；读不到 HEAD / 标签 `unknown` 时只 `warn`。
  同一检查已在真实错位上先失败（打印 `❌ ... 不对应当前 HEAD de6b4c9`）、重装后通过。见 PITFALLS #36。
- 额度 sidecar `~/.claude/ccpod-quota.json` 与自动探测回写的 provider json 现在显式收紧到 600
  （`.atomic` 写会按 umask 落成 644）。
- **直连线路（Relay-D / relay-e / Relay-S 等）会话全部 401、`/model` 只见 GLM**。
  `sync_provider_settings` 把 CCR takeover 写的主 `settings.json` 原样复制进线路配置目录，
  而 settings `env` 会无条件覆盖 ccgo 注入的线路 env → 请求被改道到 CCR 3456、带的却是线路 token。
  现在复制时让线路 env 优先、换上游时剥掉主配置的模型档与 `CCR_*`、线路自带 token 时摘 `apiKeyHelper`。
  实测：同一 `claude -p --model claude-opus-5-5`，旧代码 `401 Invalid API key`，新代码返回正常
  （opus-5-5 / fable-5-1 均通）。详见 PITFALLS #24b。
- 修复两条"添加成功但一用即死"的新线路（2026-09-29 事故）：
  `deepseek.json`（端点协议错配 + 缺模型名）与 `aliyun.json`（国内 key 配国际站端点 + 缺模型名），
  均按实测修正后端到端 200 收工；弃用的 `relay-e` 线路连同钥匙串凭证一并删除。

### Removed
- **协作循环（`ccgoal`）整体退役**：删除 `scripts/ccgoal.sh`、`scripts/agent-collab.sh`、
  `docs/agent-collaboration.md`，菜单栏「启动新会话」去掉「普通 / 协作循环」切换与目标输入框。
  原因：上线 5 个月磁盘上没有一次跑进第 1 轮的记录；Claude Code 原生 `/goal` 与 codex 插件的
  收尾审查闸已覆盖同样的能力。`install.sh` 会清掉旧的 `ccgoal` 链接。
  复盘见 `docs/lessons/2026-10-05-collab-loop-retirement.md`。

## [0.3.0] - 2026-09-26

### Removed
- **自动批准（Approval Gate / AI 裁判）整体下线**。摘除 `~/.claude/settings.json` 的
  PreToolUse / PostToolUse 两条 hook；`install.sh` 第 5 节由"注册 hook"改为"摘除历史注册项"，
  重装不会装回去；`ccapproval` 移出安装清单并删除其符号链接。
  原因（用户拍板）：Claude Code 自带的权限体系已经够用，不需要再插一层；而且这一层会把
  每次工具调用的命令、路径、参数摘要发给第三方模型判断，容易侵犯用户隐私。
  `hooks/approval/` 代码与 `~/.ccpod/` 状态、审计日志暂**保留未删**（清理需单独授权）。
  注：0.2.0 时期"[Unreleased] 里那条 Approval Gate 默认开启"随之作废。

### Added
- 会话卡显示**对话标题**，优先级 `custom-title > ai-title`（与 Claude Code CLI 一致），
  无标题时退回项目名；悬停显示完整标题与项目全路径
- 会话卡新增**重命名**按钮：调用 `claude-rename`，留空即依据对话内容自动生成标题
- `scripts/claude-rename`（随 `install.sh` 落到 `~/.claude/bin/`）：改用 Claude Code 官方的
  `custom-title` 追加机制——活跃会话也安全（只追加、不改写已有字节）、无长度限制、
  优先级高于 ai-title 所以不会被自动生成覆盖
- 无终端的 claude 进程（子 agent、脚本里的 `claude -p`）以「后台」只读行展示，不再被收编
- 登记表读不出来/解析失败时，会话卡显式说出原因，不再静默显示空列表
- 全项目对抗性审查台账：两轮、含证据与修法（内部资料，未随公开版发布）

### Security
- **密钥管理整体硬化**（发布给别人用之前必须做的部分）：
  - 6 把明文密钥搬进 macOS 钥匙串，配置文件里只剩 `{"$exec": "security find-generic-password -s <service> -w 2>/dev/null"}`；
    搬家后在 **`env -u USER`** 下逐条复验（7 个 `$exec` 全部取到值）
  - `$exec` 去掉 `-a "$USER"` 依赖：GUI/launchd 环境里 `USER` 可能不存在，会静默失效
  - 新增 `SecretResolver`（Swift 侧解析 `$exec`，带 3 秒超时 + 成功 10 分钟/失败 3 分钟缓存 + 失败原因记录）
    与 `SecretRedactor`（落盘/回显脱敏，与 python 侧 `redact()` 同一套模式）
  - `install.sh` 强制凭证目录 `700`、provider json `600`，并收紧历史遗留文件
    （根因：全项目原本**没有任何一处**设过 0600，裸 `cp` 让含明文密钥的文件落成 644 世界可读）
  - `ccdoctor` 新增「密钥卫生」节；`ccpod-key doctor` 用**字段判据**而非猜前缀
    （曾只扫 `sk-`/`ark-`，漏掉 `cr_` 前缀的一把 67 字符明文，导致“0 明文”的结论是假的）
  - 历史数据脱敏 **178 处**明文密钥（`~/.ccpod/` 下 7 个文件，就地替换为 `***REDACTED***`，未删文件）
  - 「添加线路」不再生产明文：直接写钥匙串 + `$exec`，回读校验不一致就中止且不写文件
  - `Data.write(options:.atomic)` 会按 umask 落成 644 → 保存 provider 后显式收回 600
- 新增 `docs/SECURITY.md`（威胁模型 5 场景 × 残余风险，如实写明**无第三方审计、个人项目不公开用户数**）、
  `docs/SECRETS.md`（密钥架构与轮换手册）、`docs/lessons/PITFALLS.md`（28 条踩坑 + 10 条验证纪律）
- App **首次启动弹一次风险告知**（三个按钮：我已了解 / 打开完整安全说明 / 退出 ccpod），
  `SECURITY.md` 随 App bundle 分发（.zip 安装的用户没有仓库也能看）；每次启动后台跑一次密钥卫生自检，
  干净时静默、有问题才弹窗

### Removed
- 菜单栏 Swift 侧审批代码 **1421 行**（ApprovalGateService / ApprovalSettingsView / AddApprovalProviderView /
  ApprovalStatsService / ApprovalModelHelpers / ApprovalConfigService / PendingApprovalWatcher）
  与孤儿文件 `ModelService.swift`；连同上午删的 `hooks/approval/`（4616 行）等，审批功能共清除约 **7300 行**

### Fixed
- **四处静默失败 / 误导性反馈**（用户当天为此类问题投诉三次）：
  - `ProviderEditorView` 保存时用窗口打开时的整库快照写回 → 期间在 CCR 控制台改的别的线路被**静默回滚**
    （改为保存前重新 `fetchConfig`，只合并这一条线路）
  - `HealthService.beginCheck(force:)` 的 `force` 参数**声明了却从未使用** → 60 秒内点「重新检测」零反应零提示
  - `LineCheckService` 看门狗发 SIGTERM(15) 却判 `terminationStatus != 9` → 超时被误报成“脚本版本可能过旧”
  - `BalanceService` 把“余额透支”当失败冻结 6 小时且无提示 → 充值后仍显示旧透支值（透支是状态不是失败，改 1 小时）
- **`$exec` 让两个读取方失明**（迁移时只改了 2 个读取方、漏了 2 个）：
  `ProviderManagerView` 一遇到 `$exec` 就把 env 当空 → 用户在线路管理里改任何字段并保存，
  **BASE_URL 和密钥引用全被删掉**（一次点击毁一条线路）；`HealthService` 同款 → 对这些线路的
  健康检查/测速永远显示“无配置或缺少 key”，线路真挂了也发现不了
- 「密钥读取失败（钥匙串可能被锁定）」与「无配置或缺少 key」不再混成同一句提示
- `ccpod-key doctor` 新增 `$exec` **形式一致性**机械检查（三处实现曾各自漂移，后果是“命令行能启动、菜单栏显示无 key”）
- bash 全仓 12 处 `$变量` 紧跟全角字符 → `set -u` 下崩溃（其中一处让 ccdoctor 的密钥检查
  **一发现违规就崩、永远静默**）
- 风险告知弹窗的「退出 ccpod」按钮：包里没有 `SECURITY.md` 时它会变成第二个按钮，
  点击被当成“打开文档”→ 绑定失败 → **想拒绝的用户被记成已接受**（改为按 doc 是否存在动态算序号）
- `uninstall.sh` 补上 `ccpod-key` 与 `claude-rename`（原来卸载后留下死链，一个能写钥匙串的工具留在 PATH）
- **同一个对话在会话卡出现两行**：ccgo 登记的是包装 bash 的 pid，发现层又把同进程组的
  claude 子进程当"直接启动"收编（实测 4 个对话显示 7 行）→ 按进程组去重 + 每次读表自愈存量脏行
- **永久登记号被后台进程烧掉**（实测 8 分钟 158→166）→ 无 TTY 不收编；有 TTY 也要连续两轮存活
- **同项目并开两个会话显示同一个标题/模型**：详情原按"项目目录下 mtime 最新的 jsonl"解析
  → 改走 claude 原生的 `~/.claude/sessions/<pid>.json` 拿 sessionId 精确命中
- **项目目录 slug 规则错**：只把 `/` 换成 `-`，而 Claude Code 还会把 `.` `_` 空格 换成 `-`
  → `demo_project` 这类项目查不到 jsonl，模型与标题静默为空
- **登记表解析失败被当成空表、随后把空表写回文件**（"没有存活的 claude 进程"空态的根因之一）
  → 保留内存旧值、绝不写回
- **文件监听的 cancel handler 关掉的是新 fd**（use-after-close）→ 监听悄悄失灵、fd 复用后收伪事件
  → 改为捕获自己的 fd；同时消除 double close 与 handler 的 retain cycle
- **菜单栏写登记表不拿 ccgo 那把 flock 且整份覆盖** → 与 ccgo 并发时互相抹行（会话身份跳变、
  编号重分配）→ 接同一把锁，写回改为以磁盘为基准合并；ccgo 的 `unregister_session` /
  `cleanup_dead_sessions` 也补上同一把锁（此前只有 `register_session` 拿锁）
- **SessionManager 后台队列写、主线程裸读同一份容器**（偶发 EXC_BAD_ACCESS / 菜单栏无预兆重启）
  → 全部状态收进串行队列，对外只给主线程读的不可变快照
- **`eval "$(get_provider_env …)"` 吞掉取 key 失败** → claude 以无 key 状态启动并静默回落到
  `apiKeyHelper`（无限额 key），父 shell 的旧线路变量还不被 unset → 三处改赋值式捕获 + `|| die`
- **关闭会话前不验进程身份**：登记行残留期间 pid 被系统复用，`kill(-pgid, SIGKILL)` 会打掉
  无辜进程组（不可逆）→ SIGTERM 与 SIGKILL 前都验明正身（环境里的登记号 / 进程名 + TTY）
- **切线路的 pending 文件按 pid 命名**（pid 会复用，现网残留了一个 4 个月的文件）
  → 改按永不复用的登记号命名 + 消费前校验身份 + 解析失败也删除文件
- **ccgo/ccstart 的信号 handler 先 `trap -` 再清理**：清理期间第二个信号会直接打死脚本、
  注销永不执行 → 登记表僵尸行 → 幂等标志位 + 保留 trap；ccstart 顺带补上原本缺失的 reap
- 标题提取三处：尾窗起点落在中文多字节中间导致整块解码失败、取到 `<synthetic>` 占位模型名、
  全文搜 key 会被会话正文污染（只认 `"type":"ai-title"`/`"custom-title"` 记录所在行）
- 无标题会话每 5s 回扫到 8MB → 加负缓存（文件再长出 1MB 才回扫），并按存活 pid 清理缓存


### Changed
- **Breaking**: `ccuse` no longer modifies `settings.json`. It now only sets
  the default provider preference. Each CC window gets its own provider via
  env injection at launch time (per-window isolation).
- `ccgo` and `ccstart` inject provider env vars directly into the `claude`
  process instead of writing to the global `settings.json`.

### Added
- Session registry (`~/.claude/ccpod-sessions.json`): tracks all running CC
  instances with PID, TTY, provider, project, and terminal info.
- Menu bar launcher panel: select provider + project + terminal → opens a
  new terminal window with CC already running.
- Running sessions list in menu bar: shows all active CC windows, with
  one-click provider switching (auto `/quit` + relaunch).
- Terminal adapter system: Ghostty (native AppleScript), iTerm2, and
  Terminal.app support.
- `get_provider_env`, `register_session`, `unregister_session`,
  `cleanup_dead_sessions`, `detect_terminal` helpers in `common.sh`.
- **Balance display**: popover 中线路选择器和运行中会话旁实时显示余额，
  每 2 分钟自动刷新。
- **Gateway auto-detection**: `BalanceService` 首次查询时并行探测三种
  网关类型（sub2api / new-api / relay-z），结果缓存到 provider JSON 的
  `gateway` 字段，后续直接使用对应接口。
  - sub2api: `/v1/usage`（relay-e, relay-a 等）
  - new-api / one-api 系: `/v1/dashboard/billing/subscription` +
    `/v1/dashboard/billing/usage`（Relay-EC 等）
  - Relay-Z: `/api/v1/management/subscription/detail`（需 Management Key）
- **Add provider UI**: 添加线路窗口，内置国内厂商模板（MiniMax, GLM,
  火山引擎, 阿里云百炼, DeepSeek, Kimi）和通用中转站模板。
- **Add project dialog**: 通过 NSOpenPanel 选择项目目录加入列表。
- Provider config 支持 `MANAGEMENT_API_KEY` 字段（Relay-Z 等需要独立
  管理密钥的服务）。
- Persistent session numbering: `~/.claude/ccpod-session-counter` 全局
  递增，重启 app 不重置。
- **Approval Gate**: Claude Code PreToolUse hook 自动批准系统
  (`hooks/approval/`)，AI-first 判定模型：
  - Layer 3 硬红线：`rm -rf /`、`curl | sh`、`sudo`、密钥外发等不可绕过
  - 本地风险分类：只读工具、只读 Bash 管道、受限只读循环、
    构建/测试命令、安全 git 操作、可信工作区编辑仅作为 AI 信号
  - 学习规则：连续 AI 判断形成经验信号，但不绕过 AI
  - Layer 2 AI 裁判：所有非红线自动批准都必须经 Claude Opus 判断，支持
    `Relay-A` → `Relay-EC` 供应商回退，并携带 User-Agent 避免网关拦截
  - 宽松模式：只提高 AI 自动批准倾向，不再跳过 AI
  - 审计日志：所有决策写入 `~/.ccpod/approval-audit.log` (JSONL)
  - macOS 通知：高风险操作弹通知 + 声音提醒
  - 菜单栏集成：每个 session 行显示「自动批准」开关
  - CLI 工具：`ccapproval log/status/on/off/stats/doctor/ai-test/suggest`
  - 218 个测试（41 红线 + 100 规则 + 5 hook + 52 AI 裁判 + 20 学习规则）

### Removed
- `WebLoginController.swift`: 移除 JWT 登录流程，所有余额查询统一使用
  API Key 认证。

### Fixed
- Provider env leakage: switching from Relay-EC to official in the same
  shell now properly unsets `ANTHROPIC_*` variables.

## [0.1.0] — 2026-04-21

### Added
- Initial repository scaffold (Phase 1)
- Core shell commands: `ccuse`, `ccstart`, `ccnow`
- Shared helpers under `scripts/lib/`
- Provider config templates: `official.json`, `Relay-EC.example.json`
- MIT license, .gitignore, README skeleton
- `install.sh` / `uninstall.sh` — symlink-based installer, idempotent, honors
  `CCPOD_BIN_DIR` and `CCPOD_CLAUDE_DIR` for sandboxed installs (Phase 2)
- Status line sidecar: every `ccuse` switch writes a pre-formatted badge to
  `~/.claude/ccpod-status.txt` for any statusline tool to `cat` inline
- `ccnow --badge` / `-b` prints the formatted badge directly (Phase 3a)
- Native Swift menu bar app (`menubar/`): shows current provider, one-click
  switch, auto-refreshes when CLI changes the provider. Built via
  `menubar/build.sh` → `menubar/build/CCPod.app` (Phase 3b)
- `ccuse` now accepts unique prefixes — `ccuse off` / `ccuse easy` (Phase 4a)
- New `ccgo` command: switch provider + `cd` + launch `claude` in one shot,
  with substring fuzzy-match against recent CC projects (Phase 4a)
