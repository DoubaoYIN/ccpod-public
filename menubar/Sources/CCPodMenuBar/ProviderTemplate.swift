import Foundation

struct ProviderTemplate {
    let id: String
    let displayName: String
    let category: Category
    let envKeys: [EnvField]
    let notes: String
    /// 计费模式变体：同一厂商"订阅 Plan"和"按量付费"是两套端点+两套 key，互不通用
    /// （2026-09-30 实测：Kimi Coding Plan key 打按量端点 401、百炼国内 key 打国际端点 401）。
    /// 用户选错模式的 key 会在保存前 preflight 实测时被拦下并提示配套问题。
    let plans: [BillingPlan]

    struct BillingPlan {
        let id: String
        /// 站别：nil=单站（不分组）；"国内站"/"国际站" 用于分组，国内在前、默认选中。
        /// 双站厂商（Kimi/MiniMax/百炼/智谱/火山）的订阅/按量各有国内国际两套 key+端点，跨着配必 401。
        let region: String?
        let label: String
        let baseURL: String?
        let defaultModel: String?
        /// key 从哪来、长什么样，帮用户在两种模式间认对 key
        let keyNote: String

        /// 添加表单里默认只显示第一句（到第一个「。」），其余收起、点「详细说明」才展开
        /// （2026-10-09 用户：表单下方小字太多、看不懂）。没有「。」的短说明整句显示，不给展开按钮。
        var keyNoteLead: String { Self.splitFirstSentence(keyNote).lead }
        var keyNoteRest: String { Self.splitFirstSentence(keyNote).rest }

        static func splitFirstSentence(_ text: String) -> (lead: String, rest: String) {
            guard let end = text.firstIndex(of: "。"), text.index(after: end) < text.endIndex else { return (text, "") }
            return (String(text[...end]), String(text[text.index(after: end)...]).trimmingCharacters(in: .whitespaces))
        }

        init(id: String, region: String? = nil, label: String, baseURL: String?, defaultModel: String?, keyNote: String) {
            self.id = id
            self.region = region
            self.label = label
            self.baseURL = baseURL
            self.defaultModel = defaultModel
            self.keyNote = keyNote
        }
    }

    enum Category: String, CaseIterable {
        case relay = "中转站"
        case domestic = "国内厂商"
    }

    struct EnvField {
        let envName: String
        let label: String
        let placeholder: String
        let isURL: Bool

        init(envName: String, label: String, placeholder: String, isURL: Bool = false) {
            self.envName = envName
            self.label = label
            self.placeholder = placeholder
            self.isURL = isURL
        }
    }

    func generateJSON(values: [String: String]) -> [String: Any] {
        var env: [String: String] = [:]
        for field in envKeys {
            let val = values[field.envName] ?? ""
            if field.isURL {
                env["ANTHROPIC_BASE_URL"] = val
            } else {
                env["ANTHROPIC_AUTH_TOKEN"] = val
            }
        }
        return ["env": env]
    }

    // keyNote 写法约定：第一句（到第一个「。」）只说「填什么 key、哪里办、什么开头」，表单默认只显示这一句；
    // 其余细节放后面，点「详细说明…」才展开。notes 里标了「未实测」的，keyNote 里也要说，因为表单上只看得到 keyNote。
    static let builtIn: [ProviderTemplate] = [
        ProviderTemplate(
            id: "minimax",
            displayName: "MiniMax",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "sk-cp-...")
            ],
            notes: "旗舰 MiniMax-M3。⚠️ 国内站与国际站 key 不通用（2026-10-02 实测：国内 key 打"
                + " api.minimax.io 全 401，打 api.minimax.cn 200）——按 key 的来源平台选端点。"
                + "进阶：模型名加 [1m] 后缀开 1M 上下文（实测可用，需较新版 Claude Code；经 CCR 须裸名）。",
            plans: [
                BillingPlan(id: "coding", region: "国内站", label: "M Plan 订阅",
                            baseURL: "https://api.minimax.cn/anthropic",
                            defaultModel: "MiniMax-M3",
                            keyNote: "填 platform.minimax.cn 办理的 M Plan key（sk-cp- 开头）。"
                                + "国际站的 key 不能填这里，要选「国际站」那项（地址 api.minimax.io）。"),
                BillingPlan(id: "coding-intl", region: "国际站", label: "M Plan 订阅",
                            baseURL: "https://api.minimax.io/anthropic",
                            defaultModel: "MiniMax-M3",
                            keyNote: "填 platform.minimax.io 办理的 M Plan key。"
                                + "和国内站 key 不通用；这条地址没实测过（手头没有国际站 key）。"),
                BillingPlan(id: "payg", region: "国内站", label: "按量付费",
                            baseURL: "https://api.minimax.cn/anthropic",
                            defaultModel: "MiniMax-M3",
                            keyNote: "填 MiniMax 开放平台的按量 key。和 M Plan 订阅 key 是分开发放的两把。"),
                BillingPlan(id: "tokenplan", region: "国内站", label: "Token Plan 订阅（开发者）",
                            baseURL: "https://api.minimax.cn/anthropic",
                            defaultModel: "MiniMax-M3",
                            keyNote: "填开放平台 Token Plan 的 key（Plus/Max/Ultra 月订阅）。"
                                + "和 M Plan、按量 key 都是分开发放的；这条地址没实测过。")
            ]
        ),
        ProviderTemplate(
            id: "glm",
            displayName: "智谱 GLM",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "xxx.xxx")
            ],
            notes: "旗舰 glm-5.3，快速档 glm-5.3-flash。国内站（bigmodel）与国际站（z.ai）是两套 Coding Plan、key 不通用",
            plans: [
                BillingPlan(id: "coding", region: "国内站", label: "Coding Plan 订阅",
                            baseURL: "https://open.bigmodel.cn/api/anthropic",
                            defaultModel: "glm-5.3",
                            keyNote: "填智谱 BigModel 国内站 Coding Plan 的 key（bigmodel.cn/glm-coding 办理）。"),
                BillingPlan(id: "coding-intl", region: "国际站", label: "Coding Plan 订阅",
                            baseURL: "https://api.z.ai/api/anthropic",
                            defaultModel: "glm-5.3",
                            keyNote: "填 Z.AI 国际站 Coding Plan 的 key（z.ai 办理，美元计价）。和国内站 key 不通用。")
            ]
        ),
        ProviderTemplate(
            id: "volcengine",
            displayName: "火山引擎",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "ark-xxx")
            ],
            // 说明文字 2026-10-09 改成大白话：用户在火山表单里看到 Kimi 等别家名字看不懂（火山套餐能调别家模型），
            // 所以第一句先说「填什么 key」，为什么出现别家名字紧接着说；事实（模型、地址、实测日期）原样保留。
            // 表单里 keyNote 只显示第一句（到第一个「。」），其余点「详细说明」才展开。
            notes: "火山方舟：一把 key 除了豆包，还能用 MiniMax、GLM、Kimi、DeepSeek 等别家的模型"
                + "（minimax-m3 / glm-5.3 / kimi-k3 / deepseek-v4 全家，2026-10-03 实测 7 个模型都通）。"
                + "⚠️ 别填 https://ark.cn-beijing.volces.com/api/v3：那是按量地址，不用套餐额度、直接扣钱。"
                + "要 1M 上下文就在模型名后加 [1m]。",
            plans: [
                BillingPlan(id: "coding", region: "国内站", label: "Coding Plan 订阅",
                            baseURL: "https://ark.cn-beijing.volces.com/api/coding",
                            defaultModel: "doubao-seed-evolving",
                            keyNote: "填火山方舟 Coding Plan 的 key（ark- 开头）。"
                                + "这个套餐除了豆包也能调用别家的模型，所以说明里会出现 GLM、DeepSeek、Kimi、MiniMax 这些名字。"
                                + "实测能用：doubao-seed-evolving / doubao-seed-2.1-pro / glm-5.3 / deepseek-v4-pro / kimi-k3 / minimax-m3。"
                                + "模型名填 ark-code-latest 是让火山自动挑模型（挑了哪个看不到）。"
                                + "国际版（BytePlus）地址是 ark.ap-southeast.bytepluses.com/api/coding。"),
                BillingPlan(id: "agent", region: "国内站", label: "Agent Plan 订阅（全模态）",
                            baseURL: "https://ark.cn-beijing.volces.com/api/plan",
                            defaultModel: "doubao-seed-evolving",
                            keyNote: "填开通了 Agent Plan 的火山方舟账号的 key，地址是 /api/plan（不是 /api/coding）。"
                                + "按积分（AFP）扣，含图片、视频、向量、联网搜索等能力。"
                                + "⚠️ kimi-k3 在这个套餐里用不了（实测 404）；能用 doubao-seed-evolving / doubao-seed-2.1-pro / glm-5.3 / deepseek-v4-pro / minimax-m3。"
                                + "和 Coding Plan 能不能共用同一把 key 没实测过（火山的 key 是按账号发的，见按量付费的说明）。"),
                BillingPlan(id: "payg", region: "国内站", label: "按量付费",
                            baseURL: "https://ark.cn-beijing.volces.com/api/compatible",
                            defaultModel: "doubao-seed-2-1-pro-260628",
                            keyNote: "填火山方舟账号的 key 就行（套餐那把也能用），⚠️ 但走这个地址会直接按量扣钱。"
                                + "扣不扣套餐看地址、不看 key：同一把 key 打 /api/coding 走套餐，打这里（/api/compatible）按量扣费"
                                + "（2026-10-08 实测 Coding Plan 那把 key 打这里返回 200）。"
                                + "模型名要带版本号：doubao-seed-2-1-pro-260628 实测可用；doubao-seed-evolving 这类套餐里的名字在这里会报「未开通」"
                                + "（ModelNotOpen），要先去方舟控制台开通。")
            ]
        ),
        ProviderTemplate(
            id: "tencent",
            displayName: "腾讯云 TokenHub",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "sk-tp-xxx")
            ],
            notes: "Token Plan：通用 Lite ¥39 / Standard ¥99 / Pro ¥299，混元专属 Hy Token Plan ¥28 / ¥78 / ¥238，"
                + "按月订阅（同主账号只可购一个，可升不可降）。⚠️ 与按量 sk- key 及其 Base URL 不互通。glm-5 将于 2026-10-09 下线。"
                + "注意 tc-code-latest 是 Auto 模式（算法自动匹配模型，实际跑哪个不透明）；"
                + "模型库动态更新。2026-10-02 官方文档口径，未实测",
            plans: [
                BillingPlan(id: "tokenplan", region: "国内站", label: "Token Plan 订阅",
                            baseURL: "https://api.lkeap.cloud.tencent.com/plan/anthropic",
                            defaultModel: "tc-code-latest",
                            keyNote: "填腾讯云 TokenHub Token Plan 专属的 key（sk-tp- 开头）。"
                                + "key 在控制台 TokenHub > Token Plan 页面获取。默认模型 tc-code-latest 是让腾讯自动挑模型（挑了哪个看不到）。"
                                + "地址和模型名按 2026-10-02 官方文档，没用 key 实测过。"),
                BillingPlan(id: "payg", region: "国内站", label: "按量付费",
                            baseURL: "https://api.lkeap.cloud.tencent.com/api/anthropic",
                            defaultModel: nil,
                            keyNote: "填腾讯云知识引擎的按量 key（sk- 开头，控制台「API key 管理」创建）。"
                                + "模型名可填 glm-5 / minimax-m2.5 / kimi-k2.5 等；地址和模型名按 2026-10-02 官方文档，没用 key 实测过。")
            ]
        ),
        ProviderTemplate(
            id: "aliyun",
            displayName: "阿里云百炼",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "sk-sp-xxx")
            ],
            notes: "Token Plan 端点实测仅可调 qwen3.8-max / qwen3.8-flash / qwen3.6-flash（2026-09-30 探测矩阵）。"
                + "⚠️「一键拉取」走 compatible-mode 目录接口会列出 16 个模型（qwen3.7-max/glm-5.3/"
                + "deepseek-v4-pro 等）——目录里有 ≠ Token Plan 端点能调用，别被列表带偏，可调仍只有上述 3 个",
            plans: [
                BillingPlan(id: "tokenplan", region: "国内站", label: "Token Plan 订阅",
                            baseURL: "https://token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic",
                            defaultModel: "qwen3.8-max",
                            keyNote: "填百炼 Token Plan 的 key（sk-sp- 开头）。"
                                + "国际站的 key 要用 coding-intl.dashscope 那个地址，不能填这里。"),
                BillingPlan(id: "payg", region: "国内站", label: "按量付费",
                            baseURL: "https://dashscope.aliyuncs.com/apps/anthropic",
                            defaultModel: "qwen3-coder-plus",
                            keyNote: "填百炼通用的 API Key（sk- 开头，控制台「密钥管理」创建）。"
                                + "Token Plan 那把 sk-sp- 开头的 key 在这里用不了。")
            ]
        ),
        ProviderTemplate(
            id: "deepseek",
            displayName: "DeepSeek",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "sk-xxx")
            ],
            notes: "旗舰 deepseek-v4-pro，快速档 deepseek-flash，编程档 deepseek-coder（别名→V4.1-Flash）；无订阅 Plan",
            plans: [
                BillingPlan(id: "payg", label: "按量付费",
                            baseURL: "https://api.deepseek.com/anthropic",
                            defaultModel: "deepseek-v4-pro",
                            keyNote: "填 DeepSeek 开放平台的按量 key。")
            ]
        ),
        ProviderTemplate(
            id: "kimi",
            displayName: "Kimi",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "sk-xxx")
            ],
            notes: "旗舰 kimi-k3 / k3，最强编程档 kimi-k2.7-code，快速档 kimi-for-coding-highspeed",
            plans: [
                BillingPlan(id: "coding", region: "国内站", label: "Coding Plan 订阅",
                            baseURL: "https://api.kimi.com/coding",
                            defaultModel: "kimi-for-coding",
                            keyNote: "填 Kimi Coding Plan 的 key（platform.kimi.ai 办理）。"
                                + "模型名默认 kimi-for-coding（cc-switch 的写法），kimi-k3 也实测能用。"),
                BillingPlan(id: "payg", region: "国内站", label: "按量付费",
                            baseURL: "https://api.moonshot.cn/anthropic",
                            defaultModel: "kimi-k2.7-code",
                            keyNote: "填 Moonshot 开放平台的按量 key。"
                                + "Coding Plan 那把 key 在这里用不了（实测 401）；编程最强的是 kimi-k2.7-code。")
            ]
        ),
        ProviderTemplate(
            id: "baidu",
            displayName: "百度千帆",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "xxxx")
            ],
            notes: "Coding Plan 与 Token Plan 是两个不同订阅、两个端点（cc-switch 口径）。"
                + "通用 Token 池可调 GLM-5.3 / ERNIE-5.1 / DeepSeek-V4 等。"
                + "⚠️ 端点与模型名来自 cc-switch 预设 + 官方文档，未用 key 实测（2026-10-03）",
            plans: [
                BillingPlan(id: "coding", label: "Coding Plan 订阅",
                            baseURL: "https://qianfan.baidubce.com/anthropic/coding",
                            defaultModel: "qianfan-code-latest",
                            keyNote: "填百度千帆 Coding Plan 的 key。"
                                + "地址是 /anthropic/coding；模型名 qianfan-code-latest 是动态模型（由千帆自动分配）。"
                                + "地址和模型名来自 cc-switch 预设和官方文档，没用 key 实测过（2026-10-03）。"),
                BillingPlan(id: "tokenplan", label: "Token Plan 订阅",
                            baseURL: "https://qianfan.baidubce.com/anthropic/tokenplan/personal",
                            defaultModel: "deepseek-v4-pro",
                            keyNote: "填百度千帆 Token Plan 个人版的 key。"
                                + "地址是 /anthropic/tokenplan/personal，模型池含 deepseek、glm 等。"
                                + "地址和模型名来自 cc-switch 预设和官方文档，没用 key 实测过（2026-10-03）。")
            ]
        ),
        ProviderTemplate(
            id: "meituan",
            displayName: "美团 LongCat",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "sk-xxx")
            ],
            notes: "LongCat-2.0 / 2.5-Preview，1.6T 参数、1M 上下文。资源包（9.9元/5000万 Token、399元/10亿）"
                + "+ 按量（缓存命中输入 ¥0.04/百万）。⚠️ 端点与模型名来自官方文档/社区教程，未用 key 实测",
            plans: [
                BillingPlan(id: "payg", label: "按量 / 资源包",
                            baseURL: "https://api.longcat.chat/anthropic",
                            defaultModel: "LongCat-2.0",
                            keyNote: "填 LongCat 开放平台的 APP_KEY（创建时只显示一次，要当场存好）。"
                                + "Anthropic 地址是 api.longcat.chat/anthropic；地址和模型名来自官方文档和社区教程，没用 key 实测过。")
            ]
        ),
        ProviderTemplate(
            id: "jdcloud",
            displayName: "京东云",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "pk-xxx")
            ],
            notes: "TokenPlan 服务，Anthropic/OpenAI 双协议。maas-token-latest 为智能路由（自动选模型）。"
                + "⚠️ 社区反馈高峰期 429 限流、上下文偏短；端点/模型名来自官方文档，未用 key 实测",
            plans: [
                BillingPlan(id: "tokenplan", label: "TokenPlan 订阅",
                            baseURL: "https://modelservice.jdcloud.com/tokenPlan/anthropic",
                            defaultModel: "maas-token-latest",
                            keyNote: "填京东云 TokenPlan 的 key（pk- 开头，控制台订阅详情页获取）。"
                                + "这里用的是 Anthropic 协议；另有 OpenAI 协议地址 /tokenPlan/openai/v1。地址和模型名来自官方文档，没用 key 实测过。")
            ]
        ),
        ProviderTemplate(
            id: "zenmux",
            displayName: "ZenMux",
            category: .relay,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "sk-xxx")
            ],
            // 端点与模型命名来自 `gh search code`（oh-my-pi / kilocode / AIRoute 等实际项目用法）
            // + 实测 `/v1/models` 目录（201 个模型，其中 14 个 anthropic/ 命名空间）。
            // ⚠️ 未用可用 key 做过端到端：本机这把订阅 key 的套餐不含任何模型（见 notes），
            // 所以"anthropic/claude-opus-5.5 能跑通"这一点**未实测**，只证其存在于目录。
            notes: "多模型中转网关，**双协议按模型归属路由**：Anthropic 系模型（`anthropic/` 前缀）"
                + "走 Anthropic 端点，其余模型（x-ai/、google/ 等）走 OpenAI 端点——所以跨模型类型的"
                + "模型名不能混用。⚠️ 订阅制 key 只能调用**套餐内**的模型，套餐外的模型两种端点都会返"
                + " 404「not included in your subscription plan」，需另建**按量付费** key（2026-10-02 实测）。",
            plans: [
                BillingPlan(id: "payg", label: "按量付费（Anthropic 路由）",
                            baseURL: "https://zenmux.ai/api/anthropic",
                            defaultModel: "anthropic/claude-opus-5.5",
                            keyNote: "填 ZenMux 按量付费的 key（订阅制 key 调不了套餐外的模型）。"
                                + "Claude 系模型名必须带 anthropic/ 前缀，如 anthropic/claude-opus-5.5；这个模型能不能跑通没实测过（本机订阅 key 的套餐不含它）。")
            ]
        ),
        ProviderTemplate(
            id: "relay",
            displayName: "中转站",
            category: .relay,
            envKeys: [
                EnvField(envName: "base_url", label: "Base URL", placeholder: "https://api.example.com", isURL: true),
                EnvField(envName: "api_key", label: "API Key", placeholder: "sk-xxx")
            ],
            notes: "通用中转站，填入 URL、Key 和该站的模型名",
            plans: [
                BillingPlan(id: "custom", label: "按中转站计费",
                            baseURL: nil,
                            defaultModel: nil,
                            keyNote: "填中转站发给你的 key。模型名以中转站文档为准。")
            ]
        ),
    ]
}
