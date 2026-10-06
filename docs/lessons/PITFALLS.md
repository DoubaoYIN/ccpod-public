# ccpod 踩坑清单（可复用）

> 这份文件是**给未来的人（和未来的 agent）看的**，不是变更记录。
> 每一条都带：现象 → 根因 → 正确做法 → 怎么验证。改这个仓库之前先扫一遍。
> 来源：2026-09-26 全天 29 笔提交 + 5 轮对抗性审查的实测结果。
> 变更记录见 `CHANGELOG.md`。

---

## 一、macOS / ps / 进程：本项目最容易踩的一层

### 1. `ps` 同时请求多列时会把 `command` 截断到 16 字符
```bash
ps -o command= -o tty= -p 37548     # → "bash /Users/matt ttys003"   ← 截断了！
ps -o command= -p 37548             # → "bash /Users/yourname/.local/bin/ccgo 百炼管线 /path"  ✅
ps -ww -o command= -o tty= -p PID   # 加 -ww 也**没用**
```
**后果**：任何"命令行里含 xxx"的判据都会永远不成立。本项目曾因此让"关闭会话"的身份校验对 3/4 的会话误判成"不是自己"，**关闭按钮全线失效**。
**正确做法**：要完整命令行 + 别的字段，就**分两次 ps 调用**。

### 2. `ps eww` 读不到所有进程的环境变量
实测：ccgo 的**包装 bash** 读不到（输出里根本没有环境区），但它 fork 出来的 **claude 子进程读得到** `CCPOD_SESSION_NUM`。
**正确做法**：别把"能读到 env"当普遍前提；拿不到时要有降级判据（本项目用"命令行形态 + TTY"）。

### 3. 进程真名是 `claude.exe`，不是 `claude`
`sysctl` 的 `p_comm` 给 `claude.exe`；`ps -o comm=` 给 `claude`。**精确匹配 `"claude"` 会一个都抓不到**，而 `pgrep claude` 是模糊匹配所以能抓到——用 pgrep 验证会得出假的"没问题"。
**正确做法**：前缀匹配 `hasPrefix("claude")`；验证时用**和正式代码完全相同的读取方式**。

### 4. `sysctl KERN_PROC_ALL` 的调用姿势
3 元素 mib + nil 缓冲探测大小 → 这台机器直接 `ENOENT`。必须**预分配缓冲 + 循环 `ENOMEM` 扩容**。

### 5. pid 是临时号，会被复用；进程组才是身份
- 登记行残留最长一个清理周期（5s），这期间 pid 可能已被别的进程捡走 → `kill(-pgid, SIGKILL)` 会**打掉无辜进程组**（不可逆）。
- **杀进程前必须验明正身**：TTY 一致 + 环境里的会话号 / 命令行形态。取不到信息一律当作"不是自己"，宁可不杀。
- 任何按 pid 命名的文件（如切线路的 pending 文件）都要**改用永不复用的登记号**命名，并在消费前校验身份。

### 6. ccgo 登记的是包装 bash 的 pid，真身是同 pgid 的 claude 子进程
| 要做什么 | 该用哪个 pid |
|---|---|
| 关闭（杀整组）、就地切线路（写 pending 让包装进程重启 claude） | 包装 pid（登记表里那个） |
| 读 `~/.claude/sessions/<pid>.json` 拿 sessionId、定位会话 jsonl、TTY、模型 | **claude 子进程 pid** |
同组可能有多个 claude 前缀进程（子 agent 也是独立 claude 进程）→ 认**有 pid→sessionId 映射**的那个，并列取 pid 小的。
`github-mcp-server` 也在同组，按路径模糊匹配会把它误当 claude（`comm` 前缀匹配不会）。

### 7. Claude Code 的项目目录 slug：`/` `.` `_` 空格 **全部**换成 `-`
实证：`~/.claude/projects` 下 0 个目录含 `.` 或 `_`；`/Users/yourname/Projects/demo_project` → `-Users-yourname-Projects-demo-project`。
**只换 `/` 会让带下划线/点号的项目查不到 jsonl**，模型与标题静默变空。

### 8. `lsof -Fn` 不输出 inode
只有 `p`/`f`/`n` 三种字段。想比对运行中进程的可执行文件 inode 得换别的办法（本项目改用"进程启动时间不早于 build time"）。**写完判据要实测取值非空**，否则 `-n` 守卫会让它静默跳过 = 等于没写。

### 9. `Process` 没有 `kill()`
超时强杀要用 POSIX `kill(process.processIdentifier, SIGKILL)`；`terminate()` 发的是 SIGTERM(15)，**判 `terminationStatus != 9` 是错的**。判"被信号杀死"用 `terminationReason == .uncaughtSignal`。

### 9b. 🔴 export 的变量会泄漏到**新启动的 App**：`open -a X` 把调用者的环境整份交给 X
**现象**（2026-10-05）：两个活会话都登记成 #220。#220 的 claude 里执行过 `open -a Ghostty`，
新 Ghostty 进程环境里有 `CCPOD_SESSION_NUM=220`（`CCPOD_PROBE_X=leak123 open -g -a Ghostty` 实测 probe 也在），
它的每个新终端都继承；在里面跑 ccgo，`register_session` 把继承来的号当成"复用请求" → 撞号。
**根因**：同一个变量身兼两职——"本会话自己的号"（要传给子孙）和"请复用这个号"（只该给下一个 ccgo 看一次）。
**正确做法**：复用编号只认一次性的 `CCPOD_REUSE_NUM`（菜单栏恢复 / 切线路自动重启显式给），ccgo/ccstart 注册完立刻 `unset`；
**任何"请求类"环境变量都不要和"身份类"变量共用**。顺带：线路 env（含 key）同样会被 `open -a` 带进新 App，别在会话里 `open -a` 终端。
**验证**：`test_session_registry.py` 默认带继承的 `CCPOD_SESSION_NUM=220` 跑全部用例（旧代码 16/16 挂、全是 220）；
隔离 HOME + 假 claude 跑真 ccgo：继承 220 → 新号、显式 REUSE=205 → 205、切线路重启 → 同号，且 claude 看不到 `CCPOD_REUSE_NUM`。

---

## 二、bash：三个反复咬人的坑

### 10. 🔴 `$变量` 紧跟全角/CJK 字符 → 变量名被吃掉 → `set -u` 崩溃
```bash
bad "权限过宽（$perm，应为 600）"    # ❌ bash 把多字节字符的字节当变量名 → perm?: unbound variable
bad "权限过宽（${perm}，应为 600）"  # ✅
```
**最阴的地方**：这行只在**发现违规时**才求值，所以检查"一发现问题就崩溃、永远静默"。
**扫描命令**（改完 shell 必跑）：
```bash
grep -rnP '\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7F]' scripts/*.sh install.sh
```
2026-09-26 全仓扫出 **12 处**。

### 11. `eval "$(cmd)"` 会吞掉 cmd 的失败
```bash
f(){ return 3; }
x="$(f)" || echo "捕获到 $?"   # ✅ 捕获到 3
eval "$(f)" && echo "rc=0"     # ❌ 失败被吞，rc=0
```
本项目曾因此让"取钥匙串 key 失败"变成静默成功 → claude 以**无 key** 启动并回落到 `apiKeyHelper` 那把无限额 key。
**正确做法**：一律 `out="$(cmd)" || die "…"`，再 `eval "$out"`。进程替换 `< <(cmd)` 同理（失败会静默丢参数）。

### 12. 信号 handler 里**不要先 `trap -`**
```bash
trap 'trap - EXIT HUP TERM; cleanup; exit 143' TERM   # ❌ 清理期间第二个信号直接打死脚本，cleanup 永不执行
```
**正确做法**：保留 trap + 幂等标志位（`CCPOD_CLEANING`），第二个信号进来直接 return；注销函数自己也要幂等（做完就把标记变量清空）。
⚠️ 诚实标注：这个竞态我**两次都没能复现**（子进程退太快，窗口早关了），修复依据是"按构造更安全"，不是"复现并修好"。

---

## 三、Swift / SwiftUI

### 13. 后台队列写、主线程读同一个 Array/Dictionary = 偶发 EXC_BAD_ACCESS
菜单栏无预兆重启的典型原因。**正确做法**：可变状态全收进一个串行队列，对外只暴露**主线程读的不可变快照**（`SessionSnapshot`）。
- 抛快照用 `main.async`（**不是 sync**），否则与主线程的 `queue.sync` 互锁
- 主线程侧的入口（`reload`/`stop`）也用 `async`：`sync` 是**排队屏障**，会等完整轮重活（每会话 2×ps+lsof）
- `notify` 会直接回调观察者，其中可能有碰 UI 的 → **不能盲目把整条链挪到后台**，要先审全部观察者

### 14. DispatchSource 的 cancel handler 不要读共享可变的 `fd`
`writeSessionsFile` 每次原子替换都触发 rename → 重建 watcher；旧 source 的 cancel handler 在别的队列上晚一步执行、读到的是**已换成新值的** `self.fd` → 把新 fd 关掉（use-after-close）：监听悄悄失灵 + fd 号被复用后收伪事件。
**正确做法**：handler 捕获自己那个 fd 常量、只 `close` 它；`fd = -1` 的清理留在队列内。事件 handler 用 `[weak source]`，否则每次重建泄漏一个 source。

### 15. `String(data:encoding:.utf8)` 遇到半个多字节字符会**整块返回 nil**
从文件中间截取窗口时，起点常落在中文的多字节序列里 → 解码失败 → 什么都取不到（实测某个会话因此模型和标题全空）。
**正确做法**：`String(decoding: bytes, as: UTF8.self)`（容错，永不 nil），再丢掉第一段残行。

### 16. `json["env"] as? [String: String]` 一遇到嵌套字典就整体失败
密钥改成 `{"$exec": …}` 之后，这个强转返回 nil → 调用方以为"这条线路没配 key"。
**同一个 bug 在 4 个地方出现过**（BalanceService / HealthService / ProviderManagerView / ModelService），修了 2 个漏了 2 个。
**正确做法**：一律 `as? [String: Any]` + `SecretResolver.value(from:)`。全仓扫描：`grep -rn 'as? \[String: String\]' menubar/`

### 17. Swift 里 `644` 是**十进制**
权限必须写 `0o644`。测试脚本写错会把 `~/.ccpod` 变成 `d-w-rwxr-T`（自己进不去、别人反而能读）。

### 18. `.atomic` 写文件会丢权限
`Data.write(to:options:.atomic)` = 临时文件 + rename，临时文件按 **umask（644）** 创建。原本 600 的凭证文件保存一次就变世界可读。
**正确做法**：写完立刻 `setAttributes([.posixPermissions: 0o600])`。

### 19. `ForEach(id: \.element.pid)` 遇到重复 pid 行为未定义
渲染前按 pid 去重兜底。

### 20. 别用 grep 二进制验证 Swift 字面量（假阴性）
Swift 字面量在 Mach-O 里的存储方式让字节搜索恒为 0 命中，**连早就存在的 UI 文案都搜不到**。验版本用 `ccdoctor`。
**但反过来**：`claude.exe` 是 Bun 编译的、内嵌**明文压缩 JS**，用 `strings` + 字节偏移提取**可以**拿到源码级证据（本项目的会话标题机制全靠这个查清）。

---

## 四、Claude Code 的会话文件（jsonl）

### 21. 标题有两种记录，`customTitle` 优先级高于 `aiTitle`
CLI 里的显示优先级：`agentName || customTitle || aiTitle || summary || firstPrompt || sessionId前8位`
```json
{"type":"custom-title","customTitle":"…","sessionId":"<uuid>"}
{"type":"ai-title","aiTitle":"…","sessionId":"<uuid>"}
```
- **必须带 `sessionId`**，否则读取时被直接忽略（`type==="custom-title" && sessionId`）
- 读取时按 sessionId 存进 Map，**后写覆盖先写** → "最后一条"即当前标题
- `ai-title` 会被反复重写（9.4MB 的会话里 278 条，平均 34KB 一条；31MB 的 122 条 ≈ 256KB 一条）→ 想从尾部窗口捞标题，窗口不能太小
- 标题**不在文件头部 8K 内**（头部是巨大的 system 上下文）
- 没有 ai-title 的会话在 `claude --resume` 里显示默认 "Claude Code"；生成是异步 LLM 调用，网关 429 时就静默没有
- 改名的正确做法 = **追加一条 custom-title**（CLI 自己的 `saveCustomTitle` 就是这么做的）：活跃会话也安全、无长度限制、不会被自动生成覆盖。工具见 `scripts/claude-rename`

### 22. 全文搜 `"aiTitle":"` 会被会话正文污染
一个 grep 过 `aiTitle` 的会话，正文里有 18 处。**只认 `"type":"ai-title"` / `"type":"custom-title"` 记录所在的那一行**。

### 23. `"model":"<synthetic>"` 是占位值，不是真模型
从尾部反向找 `"model":"` 时要拒绝它继续往前找。

### 24. `~/.claude/sessions/<claude_pid>.json` 是 pid→sessionId 的权威映射
定位"这一个对话"的 jsonl 必须走它。按"项目目录下 mtime 最新的 jsonl"猜 → **同项目并开两个会话会显示同一个标题/模型**（A 活跃时 A 恒为最新，B 行成了 A 的镜像）。

**⚠️ 它同时是会话"活性/状态"的权威来源，别和 ccpod 自己的登记表搞混**——两个文件**同名不同源**，
2026-10-02 我就查错了源，把"没有证据"说成了"查不到"：

| 文件 | 谁写的 | 字段 | 用途 |
|---|---|---|---|
| `~/.claude/sessions/<claude_pid>.json` | **Claude Code 自带** | `pid` `sessionId` `status`(**waiting**/`busy`) `updatedAt` `statusUpdatedAt` `messagingSocketPath` `entrypoint` `kind` … | 这个会话**当前在不在干活**、socket 在哪 |
| `~/.claude/ccpod-sessions.json` | **ccpod 自己** | `pid`(ccgo 包装) `tty` `num` `provider` `started_at` `terminal` `project` | 展示用登记表（编号/线路/终端） |

- 问"某个会话是不是卡住了/还在跑" → 看**前者**的 `status` + `updatedAt`。
- 问"这个对话是几号、哪条线路" → 看**后者**。
- 两者 pid **不同义**：登记表存 ccgo 包装 pid，前者的文件名是 claude 真身 pid（父进程才是包装 pid）。
- 注意该文件**只存当前状态**，历史状态不落盘——"它 9 小时没动过"这类**回溯结论无法由它单独证实**，
  要下这种结论得另有观测点（或如实标注"无法回溯验证"）。

### 24b. 🔴 `settings.json` 的 `env` **无条件覆盖**父进程 env（ccgo 注入的线路 env 会被静默改回去）
官方 env-vars#precedence："the settings file value applies … replacing the value inherited from the shell"。
主 `settings.json` 由 CCR takeover 写成 `BASE_URL=127.0.0.1:3456` + GLM 四档 + `apiKeyHelper`；
`sync_provider_settings` 早先原样复制进 `provider-configs/<线路>/` → 直连线路（Relay-D 等）
实际连的是 CCR、拿线路 token 打 CCR → **401**，`/model` 只剩 GLM 标签，还弹 "Both ANTHROPIC_AUTH_TOKEN
and apiKeyHelper set"（2026-09-27 #170）。现在复制时：线路定义的键让线路说了算；换了上游就剥掉主配置的
BASE_URL / 模型档 / `CCR_*`；线路自带 token 就摘 `apiKeyHelper`。
**判据**：`lsof -nP -a -i -p <claude pid>` 看它到底连谁——`ps eww` 里的 env 是启动时的，不是生效的。

---

## 五、密钥管理（发布给别人用的硬性约定）

### 25. 唯一规范形式（三处实现必须一致，`ccpod-key doctor` 会机械校验）
```
security find-generic-password -s <service> -w 2>/dev/null
```
- **不带 `-a "$USER"`**：GUI/launchd 环境里 `USER` 可能不存在 → 静默取不到 → 线路无声失效（服务名已唯一，各用户有各自的 login keychain）
- python 里的同族坑：`-a os.getlogin()`。经 LaunchServices 启动的 App（`open` 一个 .app）派生的子进程里，
  `os.getlogin()` 和 `logname(1)` 返回 `root`，而 `$USER`、`$LOGNAME`、`id -un`、`ps -o logname` 都还是用户名
  → `security … -a root` rc=44 → 体检误报「取不到入站 key」🟡。
  终端里跑永远复现不了，只有 App 派生的 python 才失败（2026-10-04，`line-check.py` 的 `probe_key()`，
  已改成不带 `-a`）。要复现得真造一个 .app 用 `open` 启动；**别拿 `ps -o logname` 当 `getlogin()` 的替身去验**——
  两者在这个环境里结果不同。为什么是 `root` 没查到底（「GUI 会话没有 utmp 登录记录」只是猜测）。
- 写进 json 的形式：`{"$exec": "security find-generic-password -s ccpod-line-<线路> -w 2>/dev/null"}`
- 服务名约定：`ccpod-line-<线路名>`，管理密钥加 `-mgmt`；诊断用 `ccpod-diag-<slot>`
- 创建条目要带 `-T /usr/bin/security`（否则读取时可能弹授权框，把主线程卡住）

### 26. 🔴 检测密钥**不要猜前缀**
本项目一度只用 `sk-`/`ark-`，漏了 `cr_` 前缀 → 一把 67 字符的明文既躲过搬家、也让三个 doctor 全报"干净"，"0 明文"的结论是**假的**。
**正确做法**：对结构化配置用**字段判据**（凭据形状的字段里只要是 ≥16 字符的字面量就算明文），正则只用于自由文本日志。见 `scripts/ccpod-key.sh` 的 `find_literal_credentials`。

### 27. `security -w` 的输出带尾部换行
直接 `| shasum` 会得到与 `printf '%s'` 不同的指纹——我一度以为密钥不匹配，其实是测量方法错了。**比对密钥要先 `tr -d '\n'`**。

### 28. 凭证文件与目录的权限是**代码职责**，不是人工职责
`install.sh` 用裸 `cp` / `mkdir -p` 会让文件按 umask 落成 644。所有写凭证的地方都要显式 600 / 目录 700，并 `find ! -perm 600 -exec chmod` 收紧历史遗留。`ccdoctor` 有「密钥卫生」节会盯这件事。

---

## 六、验证纪律（今晚 4 次假阳性换来的，最重要的一节）

> **核心一句：当一个检查在"失败"和"通过"时输出同样的东西，它就不是检查。**

| # | 纪律 | 今晚的反例 |
|---|---|---|
| V1 | **断言正面证据，不要断言弱信号**（退出码、0 行输出、"没报错"都是弱信号） | ccdoctor 一发现违规就崩溃、退出码 1，我把"退出码 1"当成"报出来了" |
| V2 | **反向验证必须断言消息文本/具体值出现** | 同上：改成 grep 那行违规消息才算过 |
| V3 | **在会复现失败条件的环境里验证** | 声称"去掉 `$USER` 依赖后仍能取到 key"，却在 USER 恒存在的 shell 里验；`env -u USER` 下当场失败 |
| V4 | **断言观测前提**：搜索根存在吗？进程真活着吗？ | `grep … 2>/dev/null \| wc -l` 得 0——路径根本不存在；`cp /bin/sleep` 造的假进程被内核秒杀成 `<defunct>`，没参与测试却打印 ✅ |
| V5 | **验证数据源要用与正式代码完全相同的读取方式** | 用 `pgrep claude`（模糊匹配）验证"能找到进程"，而正式代码是精确匹配 `claude`（真名 `claude.exe`）→ 假的"没问题" |
| V6 | **用诊断工具前先验证工具活着** | `log show` 在沙箱里对任何进程都返回空，几轮"日志取证"全是无效功 |
| V7 | **测试脚本自己也要被验证**，尤其当它有破坏性 | 权限测试把 `644` 当八进制（Swift 里是十进制），真的把 `~/.ccpod` 改坏了 |
| V8 | **提交信息只写实测过的事** | 写过"`keychainCommand` 已去掉 `-a "$USER"`"，而那个提交根本没碰这个文件；写过"5 个文件已改"，实际改了 4 个、漏的那个特征还不匹配 |
| V9 | **改完并发代码，要审自己引入的新失效模式** | 修 H1/H2 时引入两个高危：`flock(LOCK_EX)` 无限等锁（能冻死菜单栏且退不出去）、`stateQueue.sync` 是排队屏障。旧代码反而没这两个问题 |
| V10 | **编译器能帮你找悬空引用，就让它找** | 删 1421 行审批代码时，先 `git rm` 文件、再按编译错误逐个清（67 处），比肉眼找可靠 |
| V11 | **两处同改后变绿，功劳不能随便记**：必须做 A/B 隔离实验再归因 | 2026-09-30 E2E 卡死，我同时改了 session 持有方式和 harness 死锁两处，变绿后把功劳记给"URLSession 必须长持有"并准备写进坑清单；A/B 隔离实验（唯一差异：session 是否长期持有）证明**局部 session 的回调照样到达**，真凶是 harness 阻塞了主线程 |

### 自检清单（每次宣布"已验证"之前过一遍）
1. 这个 ✅ 到底**比对了什么**？
2. 如果它坏了，这条命令会输出**什么不同的东西**？答不出来 = 不是检查
3. 我验证的环境，**能复现失败条件**吗？
4. 我断言的是**消息/值**，还是退出码/行数？
5. 测试用的那个东西（进程、文件、路径）**真的存在过**吗？
6. 提交信息里每一句"已修/已验证"，都有对应的实测输出吗？

---

## 七、本项目的设计不变量（改之前必读）

1. `settings.json` 只许 CCR daemon 写；人只通过 CCR profile 层或菜单栏的「线路设置」编辑器
2. 写 CCR 只走 daemon RPC（`getConfig → saveConfig → applyProfile`），**永不直写 `config.sqlite`**
3. `saveConfig` 默认自带 `applyProfile`（反汇编官方 `cli.js` 确认：`t?.applyProfile!==false && await Mw(o,s)`），所以只调 `saveConfig` 不是漏了一步
4. 写登记表/计数器必须拿 `~/.claude/ccpod-session-counter.lock` 这把 flock（ccgo 与菜单栏共用），且**以磁盘为基准合并**（只删本轮判定该删的 pid），绝不用内存快照整份覆盖
5. `withRegistryLock` **不可嵌套**（flock 按 fd 计，同线程两个 fd 会自己等自己）
6. 密钥明文只允许在三处：CCR sqlite、钥匙串、`~/.ccpod` 归档（0600）
7. 登记表读/解析失败**绝不当成空表**、绝不写回（那是"没有存活的 claude 进程"空态的根因，用户投诉过两次）
8. 对上游健康接口**只信状态码，不挑响应体措辞**（CCR 的 `status` 从 `"ok"` 变成过 `"running"`，挑措辞导致整晚误报离线）
9. 永久登记号只对应真实对话：无 TTY 的进程（子 agent / 脚本里的 `claude -p`）只展示不收编；有 TTY 的也要连续两轮存活
10. UI 措辞不能像报错；能力边界要如实标注，**不做假功能**（按钮在、功能不灵，比明说不能做更糟）


## 八、线路同步与交接（2026-09-27）

- **跨线路继承要重新处理配置目录**：旧窗口继承下来的 `CLAUDE_CONFIG_DIR` 若指向 CCPod 自己的线路副本，切线后必须重新生成新线路副本。无 token 的网关线路也需要隔离，否则主 settings 会盖过模型；此时必须保留 `apiKeyHelper`。验证：`python3 -m unittest discover -s scripts/tests -p 'test_gateway_launch.py' -v`，使用 fake claude 捕获实际环境和参数，不调用上游。
- **厂商和模型 ID 不能与显示名混用**：`relay-z/x-ai/grok-4.7` 中只有第一个 `/` 分隔厂商，其余 `/` 属于模型 ID；写回配置不能全部替换成逗号。生成线路 ID 需加入稳定摘要避免命名空间扁平化相撞。
- **网关健康与上游可用是两件事**：无 token 的线路经主配置 helper 鉴权，不能直接判“缺 key”；本地 `/health` 成功也不能证明上游能回答。测速应使用选定模型，不再固定测旧 Opus。
- **同步只能清理自己生成的文件**：只有 `source=gateway` 的过期文件可删；异常配置和同名手动文件必须报错并保留。旧直连配置默认进导入候选，不能扫描到就自动启用。
- **交接包是会话的另一份副本**：只处理原会话不够，写交接时也要脱敏并设置权限。正面验证应检查合成凭据不出现在生成文件中，以及 700/600 的具体值；不能仅以脚本退出 0 宣布安全。

- **顶层只选管线，模型是管线的配置**：不能把厂商×模型笛卡尔积铺进启动菜单。本机 8 条管线、28 个模型不等于 28 个启动入口。默认模型优先 Opus；人工设置持久化且刷新不覆盖。模型已下线时需明确提示回退。生成 ID 只取决于管线，不因改默认模型变化；旧模型 ID 隐藏兼容，不改正在运行的会话。
- **管理服务地址不是模型 API 地址**：本机管理 `service.json` 是 3458，转发配置 `PORT` 是 3456。生成客户端 BASE_URL 必须用转发 HOST/PORT，不能直接用 RPC origin；旧自动生成配置也要同步纠正。缺配置时报错，不猜端口。

## 九、上游端点与计费模式（2026-09-29 DeepSeek/百炼事故）

### 29. 🔴 Claude Code 会把"端点协议错配的 404"误译成"模型不存在"
- 现象：线路填了 OpenAI 协议端点（如 `api.deepseek.com/v1`），Claude Code 按 Anthropic 协议请求
  `POST {base}/v1/messages`，上游返回 404（路径不存在）；Claude Code 却报 `model_not_found`
  ——"There's an issue with the selected model…"。**报错指向模型名，而请求根本没到达
  模型路由层，模型名从头到尾没被上游检查过。**
- 证据（2026-09-29）：会话 jsonl 记录 `error:"model_not_found", apiErrorStatus:404`；
  实测 `/v1/messages` 与 `/v1/v1/messages` 两种 URL 拼法均 404 空 body；端点改 `/anthropic`
  后同样的模型名即通。
- 机制说明是推断（未读 Claude Code 源码）：Anthropic 官方 API 的 404 语义是"模型不存在"，
  Claude Code 大概率按这本字典翻译了 OpenAI 网关的"路径不存在"。
- **排查"模型名称问题"先验端点协议**（`curl -X POST {base}/v1/messages`，max_tokens=1）：
  404=端点不说 Anthropic 协议；401/403=端点对而 key 不配套；400 "Model not exist" 才是真的
  模型名问题。`LinePreflight` 已按此分类做翻译，添加线路时当场拦截。

### 30. 🔴 订阅 Plan 和按量付费是两套端点+两套 key，互不通用
- 同一厂商（Kimi / 百炼 / 火山 / GLM）的"Coding Plan 订阅"与"按量付费 API"是两套体系：
  端点不同、key 不同，跨着配必 401。
- 双向对照实验（2026-09-30 实测）：
  Kimi Coding Plan key → `api.moonshot.cn/anthropic` **401**、`api.kimi.com/coding` **200**
  （kimi-k3 / k3 / kimi-k2.7-code 等 5 个模型名全通）；
  百炼国内 key → `coding-intl.dashscope` **401**（x-api-key 与 Bearer 双 header 复测，
  排除测量误差）、`token-plan.cn-beijing.maas.aliyuncs.com` **200**。
- 模板已用 `BillingPlan` 建模此差异（端点+默认模型+key 来源提示），添加界面可选计费模式；
  选错模式的 key 会被 preflight 实测拦下。

### 31. APFS 默认不区分大小写：`Data(contentsOf: "relay-d.json")` 会读到 `Relay-D.json`
- CCR 管线名全小写（`relay-d` / `relay-s`），旧直连文件是 `Relay-D.json` / `Relay-S.json`。
  按名字拼路径读文件会**静默读到另一条线路**（另一把 key、另一个账户），写回更糟——
  探测结果写进了不相干的文件。
- 做法：先对目录列表做**精确字符串匹配**再读写（`BalanceService.providerFileExists`）；
  同名时 CCR 管线优先。

### 32. bash `IFS=$'\t' read` 会合并连续 tab：空字段让后面的列整体错位
- tab 属于 IFS 空白字符，`a\t\tb` 读成两列而不是三列。2026-10-01 statusline 里 `resetAt` 为空，
  余额列吃到了单位列，所有钱包都显示 `$0.00`。
- 做法：jq 输出空字段时给占位符，或把可能为空的列放最后。
- ⚠️ 占位符别只写 `// "-"`：jq 的 `//` 只在 **null/false** 时触发，**空串 `""` 不触发**。
  2026-10-04 实测 `echo '{"tool":""}' | jq -r '.tool // "-"'` 输出空行，hook 状态文件里
  `tool:""` 让 hud CLI 的 tool 列显示成了时间戳。要么 jq 里写
  `if (.tool // "") == "" then "-" else .tool end`，要么读出来后在 shell 里补
  `[[ -z "$tool" ]] && tool="-"`。

### 33. 模型接口 403「仅限客户端」不能外推到管理/余额接口
- 2026-10-01 因 relay-a `/v1/messages` 对普通 curl 返 403（Cloudflare 按 UA 分流），把它整个
  定为「限定客户端、连额度都不查」。10-02 用户提醒后实测：**`/v1/usage` 余额接口普通 UA
  直接 200**——限制是按端点的，不是按站点的。误判让额度卡白瞎显示了一天「官网查看」。
- 做法：对「查不了」的结论，先区分是**哪个端点**查不了；下线一个功能前用最接近的真实
  请求路径实测一炮。同类教训见 #验证纪律（403 假信号曾把 relay-a 错判为死线）。

### 34. 200 也可能是「没货」：接口通 ≠ 有数据，降级文案要区分两者
- 百炼 `GetSubscriptionStats` 返回 200 + `{"Success":true}`（无 Data）——个人版没有座席数据。
  若按「非 200 即失败」写文案，界面上会显示「额度查询失败」，把「接口通了但没数据」
  和「接口坏了」混为一谈。
- 做法：HTTP 200 但解析不出主体时，降级为 `consoleOnly`/`notIntegrated`（如实说明去哪看），
  而不是 `failed`；failed 只留给传输/鉴权/服务端错误。

### 35. 开发者社区的 AI 生成文章会编造不存在的接口
- 「百炼 `bl credits balance` CLI」（npm 无 `@modelstudio/cli`，实测 404）、「个人版 7 天滚动
  限额」（官方文档实为月度 Credits）——同一篇文章里两个编造，都带着可信的代码块。
- 做法：社区口径的接口/参数/价格，引用前逐条对官方文档或实测核验；`npm view`/`curl` 一炮
  的成本远低于照着实现。取证优先级：官方 SDK 源码（`gh api` 拉 ResponseBody，wire 字段名
  比文档准）> 官方文档 > 第三方查询工具仓库（常自带逆向文档）> 社区文章。

### 36. 「构建早于提交」会让装机版停在旧 commit 标签，而 ccdoctor 全部报绿
- 2026-10-02 实测：多会话共用一个工作树，`build.sh --install` 在 23:12 构建于 `fe9a45c` 的**脏**树；
  那批改动次日 10:48 才提交成 `de6b4c9`。于是装机标签 `fe9a45c-dirty`、`HEAD` 已是 `de6b4c9`——
  **无法证明在跑的二进制等于当前代码**（构建早于提交，中间还有其他会话在动）。
- 旧 `ccdoctor` 三条检查全绿：它只比「安装版 vs build 产物 hash」与「版本 vs VERSION」，
  **没有一条比 `commit` 字段 vs `HEAD`**。这正是"运行的二进制是否含最新改动"这类问题溜过的地方。
- 做法：已加第四条检查（`scripts/ccdoctor.sh`）——剥离 `-dirty` 后缀后与 `rev-parse --short HEAD`
  精确相等，否则 `bad`；读不到 HEAD / 标签为 `unknown` 时只 `warn`（宁可漏报不误报）。
- 通用教训：**每个 ✅ 都要能回答「它到底比对了什么」**。检查之间会互相留缝，缝里的错位
  看起来和健康一模一样。修完用真实错位做反向验证（它当时真的报错），不要造假数据。

### 37. 「盲探没识别」和「第三方说会被拒」都会把你推向下错的结论
- 2026-10-02：MiniMax 的额度状态长期是 `notIntegrated`（三路盲探都没命中）。要下"它没有额度
  接口"这个结论前做功课，发现**接口一直存在**：`GET /v1/token_plan/remains`，Bearer 模型 key 即可。
  两个信号都在往错的方向指——① 盲探未识别（我们自己的探测覆盖不到）；② 第三方资料说
  「`coding_plan/remains` 拒 sk-cp- key（2062 no active token plan）」——**但那是另一个端点**。
- 做法：**「查不到」永远不等于「不存在」**。下"没有"的结论前，按搜索四标准换角度搜 + 真 key 实测；
  第三方说"某个接口拒绝某类 key"时，先确认说的是不是同一个 URL。
- 同族：PITFALLS #33（403 不能外推到别的端点）、#34（200 也可能没货）。
- 附带一条实测事实：社区对 `current_interval_usage_count` 是「已用」还是「剩余」有两种相反说法，
  实测该 plan **count 字段恒为 0**——争议本身就是空谈，**字段语义要用真实响应定案，不是投票**。

### 38. 共用一个工作树时，你会读到别人正在写的**中间态**——单次快照不能定生死
- 2026-10-02：我 `swift build` 抓到 `ProviderEditorView.swift:320` 的编译错（IIFE 里的 `$0` 缺参数），
  据此下了「**谁都不能装机**」的结论并报警。实际上作者 30 秒内就自己修好了——
  我抓到的是一张**编辑中**的快照。（同一晚我先前还踩过同一族的坑：grep 撞上另一会话写文件的中间态，
  误判 `ModelProber` "未被引用"。）
- **两次踩同一个坑**，所以这条要机械化：
  1. 判「坏没坏」要**两次间隔的稳定读数**（或直接问作者 / 等它停手），别单次快照定生死。
  2. 报警时**区分「确认的事实」与「我的推断」**：事实是"此刻读到 X 编译错"，推断是"谁都不能装机"。
     把推断当事实报出去，代价是别人被虚假阻塞。
  3. 想要可靠结论，**用隔离副本验证**（`git worktree add --detach <tmp> <commit>` 后在其中编译）——
     干净检出能确定地回答"**这个提交**能不能编译"，且完全不碰别人的工作树。
     实测：`a8fd862` 干净检出 `Build complete` + 单测全过；工作树当时却编译不过——**两者结论都对，因为状态本来就不同**。
- 根治方向：worktree-per-session（`ccworktree`），物理隔离后就没有"读到别人中间态"。

### 39. 🔴 同一个键两处写法不同（tty 全路径 vs 小名）→ 数据源从装机起就没被读到，且全程静默
- 2026-10-04：登记表 `~/.claude/ccpod-sessions.json` 存的是 `/dev/ttys002`，hook 状态文件却是
  `/tmp/claude-tab-state/ttys002.json`。`hudState` 直接拿登记表的值拼路径 →
  `/tmp/claude-tab-state//dev/ttys002.json` 永远不存在 → 「源 B」**从第一天起就没生效过**，
  会话行只能靠源 A，遇到不认识的 `waiting` 就显示 ❓。没有任何报错，因为「文件不存在」
  本来就是合法分支。
- 做法：跨组件共用的键在读取处统一归一化（这里是 `lastPathComponent`，`e00cbca`）；
  新接一个数据源时**断言它至少被读到过一次**（打一行日志或跑一次真数据），
  「没读到」和「没数据」从外面看一模一样（同族：验证纪律 4「断言观测前提」）。
- 连带的坑：改成小名后会读到**上一个会话**留在同一 tty 上的旧条子。护栏 = 条子时间戳早于
  pid-file 的 `startedAt` 就不采信；要留 5s 容差——SessionStart hook 落盘可能早于 pid-file 注册，
  不留容差会把新会话自己的第一张条子判成残留（时间差「亚秒级」是写这段代码的会话自述，本条写入时没复测）。

### 40. 改了 `~/.claude/bin/` 下的安装副本 = 改了个会被覆盖的文件
- `~/.claude/bin/claude-tab-title.sh`、`~/.claude/bin/hud` 的源码在 **session-hud 仓库**
  （`src/claude-tab-title.sh`、`src/hud.zsh`），`~/.claude/bin/` 里只是安装副本。
  2026-10-04 有会话直接改了安装副本（✳→●、补 `waiting`、补空串兜底），当场生效、测试也过，
  但源码没动 → `diff src/hud.zsh ~/.claude/bin/hud` 有差异，下次安装就把修复冲掉，且不在任何 git 历史里。
- 做法：动 `~/.claude/bin/*` 之前先找它的源码仓库；只改源码、跑它的测试、再走它的安装器。
  提交信息里也别写仓库外文件的修复（验证纪律 8）。

## 十、模型路由、线路监控与 Claude Code 升级（2026-10-05）

> 一句话：**界面上写的模型、会话自报的 modelUsage 都不是证据；唯一可信的是 CCR 账本
> `~/.claude-code-router/app-data/usage.sqlite` 里 `model`（请求的）与 `logical_model`（实际路由）。**

### 41. 「静态体检全绿」不等于线路通；而 curl 式探测对只认 Claude Code 客户端的网关**必然** 403
- 2026-10-05 同一时刻：`line-check.py --json`（只看配置）7 条全绿；`--probe` 实测 relay-s 403/503、relay-a 全 403；
  而本会话正经 CCR 走 `relay-s/claude-opus-5-5` 正常干活。探测用浏览器 UA 的裸请求，这类网关校验客户端指纹，
  探测失败**不代表线路坏了**（与 #33 同源）。
- 所以周期实测（`LineAutoProbePolicy`）只提醒「上次通 → 这次 4xx」：从没通过的线路永远不报，5xx/429/网络异常算拿不准、不改基线。
  想让这两家也被监控，只能用真 Claude Code 客户端发请求，别去伪造客户端指纹。
- 验证：`defaults read com.ccpod.menubar lineAutoProbeLastRound`（每轮留痕）；
  缩短首轮等待 `defaults write com.ccpod.menubar lineAutoProbeInitialDelaySeconds -float 15`，验完删掉。

### 42. 🔴 系统通知被关时，提醒是**静默**丢掉的
- 本机 CCPod 的通知权限是 denied：`requestAuthorization` 不弹框、直接回 `UNErrorDomain Code=1 Notifications are not allowed`，
  `add()` 也不会报错到任何人看得见的地方。审批功能下线后再没人发过通知，所以没人发现。
- 做法：每轮用 `getNotificationSettings`（只读、不弹框）查一次，denied 就在 popover 那行明写「系统通知已关」；
  状态留痕 `lineAutoProbeNotifyStatus`（1=denied 2=authorized）。打开：系统设置 → 通知 → CCPod。

### 43. 🔴 CCR 对认不出的模型名**静默换成 GLM**，还回 200——会话里照样显示 "Opus"
- 2026-10-05 用户看到 relay-s 会话标着「Opus 5」，以为没用上最好的模型。取证结果有两层：
  1. **标签是假的**：账本 `usage_events` 里该会话 1783 次请求全是 `relay-s/claude-opus-5-5`。
     Claude Code 2.1.226 不认识 Opus 5.5（2.1.280 才加），按子串 `includes("claude-opus-5")` 猜成 Opus 5。
  2. **但真泄漏存在**：管线会话里 `--model opus/sonnet/haiku`（子代理、`/model opus`、后台小模型）发的是不带前缀的
     `claude-opus-5` 等，已下架的 `relay-a/claude-opus-5` 也一样——CCR 都转给 profile 默认 `glm/glm-5.3`，200，无任何报错。
     账本里 9-26～10-03 有 1500+ 次这样的请求（sonnet 502、qwen3.8-max 585、opus-5-5 105……）。
- 修：`scripts/lib/line_models.py` 在启动时把五个档位（OPUS/FABLE/SONNET/HAIKU/SMALL_FAST）钉到本管线，
  只挑**近 7 天账本里真返回过 200** 的模型（relay-s 清单 4 个只有 opus-5-5 放行，sonnet/haiku 钉过去会全 403），
  缺档退主模型；主模型不在管线里就换成管线默认并在终端打出来。状态栏改为显示真实路由（不信 display_name）。
- 兜底监控：`ccdoctor`「网关路由」段查近 24 小时「请求的 ≠ 实际用的」。
- **升级 Claude Code 治不了泄漏**：2026-10-05 升到 2.1.289 后标签变对了（认识 Opus 5.5），但去掉档位变量再要 `opus`，
  发出的是不带前缀的 `claude-opus-5-5`，照样被 CCR 转到 `glm/glm-5.3`。档位钉死这层必须一直保留。
- 判据：看账本 `model`（请求的）与 `logical_model`（实际路由）是否一致；会话里的模型标签和 `modelUsage` 都不能当证据
  （泄漏那次 `modelUsage` 写的是 `claude-opus-5`，实际是 GLM）。

### 44. 升级 Claude Code 后新模型的思考强度**静默降档**（Opus 5.5 默认 medium）
- 2.1.226 把 opus-5-5 当 Opus 5，用其内置默认 high；升到 2.1.289 后认出 Opus 5.5，默认变 **medium**，
  且「新模型保持自身默认」——界面只在角落写 `◐ medium`，不提醒（2026-10-05 pty 实测启动画面）。
- 修：`~/.claude/settings.json` 加 `"effortLevel": "high"`（ccgo 同步设置时会带进每条管线的配置目录；`/effort` 仍可临时改）。
  三种方式实测都能把 Opus 5.5 拉到 high：`effortLevel`、`CLAUDE_CODE_EFFORT_LEVEL`、`--effort`；环境变量会锁死、不选。
- 兼容性：CCPod 读的会话文件字段（sessionId/status/startedAt/updatedAt）新旧版一致，新版只多 nameSince/peerFeatures/pidDomain。
- 测试坑：从会话里拉起的测试 claude 会继承 `CLAUDE_CODE_CHILD_SESSION`，于是**不写会话文件、不存 transcript**——要先 unset。

### 45. 🔴 从程序里起 `claude -p` 直连别的地址：`settings.json` 的 env 会把地址盖回网关，看起来像卡死
- 2026-10-05 做「新模型自动上架」时实测（#241 验证、#244 复核）：给 `claude -p` 设了 `ANTHROPIC_BASE_URL=<上游地址>` 和上游的 key，
  请求却去了本机网关——`~/.claude/settings.json` 的 `env` 块**无条件覆盖**进程环境（#24b 的同一个机制）。
  后果是三件事叠在一起：
  1. 上游的 key 被送到网关，入站鉴权 401；
  2. Claude Code 默认重试 11 次，进程一直不退，**看起来像卡死**而不是报错；
  3. 等不及把它杀掉后，全局 `~/.claude/sessions/` 里留下一个一直「忙碌」的会话文件。
- 做法（`scripts/ccmodel-probe.py`，单测 `scripts/tests/test_ccmodel_probe.sh` 逐条断言）：
  给一个**一次性的空 `CLAUDE_CONFIG_DIR`**（用完即删）；环境只留白名单（`env -i` 的效果，会话编号等一个不带）；
  `CLAUDE_CODE_MAX_RETRIES=0`；`--bare --no-session-persistence --tools ""`；标准输入接 `/dev/null`；
  超时后**连进程组一起杀**。
- 判定读 `--output-format json`：通过 =「退出码 0 且 `is_error` 明确为 false 且 `result` 去空白非空 且 `usage.output_tokens > 0`」。
  缺 `usage`、`result` 空、`is_error=false` 但 `result:""`，一律算**拿不准**（中转站可能回 200 空内容或错误页）。
  实测形态：通过 → `rc=0, is_error=false, result 非空, usage.output_tokens>0`；被上游拒绝 → `rc=1, is_error=true, api_error_status=403`。
  直连请求不经网关，**不进 CCR 账本**，别去账本里找它。
- **上游静默映射检测不到（已知限制）**：2026-10-05 实测 relay-d/claude-sonnet-5-5——`--output-format json` 的 `modelUsage` 键、
  `canonicalModel`、`--output-format stream-json --verbose` 的 `message.model` 全都等于**请求的模型名**，没有独立的上游真实模型名字段
  （Anthropic Messages API 不回显实际服务的模型）。所以上游若把不认识的名字静默映射成别的模型并回 200，客户端输出里看不出来；
  只能靠「`result` 非空 + `output_tokens>0`」挡住空回复/错误页，挡不住「真内容但换了个模型」。这条没做进判定，是已知盲区。
- 测试坑：macOS 的 `/usr/bin/python3` 是 Xcode 的转发壳，会往自己的环境里塞 `CPATH`/`SDKROOT` 等。
  用 python 写的假 `claude` 看不出调用方到底给了哪些变量，要用 bash 写。

### 46. 往网关写线路配置会**重启转发进程**，同一秒在跑的会话吃 502
- 读 CCR 3.1.1 的 `saveConfig`（`dist/main/cli.js`）：它把新旧配置里一组字段序列化后比较，**`Providers` 在比较范围内**，
  不一样就 `restart`/`start` 转发进程。所以只要改了任何线路的 `models`，网关必重启；这与要不要 `applyProfile` 无关
  （`applyProfile` 只是之后要不要重写各客户端的设置文件，可用第二个参数 `{applyProfile:false}` 关掉）。
- #241 的取证：当天两次手动往清单加模型，两次的同一秒都有活会话收到 502（2/2）。
- 所以自动上架**不**用「先加进清单再测、失败回滚」（每个候选写两次）：改成直连上游实测（#45），
  通过的攒到一轮末尾**只写一次**，并限制每天最多写 2 次。
- 「跳过 `applyProfile`」没有采用：没有证据证明新模型在不重新应用配置时也能被路由（CCR 里另有按配置档的模型白名单逻辑），
  而带着它的那条路径是线路设置窗口和手动补清单都走过的。

### 47. bash 3.2：挂了 `trap … EXIT` 的脚本因 `set -u` 崩掉时，退出码是 **0**
- 2026-10-05 写测试时撞到：`echo "…（$config）"` 里变量紧跟全角括号（#10 的老坑）→ `unbound variable` → 脚本中止，
  但 `echo $?` 是 0。三行脚本复现（macOS 自带 `GNU bash 3.2.57`）：没有 EXIT 钩子时退出码是 1；
  有 `trap 'rm -rf "$d"' EXIT` 时是 0；在钩子里写 `code=$?; …; exit $code` 也没用——钩子里读到的 `$?` 已经是 0。
- 后果：测试脚本崩在半路，调用方只看退出码会当成通过。本仓库 `scripts/tests/*.sh` 里凡是「`set -u` + `trap … EXIT`」的都有这个洞。
- 做法：用「跑到了最后」的标记判——脚本末尾置 `finished=1`，钩子里发现不是 1 就打印 `FAIL 测试脚本中途退出` 并 `exit 1`
  （`scripts/tests/test_ccmodel_probe.sh` 已这样做，并做过反向验证）。读测试结果永远认那行正面文本（「全部通过」），不认退出码。

### 48. 🔴 `pmset -b disablesleep 1` 是运行时临时覆盖，拔电源就丢；`pmset -g custom` 还**永远不显示**它
- 2026-10-06 做「合盖保持唤醒」开关时实测（macOS 27.0 / arm64）三轮拔插实验：
  `-b` 在 AC 下设置 → 拔线后电池下读回 **0**（丢了）；`-a` 在 AC 下设置 → 拔线、插回双向都**存活**。
  最坑的使用场景：插着电打开开关、拔线合盖走人 → 机器照样睡眠，**静默失效**。
- 排查被 `pmset -g custom` 误导了两轮：它的分档位视图里 Battery/AC 两边**都没有** `disablesleep` 这一项
  （即使值确实是 1 且功能正常）——读 `disablesleep` 只能看 `pmset -g` 的 `SleepDisabled` 行，custom 视图无证据价值。
- 曾怀疑过的替罪羊（都被实验排除）：第三方电源管理软件、看门狗误触发、合盖/开盖事件清值。
  结论只认证据：设置方式（-b/-a）× 设置时的电源状态，决定拔插后是否存活。
- 连锁设计修正：helper 必须用 `-a`（`scripts/sleep-switch/ccpod-sleep-switch` 头部注释有完整记录）；
  且用了 `-a` 后「接电源自动关」从无害变有害（会把用户在桌前打开的开关偷关掉，拔线后合盖即睡眠），
  看门狗改为只在**低电量**时自动关。
- 教训：电源管理 API 的语义在 Apple Silicon + 新 macOS 上会变，文档没写的部分按「先设计可区分的拔插实验，
  再下结论」处理；两次观测到「值变了」先查**是谁改的**（日志），再怀疑平台。
