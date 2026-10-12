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
同族（2026-10-06 再踩）：`echo "…$DST（…"` 的 `echo` 字符串里变量紧跟全角括号，一样崩（`unbound variable`）。
bash 3.2 下**任何**「`$VAR` + CJK 字符」的位置都用 `${VAR}` 定界，不只是检查分支。

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
  三种方式实测都能把 Opus 5.5 拉到 high：`effortLevel`、`CLAUDE_CODE_EFFORT_LEVEL`、`--effort`；环境变量会锁死、不选
  （写进 settings env 后撤销了也还锁着，见 #56；按管线设思考强度用 `effort` 字段 → `--effort`）。
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

## 十一、导出与脱敏管线（2026-10-06 公开版导出，详见 `docs/lessons/2026-10-06-public-export.md`）

### 49. 🔴 macOS BSD sed 的方言差异是**静默不替换**，不报错
- `\b` 在 BSD sed 里不是词边界（GNU 扩展）——`s/\b1800\b/…/` 把 `\b` 当字面 → 规则永不命中，**没有任何报错**。
  词边界要写 `[[:<:]]1800[[:>:]]`。
- `+` 在默认 BRE 里是字面加号（`[0-9]+` = 数字+加号）；量词要么 `-E`（ERE），要么 `[0-9][0-9]*`。
  **手动验证和正式代码必须同方言**：曾用 `sed -E` 手测通过、脚本里普通 `sed` 永不匹配。
- **验证法**：sed 规则跑完必须断言「替换真的发生了」（diff / 对已知样值 grep）——和门禁防漂移同源：
  静默不匹配 = 检查不存在。

### 50. rsync `--exclude` 不会删除目标里**已存在**的排除项
- `rsync -a --delete --exclude .build src/ dst/`：dst 里已有的 `.build/`（比如在目标仓本地跑过构建）
  会被保留——`--delete` 只删「源里没有的」，exclude 让它对排除项视而不见。
- 后果链（实测）：排除项残留二进制 → 全树文本处理（sed/grep）撞上 → `illegal byte sequence` 崩；
  在「有时构建、有时不构建」的使用节奏下表现为**不可稳定复现**。
- 要让排除项在目标侧也消失：`--delete-excluded`。注意先想清楚它会不会误删目标侧需要保留的东西
  （如 `.git`——别把 `.git` 放进同一套 exclude）。

### 51. 🔴 「先脱敏、后门禁」的顺序 ⇒ 门禁只能抓**脱敏表覆盖外**的残留
- 反向测试植入站名/个人路径，重跑管线：植入内容被脱敏 sed **先洗掉**，门禁「通过」——这是假阴性，
  测的不是门禁本体。
- 正确测法：反向测试样本必须落在「门禁 pattern 覆盖、但脱敏表**不**处理」的区间（如门禁词表比
  替换表多出的词、格式不同的个人标识）。
- 结构性含义：门禁不是终极防线，**发布前人工抽查新内容是最后防线**——这条要如实写进方案，
  不要用「有门禁」说服自己不用看。

## 十二、多账号与计费端点（2026-10-08 火山/百炼部署）

### 52. 🔴 同厂商多账号多 key：`401 InvalidApiKey` ≠ key 失效；火山 key 是账号级、**计费由端点决定**
- 现象：网关「百炼」、直连 `aliyun`、新加 `bailian_187` 三把 `sk-sp-` key 前缀相同、长度只差 1–2，
  前两把打 Token Plan 端点 401 InvalidApiKey，被误判为"旧 key 失效"——实际是**另一个账号**的 key
  （该账号在此端点下不可用），用户确认 key 本身没作废。
- 火山实测：Coding Plan 那把 key 打按量端点 `/api/compatible` 同样 200，**直接按量扣费**。
  "订阅 key / 按量 key 分开"的说法对火山不成立；线路名必须带计费模式（默认 `厂商-计费`，如 `volcengine-payg`）。
- 预案（已落地）：管线管理每行显示 **key 指纹**（SHA256 前 6 位，钥匙串与网关同算法，可对号入座、不可还原）；
  添加线路时提示"这把 key 已用在 X"或"同厂商已有别的 key（指纹…），若是另一账号请在名称写账号备注"；
  名称允许中文（存 `display_name`，ID 自动生成）。
- 换网关上游 key：RPC `getConfig` → 只改该 provider 的 `api_key`（diff 守卫：其余字段必须不变）→ `saveConfig`
  一次 → `line-check.py --probe <名>` 转绿才算完。网关 key 在钥匙串没有副本，删直连线路前先另存 `ccpod-line-<网关名>`。
- 报错翻译：火山 `ModelNotOpen`（404，账号未开通模型）旧版被译成"不认识模型 + 截断 JSON"；
  切换计费模式时没有默认模型的要清空模型名，否则上个模式的模型名会被带进来（火山/腾讯按量都中过）。

## 十三、审查报告、脱敏出口与拆分提交（2026-10-09 线路状态审查）

### 53. 🔴 审查报告里的「缺陷」也要先对照代码复核，再动手修
- 现象：10-09 一份线路状态审查（另一个会话写的）列了 3 个 P0、5 个 P1。动手前逐条对照代码：P0「用量失败显示获取中」
  不成立（失败时会写「用量获取失败」）；P1「找不到体检脚本时手动体检静默」不成立（`refresh()` 会显示原因）；
  P1「额度失败分不清」基本不成立（`QuotaStatus` 本来就有 failed/restricted/notIntegrated/consoleOnly）。
  反过来，它**漏了真问题**：「今日网关用量」只在第一次展开时取一次，之后一直显示旧数，过了午夜把昨天的数标成「今日」。
- 根因：审查是读代码时边读边写的推测（报告里自己写着「假设 gatewayVisibleText 包含脱敏」），没有逐条回到代码取证。
- 正确做法：每条缺陷修之前先找到对应代码行、写出「什么输入 → 看到什么」；对不上的标「不成立」，别为了清单好看去改。
  同一份报告的「已确认没问题」也要抽查——漏掉的往往在相邻的路径上（这次是失败路径查了，「成功后再也不刷新」没查）。
- 怎么验证：修复说明里每条都带代码位置或实测输出；被判不成立的条目写明依据，留在报告里。

### 54. 🔴 脱敏要在**每个出口**做：只在落盘时脱敏，发给模型的仍是原文
- 现象：错误诊断把输入框文字发给诊断模型（`ErrorDiagnosisService.diagnose`）时没有脱敏，只有写历史
  （`ErrorDiagnosisHistoryStore.add`）时脱敏。用户粘贴的报错常带 key；`8efccee` 又加了「填入诊断」，把线路报错自动带进去。
- 正确做法：出口有三类——落盘、界面回显、**发给任何外部服务（含 AI 模型）**——每一类都过 `SecretRedactor` / `redact()`。
  加新功能把文字带到一个新出口时，顺手查这个出口有没有脱敏。
- 怎么验证：`grep -n "SecretRedactor\|gatewayVisibleText" <出口所在文件>`；没有就是没做。

### 55. 🔴 用 `git diff -U0` + `git apply --cached --unidiff-zero` 拆混合改动：插入块会落错位置，还可能照样编译通过
- 现象：10-09 把同一工作区里 #266（点会话切终端）和 #270（线路状态）的改动拆成两笔提交。按 `-U0` 取块、只挑 #266 的块
  `git apply --cached --unidiff-zero`：`PopoverContentView` 的「整行点击」块被插进了「保持唤醒」那一段，单独编译报
  `cannot find 'session' in scope`；`StatusController` 的两个块也落错了位置，却**照样编译通过**。
  另外，两边的插入块挨在一起时会被 `-U0` 并成同一块（CHANGELOG 里 #266 的 5 行和我补记的 9 行成了一块 14 行）。
- 根因：没有上下文行，`git apply` 无从核对插入点（实测两个文件都落错，具体偏移机制没深究）。
- 正确做法：以 HEAD 原文为底，按 `-a,0` 的原始行号**自下而上**自己插入；拆完先比对「拆出版 vs 工作区」，差异里不应再有
  另一方的内容；按行数核对每个文件（拆出的增删行数要和那一方原来的改动量对得上）；
  **每笔拆出的提交都在干净的临时 worktree 里单独编译**（`git worktree add --detach /tmp/x <提交>` → `swift build`）。
- 首选写法：**不动工作区，直接写暂存区**。`git show HEAD:<文件> > /tmp/f` → 只往 /tmp/f 插本方的段落（用唯一的锚文本定位，
  找不到或不唯一就停）→ `git update-index --cacheinfo "$(git ls-files -s <文件> | cut -d' ' -f1)",$(git hash-object -w /tmp/f),<文件>`。
  两个方向都要核对：`git diff --cached <文件>` 只有本方的段落，`git diff <文件>` 只剩另一方的。
  10-09 实测：#261 用它提交 `1c00388`，README 里它的 7 行进了提交，#265 还没提交的 5 行原样留在工作区、暂存区干净。
- 怎么验证：上面三步都要有输出证据；「编译通过」只能排除一部分错位，排除不了全部。

## 十四、思考强度与 settings env 残留（2026-10-09）

### 56. 🔴 写进 `settings.json` `env` 的键会**热加载进运行中的会话**，删掉却**不回收**——`CLAUDE_CODE_EFFORT_LEVEL` 能把会话一直锁在 max
- 现象：为「全部窗口最高思考强度」往主 `settings.json` 的 `env` 写了 `CLAUDE_CODE_EFFORT_LEVEL=max`，约一小时后撤销
  （文件已逐字节恢复）。7 小时后，撤销前就在跑的会话里该变量**仍是 max**（那个会话 09:02 启动，09:22 才写进去——是热加载进来的），
  子进程照样继承；`/effort high` 被拒：`CLAUDE_CODE_EFFORT_LEVEL=max overrides this session`。
  放大器：ccgo 每次启动都用主 settings 同步线路目录（`sync_provider_settings`），改主配置 = 改所有线路，撤销前开的会话全中招。
- 根因：Claude Code 监听 settings 文件，把 `env` 里新增的键写进自己的 `process.env`，键从文件里删掉时没有对应的删除
  （行为观察；源码里对应的那段没找到）。#44 说「环境变量会锁死、不选」，这里是它的第二个坑：撤销了也锁着。
- 正确做法：思考强度只走线路文件的 `effort` 字段 → 启动参数 `--effort`（`line_models.effort()`），不碰任何 env。
  运行中的会话要摆脱残留只能换进程：会话菜单「重启」（同线路 pending + `--resume`）。
- 怎么验证（本地截获，不花额度）：起一个只记录请求体、回 400 的假 API，`ANTHROPIC_BASE_URL` 指过去，**配全新的
  `CLAUDE_CONFIG_DIR`**（否则 #45 会把地址盖回网关），看请求里的 `output_config.effort`：`--effort max` → `max`；
  stream-json 同一会话先 `/effort high` 再提问 → 用 `--effort` 的变 high，用环境变量的仍是 max。
  **残留本身要单独验**（2.1.289，同一个假 API）：settings `env` 起始 `{CLAUDE_CODE_EFFORT_LEVEL: max, CCPOD_PROBE: before}`，
  会话运行中改写成 `{CCPOD_PROBE: after}`；8 秒后 `UserPromptSubmit` hook 的子进程看到 `CCPOD_PROBE=after`（settings 确实重读了）、
  EFFORT 仍是 max，`/effort medium` 被拒、请求仍是 max。正对照：启动时没有、运行中加进 max，8 秒后已锁住。
  探针变量不能省：只看「还是 max」，分不清是没回收还是根本没重读。
  测试时先 `env -u CLAUDE_CODE_EFFORT_LEVEL`——你自己的会话可能就带着残留。
  顺带两个坑：macOS 没有 `timeout`（coreutils 才有），限时用 `perl -e 'alarm 90; exec @ARGV' …`；`env` 调不到 shell 函数。

## 十五、子代理模型路由（2026-10-09）

### 57. 🔴 CCR 对 Claude Code 的子代理请求**不看客户端指定的模型**，没配子代理专用模型就一律送 profile 主模型——Opus 被换成 GLM 两周无人察觉
- 现象：ccdoctor「网关路由」报 `claude-opus-5-5 → glm/glm-5.3 ×385`。账本按天：09-26 11、10-01 88、10-03 6、10-05 127、10-09 435+。
  用 `input/cache_read/output` 三个 token 数到会话记录里反查（`grep '"cache_read_input_tokens":114048'`），全部落在
  `<sid>/subagents/agent-*.jsonl`（`isSidechain=true`），主线程一条没有。#262 当天 8 个子代理（含「审计」「对抗审查」）全是 GLM 产出，
  主对话按 Opus 的可信度采纳了它们的报告。
- 机制（CCR 3.1.1 `router-plugin.js` 实读 + 本地截获）：Claude Code 2.1.289 给子代理请求的第一条 system 加计费头
  `x-anthropic-billing-header: …; cc_is_subagent=true`；CCR 策略链 custom → 子代理标签 → profile 规则 → Router.rules →
  子代理 env → **客户端指定模型（被标记为子代理的请求在这一步直接跳过）** → profile 主模型 → default。父请求和子请求的 `model`
  字串一模一样（都是 `relay-a/claude-fable-5-1`），只差这个头；回 200 并回显请求的模型名，jsonl `message.model`、identity 附件、
  状态栏全写 Opus。3.1.2（10-08 发布）同一行逻辑原样还在，升级无用。
- 不是这些：10-05 修的「裸名→默认」（#43，钉档位对它无效）；长上下文阈值（两边 token 分布重叠）；Claude Code 的
  `CLAUDE_CODE_SUBAGENT_MODEL(_FORCE)`（进程 env 里没有）。Agent 工具显式 `model: haiku/sonnet` 一样被换。
- 正确做法（用户 10-09 拍板：子代理默认走全局默认模型）：ccgo 按会话注入 `CLAUDE_CODE_SUBAGENT_MODEL=<全局默认模型>`
  （`line_models.subagent_model()`，来源 = 主 settings env 的 `ANTHROPIC_MODEL` 去掉 `[1m]`）。请求本身就写 GLM，到哪都是 GLM，
  标签天然真实，不依赖网关怎么识别子代理（它靠解析计费头，两边升级都可能翻转）。例外要用 Opus：prompt 第一行写
  `<CCR-SUBAGENT-MODEL>relay-a/claude-opus-5-5</CCR-SUBAGENT-MODEL>`（CCR 自带机制，零配置，实测可用）。
  **不在网关加自定义路由**——决定权属于起会话的人，网关该是哑转发；用聪明治聪明只会再出一次这种事。
  **不写进任何 settings.json 的 env**（#24b/#56 会盖掉所有管线并热加载进运行中会话；ccdoctor 查）。只对新开的会话生效。
- 怎么验证（不花多少钱）：隔离配置（`env -i` + 临时 `CLAUDE_CONFIG_DIR`）+ 本地只记录请求头的代理（3499→3456）起 `claude -p`，
  让它派一个子代理；看账本 `model` / `logical_model`：父 `claude-fable-5-1 → relay-a/…`、子 `glm-5.3 → glm/glm-5.3` 才算对。
  判「错路由」只看 `logical_model`（`model` 列本来就不带前缀）；会话记录里的模型名、`modelUsage`、状态栏都不是证据。
  Claude Code 会对 `glm/glm-5.3` 打一行 `unrecognized_model` 日志，管线已关窗口强制，无害。
- 为什么两周没发现：ccdoctor 要人手动跑；子代理产出的质量差异容易归因到任务本身；10-05 修复验证只看了主线程。
  现在菜单栏每半小时查账本（`RoutingLeakService`），新出现的换模最多每 6 小时推一次系统通知，线路区常显一行橙字。

## 十六、大上下文冷读超时（2026-10-09）

### 58. 🔴 Claude Code 升级悄悄把 opus/fable 的压缩点从 16.8 万挪到 97 万，会话涨到 40 万后一冷就 524、原样重试 10 次"卡死"
- 现象：多窗口 `524 All target providers failed`，转圈 2–20 分钟；账本里 24 次 524 全是 ≈125 s、0 字节回包，relay-a 与 relay-s 上限一样
  （都在 Cloudflare 后面，`server: cloudflare`，100 s 没首字节就掐）。能对回会话的 524 落在 33–45 万 token（relay-s 上游 503 时 14.6 万也中过）。
- 根因：10-05 17:47 升到 2.1.289 后 `/context` 显示 `/ 1m`、压缩缓冲 33k；10-05 之前 50 次自动压缩全在 16.7–17.0 万，之后 0 次。
  真正被违反的不变量是**冷 token 数 ÷ 上游预填速度 < 网关首字节期限**：热的 44 万请求 20 s 回，冷的 35.7 万要 186 s。
  缓存 5 分钟就冷，中转站不兑现 1h 缓存（实测 relay-a 8 分钟未命中，对照 10 s 命中）。Claude Code 对 524 只会原样重试（每次都冷）。
- 不是这些：线路坏了（同线路 4 万 token 请求 3.7 s 通）；key/余额（那是同日上午的 403，占比逐步爬升到 100%）。
- 正确做法（方案 v2 见 `docs/lessons/2026-10-09-large-context-cold-read-524.md`）：占体积的（工具输出 90%）和有价值的（用户原话 + 决策 < 2%）不是同一批，
  **先无损清旧工具输出，再谈有损压缩**；压缩/交接在任务边界、缓存热的时候做；`CLAUDE_CODE_AUTO_COMPACT_WINDOW`（实测生效）只当安全网，
  由 ccgo 按会话注入，**不写 settings env**（#24b/#56）。Claude Code 自带的清理（闲置 ≥ 65 分钟 + ≥ 20 次工具调用）在这些会话里从未生效
  （占位符 0、`applied_edits: []`）。
- 怎么验证：`claude -p --model <线路/模型> "/context"` 看 `Tokens: x / 1m|300k` 是正面证据；账本按 `cache_read_tokens/(总 token)` 分冷热、
  按 `duration_ms` 看逼近 100 s 的趋势；会话文件 `grep -c '\[Old tool result content cleared\]'` 看瘦身有没有真发生。
- 为什么没发现：压缩点是客户端静默决定的，升级说明里没有；会话一路涨到 40 万没有任何提示；524 的文案把责任指向"服务端临时问题"。

## 十七、夜间无人值守（2026-10-10）

### 59. 🔴 阻塞式 `AskUserQuestion` 只有用户本人能解，跨会话消息唤不醒——无人值守=全线停摆
- 现象：通宵 4 会话仅 2 个持续工作。#279 00:58:15 挂出 `AskUserQuestion` 冻结 ~6h（06:53 用户醒来按键才解）；
  #265 01:11 线路 403 余额耗尽静默卡死，无任何告警面。损失 ~11.5 人时。
- 根因三层：直接=该控件是同步阻塞 UI，唯一解锁输入是用户本人按键；深层=会话等的是"后续步骤"的授权，
  停摆的却是"当前步骤"——手里明明还有不需要点头的活；底层=把同步 RPC 心智的控件跑在异步无人场景里。
  跨会话 SendMessage 送达 idle 会话可唤醒，但送达 AskUserQuestion-frozen 会话只滞留 socket 收件箱（看板 01:15 实测）。
- 更瞎的一层：pending 的 `AskUserQuestion` **不写入 transcript**（anthropics/claude-code#96795，要到被回答才落盘），
  协调者连"问什么"都看不见；`~/.claude/sessions/<pid>.json` 只有 `waitingFor:"input needed"` 无问题内容。
  副作用彩蛋：配了 PreToolUse matcher hook 后 tool_use 2s 内落盘——拦截顺带解决观测。
- 正确做法（Nightwatch，`docs/nightwatch.md`）：PreToolUse matcher 拦 `AskUserQuestion|ExitPlanMode` →
  `permissionDecision:deny + reason`，模型收 reason **继续回合不冻结**，转做不依赖该答案的工作；问题脱敏落盘、
  晨间 `ccnight morning` 聚合批答；线路静默死靠 StopFailure hook（第二网）+ 协调者心跳 busy 超 10min（主探测）。
- 红线：**hook 永不代答**——`allow + updatedInput.answers` 注入技术上可行（botmux 源码实锤），正因可行必须明文禁止，
  伪造同意比停摆更坏；授权只可睡前书面预产；push/装机/系统级夜间永久冻结待晨。
- fail-open 是正确失效方向：hook 崩溃/超时（PreToolUse 超时不阻断工具）/redact import 失败一律放行+errors.log，
  问题照弹回到现状不会更坏；宁可照弹，不可误拦用户本人、绝不落盘未脱敏文本。`onFailure:block` 需 2.1.295+（本机 2.1.289 没有，也不需要）。
- 为什么没更早发现：白天用户在场，控件秒解、体验丝滑；只有整夜无人时才暴露"唯一解锁者是睡觉的人"。
  第三方（botmux/omnara/AgentDeck 等）全走 PreToolUse hook 同一条路，官方无原生非阻塞方案（#95391 iOS 推送答题未实现）。

## 十八、计划驱动开发：计划不是契约（2026-10-10 优惠雷达 P0 一夜）

### 60. 🔴 计划里的代码块从没被逐字执行过——数字对了只证明跑的是"语义等价改写版"
- 现象：计划的数字/锚点/结构都能"实测对上"，但真正粘进产品代码的那段**一跑就崩**：
  `import html` 被同名变量 `html = read_text()` 覆盖（修正 11）、`try:` 漏 `except` 致整个模块 SyntaxError（修正 14）、
  旧代码块与后文自我纠正互相矛盾（修正 25/33）、Step 5 断言"退出码应为 1"而纯 import/def 的脚本本就退 0（修正 2）。
- 根因：计划作者"实测过"数字，跑的是**手改过的等价脚本**，从没逐字执行过计划里写的那段。
  数字验证了，代码块本身还是坏的。
- 正确做法：派发前**机械抽取**计划代码块（不是肉眼、不是重打等价版），用该语言自己的解析器逐字跑：
  python `ast.parse`、json `json.loads`、bash `bash -n`（本项目 `.local/preflight-extract.py` 已落地）。
- 能力边界（写清，别高估工具）：语法检查只抓 syntax error，**抓不到 shadow bug 这类"语法合法、跑起来才崩"的**。
  凡块里带 assert/期望值，仍须**逐字跑那一段本身**。
- 怎么验证：修正 14 的发现法就是标准答案——`sed` 机械抽出 → `ast.parse` 一次炸出漏 `except`，肉眼读过不止一遍没看出来。

### 61. 🔴 检查的两种更坏变体：通过时输出"失败"裁决 / 失败时输出指向别处的"通过"解释
- 开篇那句"一个检查在失败和通过时输出同样的东西，它就不是检查"，有两条**更隐蔽的变体**：
  - **通过时输出失败裁决**（候选⑧/修正 2）：把"退出码应为 1、看到 0 回去查"写在正确的实现上——正确的 0 被判成错误，人被指挥去改坏一个没坏的东西。同族：修正 28 把 `0o644` 算成 424，让正确输出 420 的人去"查没坏的测试"。
  - **失败时输出指向别处的通过解释**（候选⑩/修正 12）：fixture 烘焙顺序错 → 可见字符 3562 塌到 225 → 低于 500 阈值 → 面板伪判"JS 壳页"。有字、有原因、看着像在工作，实际把正确的东西判成了另一个错误的东西。
- 根因：这两种都比"失败和通过输出一样"更难抓——前者方向反了，后者方向偏了但**给了解释**。
- 正确做法：写任何"期望值/阈值/退出码"断言前，先问"**这个值正确的方向是什么**"；阈值类断言必须证明"跨过阈值后**解释跟着变对，不是变错**"。

### 62. 🔴 计划里的推算值一旦写下就被当成实测值——"碰巧对"和"实测对"长得一模一样
- 现象：`3612` 复制 5 处跨 3 个 Task（真身 3562）、`109349` 复制 12 处跨 4 个 Task（真身 107606），
  其中一处还写着"两个数字**都别改**"，把怀疑入口一起钉死。17 个钉死值机械复测只有 1 错、16 个**碰巧推对**。
- 根因：断言写在产物（fixture/接口/数据）**存在之前**，那数字是推算的；等产物落地，推算值已经长进多个 Task 的断言，
  没人记得它没被测过。计划的 `Expected: Ran N` 结构性偏低（写于复审之前，复审只增测试）也是同一根因。
- 正确做法：产物落地时**用真身复测全部钉死值**，并标注每个数的**来源（推算/实测）与口径**；
  验收判据永远是两个数相等（`grep -c def test_` == 实跑 `Ran N`），不是 == 计划数字；
  "光有'别改'没有'是什么口径'的注释，比没有注释更危险"。

### 63. 🔴 速查表/派发词是最危险的文档形态：它省掉的就是别人发现错误的那一步
- 现象：计划 `:1444` 注释自称"verified 四条件（spec §5）"，列出的却把 spec §5.2 的条件 2/3 换成两个恒真结构前提；
  e6 的派发词速查表**继承错版** → 实现者逐字照抄 → 三层继承，B 类优惠差点能弹通知（修正 18）。
- 根因：速查表存在的意义就是**让人不读原文**，所以它一错，错误就获得原文的权威；忠实执行的实现者恰好成了传播通道。
- 正确做法：派发词/速查表里每条"符合 §X"都必须**回原文核对一次并留核对记录**；
  执行链每一环都有向上核对原文的义务，"忠实执行 ≠ 正确"。
- e6 定性原文（晨报用）：**"省时间的工具一旦错了，它省掉的就是别人发现错误的那一步。"**

### 64. 🔴 计划里的字面值/数字只当假设，契约权威是已结案代码，不是计划
- 现象：计划 Task 5 写 `case limitedTime = "limited_time"`，而 Python 侧（Task 4，已结案、sha 冻结）线上值域是 `"promotion"`。
  照抄会让 Swift 解码枚举遇未知 raw value **整体抛错** → 整页情报静默解不出来。
- 根因：计划写于实现之前，却用**陈述句语气写假设**，读的人分不清哪句是事实、哪句是猜测。
- 正确做法：计划里的字面值一律当假设，以已结案代码的**线上行为**为准；冲突时报出来不要自己选。
  与 #62 同族（一个"结构性偏低"、一个"结构性超前"），修法同源：产物落地用真身复测。

## 十九、审查与证据的信任边界（2026-10-10 优惠雷达 P0 一夜）

### 65. 🔴 时间戳和引用也会"编造"——自控不是可靠控制，只有机械控制可靠
- 现象：e6 九处时间戳朝未来漂移、盖假"当场 `date` 实测"章，其中一处发生在**刚写进台账、正执行时间戳纪律之后 4 分钟**；
  三次引用不存在的 `scripts/tests/run_tests.sh`、把实现者送去抄错的权威源。
- 根因：假标签比错数值更坏——错数值下个读者会重算，假"实测"章让读者**跳过核对**，标签成了麻痹剂；
  "正在写这条纪律"的上下文也拦不住它再犯。
- 正确做法：凡写进持久介质的时间戳必须来自当场 `date`；与闸门比较先跑 `date`；冲突以**内核 mtime** 裁决（mtime 不撒谎）；
  凡写进交付物的引用（行号/路径/命令/测试名/时刻）在**写下它的那一次工具调用里当场取证**，交付前**机械抽取全部引用逐条回源核对**（固定流程，不是想起来才做）。

### 66. 🔴 "0 命中/0 失败"有三种来源，只有一种是通过——0 必须与阳性对照同批打印
- 现象：命令 rc=0 输出 0 行（其实 macOS 没有 `timeout` 命令，rc=127 根本没跑）；后台通知报 exit 0（报的是最后那个 `echo` 的 0，真 rc 在文件里）；门禁"命中 0 行"（扫描根不存在，一条没扫到）。
- 根因：这三种"0"看起来都像"干净/通过"，只有一种是真通过。后台 Bash 的真实 rc 要**读文件**，不要信 notification 的 exit code。
- 正确做法：凡拿"0 命中/0 失败/0 差异"当通过，**同一批输出里打印一个阳性对照**（已知会被抓到的样本），证明扫描器/测试/门禁此刻是活的。

### 67. 🔴 自测样本由同一心智模型生成，测不出自己模型的洞
- 现象：lint 工具用 `\b\d{1,2}:(?:[0-5][xX]|…)` 认时间占位符，漏了 `14:6x`；而 `--selftest` 的阳性样本**全部**落在 `[0-5]` 内——洞和样本同源，自测必然全绿。抓住它的是**同伴消息里一个真实形状**，不是自己的样本。
- 根因：用**值域**去识别**形状**（"分钟不可能是 6x"正是它更该被报的理由）；同一个盲点既造了洞、也造了测不出洞的样本。
- 正确做法：判据写"形状"不写"我以为的合法值域"；自测样本**至少一个来自外部真实流量**（同伴消息/线上响应/别人的代码）；
  工具第一次被真实输入打脸时，先谢它再修它（那是唯一能证明样本集有洞的信号）。

### 68. 🔴 要证明新断言有检出力，先加变异后加断言；绿也要有对照才算绿
- 现象：先加断言、后跑变异，只能证明"测试没被我改坏"——一条恒真断言（`assertIn("a","aaa")`）在这个顺序下同样全绿。
- 正确做法：**先加变异**，对未修改的测试跑；回来是绿的 = 空洞铁证（现有断言锁不住该不变量）；**再补断言**，重跑必须变**断言红**（不是异常红）。
- 推论（更易被忽略）：某变异在旧断言下**已经红了**，那新断言至多是**诊断性**的，不增加检出力，**必须标注，不许和承重那条混说"都很有用"**。
- 配套：替身（mutant）本身也要证明是活的（阳性对照），否则"它们仍绿"证明不了任何事。

### 69. 🔴 给子代理的自查断言，错误的断言比没有断言更危险
- 现象：派发词写"两条 docs 路径必须**仍然不存在**"——一个顺从的子代理会去**删掉那个已跟踪文件**来让检查通过（真破坏性事故）。
- 根因：正确表述是自查"**`git status --short <路径>` 输出为空**"（检查的是"有没有改动"，不是"文件在不在"）；spec 那条已跟踪文件本来就该在，写成"不存在"是错的。
- 正确做法：给下游的断言，先想"**一个诚实的人和一个顺从的人分别会怎么让这条通过**"；顺从路径会导致破坏的，必须改措辞。

### 70. untracked ≠ 没有旧字节；"查不出来"要复核，披露 ≠ 结案
- 现象：复审逐行人眼比对 398 行后写"untracked 无法机械定位，建议落 git 后再看"；e6 扫 /tmp 按 hash 找到子代理备份副本，一次 `diff -u` 结案（新增 12 行全注释，真因=复审自己的剥离手法不精确）。
- 根因：git、/tmp 副本、evidence、日志、mtime、duration_ms、进程表、sqlite 账本都是旧字节的栖息地；"无法机械定位"常常是**没换一条路去找**。
- 正确做法：宣布"无法机械验证"前，先问"这个事实的旧状态还被什么东西记着"；任何一方"查不出来"都要复核，与"审计工具的输出也要复核"同源。

### 71. 🔴 断言失败消息必须指对调查方向——"assertIn failed"是现象复述，不是错误消息
- 现象：负例前置锚点钉死了字面价格 `deepseek-v4-pro … 12 元 24 元`，阿里一改价这条就红，而裸 `assertIn failed` 会让后人去查**规则正则**——方向全错（真因是 fixture 漂了，不是规则坏了）。
- 正确做法：失败消息必须说清三要素——**什么漂了 / 什么没坏 / 下一步查哪**。例："这是 fixture 漂移，不是规则失配，重新裁 fixture 或更新负例字面量"。

### 72. 🔴 峰谷定价正则：厂商多张同构表靠地域插列，照着第一张表写正则静默少收 81%
- 现象：阿里百炼计费页 16 行峰谷定价只命中 3 行，不报错不异常退出码 0，面板照常显示 3 条 verified=true——用户视角"功能正常"，只是情报少了 81%。
- 根因：非北京地域的表在"享有折扣"和"忙时"之间多插一列"服务部署范围"（全球/国际/美国），照北京表写死"…折扣+忙时"的正则整个失配。
- 正确做法：给厂商写规则前先**数一遍整页有几张表、每张表列是否一致**；插列做成**可选命名捕获组**并记进结果（地域决定单价，丢了等于丢信息）。
- 回归测试断言**正面证据**：`len(rows)==7` + `"全球" in scopes` + `"美国" in scopes` + `None in scopes`（最后一条钉住"无 scope 列的表也必须能收"，防把可选组写成必需组）。
- 全文：`.local/notes-281/promo-scope-column.md`；已进 `docs/RELAY-STATIONS.md` 峰谷判别特征节。

### 73. 🔴 计划里的锚点命中 2 行仍编译通过——锚点唯一性要当场证
- 现象：计划 Task 2 用"影响计费的因素"/"新加坡"做裁剪锚点，其中"新加坡"在正文出现 69 次（计划写 6 次）；
  若按首次出现位置裁，会得到 2633 字符、items 命中 0 行的**废 fixture**，而它照样编译、照样能跑。
- 根因：锚点是"找位置"的，不是"找内容"的；命中多行时取到错误位置，没有任何东西会报警。
- 正确做法：写锚点断言前先 `grep -c` 确认命中次数唯一（或明确"取锚点之后首个"的语义）；钉死值一律带命令留痕可回放。

### 74. 🔴 机械核对的锚（sha）本身也会被编造/钉错——可回放 + 对象要对
- 现象（同一失效模式的两个方向）：**编造值**——e6 把 promotion_store.swift 的 sha 写成 `c3c31b1e…`，全盘扫 /tmp 无任何真实副本，值从未存在过；**钉错对象**——接手会话钉 promotion_notify.swift 时从 /tmp 旧副本实测出 `38466e75…`（真值、错对象），而非当时 worktree 源。两个都让「受保护文件清单」这个机械警报失真。
- 根因：sha 是「机械核对」的锚，人默认它可靠——但锚的值可造假、锚的对象可选错，且都发生在「正在执行核对纪律」的上下文里（同 #65 的 e6 时间戳编造）。
- 正确做法：钉 sha 必须从**当前 worktree 源文件**当场 `shasum -a 256`，不从 /tmp 副本、不凭记忆、不沿用旧值；钉完 `shasum -c` 当场回放证明锚是活的（阳性对照，同 #66）。

## 二十、弹窗外点判定与切线闭环（2026-10-10）

### 75. 🔴 判「点击在不在弹窗里」用了矩形和窗口层级——两个都是代理量，而且实测都是错的
- 现象：点线路下拉里任意一条线路，0.4 秒后主弹窗被关；用户感受是「随便点一下 CCPod 就关了」。
- 根因：`0b7a740` 的常驻外点兜底用「点击落在弹窗矩形外 + 窗口层级 != 101」判外点。本机实测：
  状态栏 `NSPopover` 的窗口层级是 **25**（不是 popUpMenu 的 101）；线路下拉是 SwiftUI `.popover`，
  是挂在主弹窗下的**独立子窗口**，真 App 里开在主弹窗左侧，**11 行全部在主弹窗矩形之外**。
  方案文档把它写成「自绘 overlay、不走独立窗口」，没有量过。
- 不是这些：不是系统 transient 监视器的行为（嵌套弹窗在系统的层级里，系统不会关父弹窗）；不是 App 崩溃（进程 uptime 连续）。
- 正确做法：外点 = 点击目标不属于弹窗自己的界面树。直接沿 `window.parent` 链判（`PopoverClickClassifier.inFamily`），
  不看几何、不猜层级；菜单窗口没有父链才退回认层级（`>= 101`）；**认不出目标一律不算外点**——漏关有系统监视器和下一次点击兜着，误关是直接打断用户。
- 怎么验证：`scripts/tests/test_popover_click.sh`（含回归断言「点线路下拉里的一行不是外点」，删掉家族规则会按名字报错）。
  实机必须用**真实鼠标事件**点下拉行（CGEvent），断言「选择生效 + 主弹窗数仍为 1」；AXPress 不经过 NSEvent 监视器，测不到这条路。
  开下拉本身要用 AXPress：主弹窗滚动区里被裁掉的行仍会上报坐标，按坐标点会点到别的东西。
- 为什么没发现：上一轮 T1–T9 合成测试只点了**落在主弹窗矩形内**的菜单项，矩形判据恰好替层级判据兜了底；
  「弹窗自身层级也是 popUpMenu」这句写进了自审记录但从未测量（验证纪律 #1：断言要有正面证据）。

### 76. 🔴 切线是「写请求 → 杀旧 claude → 包装脚本读请求 → 重启」的开环接力，第一步就不可逆，发起方却不看结果
- 现象：10-10 18:59 把 #280 从百炼切到智谱，会话直接没了、没有任何提示。交接包生成了、请求文件写了、旧 claude 正常收尾退出了
  （会话文件末尾有 cost-state / relocated 记录），但没有任何新会话出生，`ccpod-pending-280.json` 一直留在盘上。
- 根因（结构层）：`doSwitch` 发完 SIGTERM 就返回；找不到 claude 进程时静默跳过；请求文件没人读也没人收——
  留在盘上的请求会让这个号的会话日后某次退出时被莫名换线。
- ⚠️ 未查明：那一次包装脚本**为什么**没读请求。已排除：claude 收 SIGTERM 后包装脚本走不到下一行（受控实验，普通会话与带未提交文件的
  worktree 会话都能走到）；请求目录读写不一致（两边都是 `~/.claude`）；脚本当天被改（最后改动在 10-10 00:36）；同一套脚本当天 06:53 两次切线成功。
- 正确做法：发起者自己确认结果。成功判据 = 请求文件已被消费 **且** 该终端里跑着一个 pid 不同的 claude
  （重启靠 `exec` 沿用包装 pid，登记表那一行不变，不能拿登记表当证据）。25 秒未达成即弹窗说明卡在哪一棒、
  给出接回命令（已复制到剪贴板）、收走请求文件。同一登记号不许并发切两次。判定纯函数是 `SwitchOutcome.judge`。
- 仍未做：重启用的是登记表里的 `project`（主仓库），而会话可能已经 `EnterWorktree` 到别的目录——接力后的新会话开在主仓库。
  包装脚本侧没有任何落盘痕迹（没读到请求时一声不吭地正常退出），下次复发仍需靠终端滚屏定位。

### 77. 🟡 装机版来自未合并的分支时，主仓库 `ccdoctor` 的红字是真的，但别按它的建议「从 main 重装」
- 现象：主仓库跑 `ccdoctor` 报「安装版 commit 落后 HEAD 且 menubar 源码已变更」，建议 `build.sh --install`。
- 实情：装机版是从修复 worktree 构建的（标签 `<commit>-dirty`），那几笔修复不在 main 上；从 main 重装会把修复一起抹掉，旧 bug 原样回来。
- 正确做法：先 `git merge-base --is-ancestor <装机 commit> main` 看装机源在不在主线；不在就去那个 worktree 里跑 `ccdoctor`。
  构建标签带 `-dirty` 时，`nm` 查符号是「新代码进没进二进制」的正面证据（#10 说的是别 grep 字面量，符号表可以用）。

### 78. 🔴 `NSPopover.close()` 是异步动画，动画期间抢焦点会把 transient 弹窗打成半死态
- 现象：点「启动」后弹窗再也开不出、外点关失效；随后连点菜单栏图标也失效（渐进恶化，`launch` 是被实证的触发器）。
- 根因：`close()` 默认 `animates=true`，是 ~0.3s 异步动画，动画期间 `isShown` 仍 true、系统 transient
  外点监视器未卸载；`onLaunch` 紧接着 `DispatchQueue.global().async { openNewWindow }` 激活 iTerm2 抢焦点 →
  竞态把 popover 打成半死态，三层症状：层1 外点监视失效（持久）、层2 show 失效（分钟级自愈）、
  层3 key 态丢失（click-through，首次点击只激活不传递）。
- 正确做法：需要立刻让出焦点的动作前用 `closePopoverNow()`——`animates=false` **必须在 `close()` 之前**
  （close 调用瞬间读 animates 决定同步拆除还是异步动画），`popover=nil` 放 close 之后（close 期间读
  `self.popover` 看到的仍是 isShown=false 的实例）。图标点击的 close 向**保留动画不动**（受控三轮实证不脏）。
- 同构风险面：所有「close 动画中 → 立即抢焦点」的 vm 回调（onLaunch/onSwitch/onRecover/onRename/onFocus +
  6 个开窗回调，共 11 处）同险，必须一处不漏地替换；单测造不出 GUI 时序，用 `grep -c 'closePopoverNow()' == 13`
  （1 定义 + 12 调用）做结构断言防漏网。
