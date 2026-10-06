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
                            keyNote: "platform.minimax.cn 的 M Plan key（sk-cp- 前缀）；国际站 key 请换 api.minimax.io 端点"),
                BillingPlan(id: "coding-intl", region: "国际站", label: "M Plan 订阅",
                            baseURL: "https://api.minimax.io/anthropic",
                            defaultModel: "MiniMax-M3",
                            keyNote: "platform.minimax.io 的 M Plan key；与国内站 key 不通用（未实测通，需国际站 key）"),
                BillingPlan(id: "payg", region: "国内站", label: "按量付费",
                            baseURL: "https://api.minimax.cn/anthropic",
                            defaultModel: "MiniMax-M3",
                            keyNote: "MiniMax 开放平台按量 key；与 M Plan 订阅 key 分开发放"),
                BillingPlan(id: "tokenplan", region: "国内站", label: "Token Plan 订阅（开发者）",
                            baseURL: "https://api.minimax.cn/anthropic",
                            defaultModel: "MiniMax-M3",
                            keyNote: "开放平台 Token Plan key（Plus/Max/Ultra 月订阅）；与 M Plan/按量 key 分开发放，端点未实测")
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
                            keyNote: "智谱 BigModel 国内站 Coding Plan key（bigmodel.cn/glm-coding 办理）"),
                BillingPlan(id: "coding-intl", region: "国际站", label: "Coding Plan 订阅",
                            baseURL: "https://api.z.ai/api/anthropic",
                            defaultModel: "glm-5.3",
                            keyNote: "Z.AI 国际站 Coding Plan key（z.ai 办理，美元计价）；与国内站 key 不通用")
            ]
        ),
        ProviderTemplate(
            id: "volcengine",
            displayName: "火山引擎",
            category: .domestic,
            envKeys: [
                EnvField(envName: "api_key", label: "API Key", placeholder: "ark-xxx")
            ],
            notes: "多模型聚合入口：一个 key 通吃 doubao-seed 全系 + minimax-m3 / glm-5.3 / kimi-k3 / "
                + "deepseek-v4 全家（2026-10-03 实测 7 模型全通）。⚠️ 勿配 https://ark.cn-beijing.volces.com/api/v3——那是按量端点，"
                + "不消耗套餐额度而直接产生费用。1M 上下文用模型名加 [1m] 后缀。",
            plans: [
                BillingPlan(id: "coding", region: "国内站", label: "Coding Plan 订阅",
                            baseURL: "https://ark.cn-beijing.volces.com/api/coding",
                            defaultModel: "doubao-seed-evolving",
                            keyNote: "火山方舟 Coding Plan key（ark- 开头）。实测可调：doubao-seed-evolving / doubao-seed-2.1-pro / glm-5.3 / deepseek-v4-pro / kimi-k3 / minimax-m3；ark-code-latest 是 Auto 智能调度（不透明）；国际版 BytePlus 端点为 ark.ap-southeast.bytepluses.com/api/coding"),
                BillingPlan(id: "agent", region: "国内站", label: "Agent Plan 订阅（全模态）",
                            baseURL: "https://ark.cn-beijing.volces.com/api/plan",
                            defaultModel: "doubao-seed-evolving",
                            keyNote: "Agent Plan 专属 key——与 Coding Plan 不共用，端点 /api/plan（不是 /api/coding）；积分制（AFP），含图像/视频/向量与联网搜索等 Harness；⚠️ 实测 Kimi-K3 不支持 Agent Plan（404），可用 doubao-seed-evolving/2.1-pro/glm-5.3/deepseek-v4-pro/minimax-m3"),
                BillingPlan(id: "payg", region: "国内站", label: "按量付费",
                            baseURL: "https://ark.cn-beijing.volces.com/api/compatible",
                            defaultModel: nil,
                            keyNote: "火山方舟平台按量 key（与 Coding/Agent 订阅 key 分开）；端点 api/compatible（cc-switch 口径），按量计费不消耗套餐额度；模型可填接入点 ID（ep-xxx）或预置模型名（cc-switch 2026-10-05 预设用 doubao-seed-2-1-pro-260628，未实测）")
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
                            keyNote: "TokenHub Token Plan 专属 key（sk-tp- 前缀，控制台 TokenHub > Token Plan 获取）"),
                BillingPlan(id: "payg", region: "国内站", label: "按量付费",
                            baseURL: "https://api.lkeap.cloud.tencent.com/api/anthropic",
                            defaultModel: nil,
                            keyNote: "知识引擎按量 key（sk- 前缀，控制台「API key 管理」创建）；模型如 glm-5 / minimax-m2.5 / kimi-k2.5")
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
                            keyNote: "百炼 Token Plan key（sk-sp- 前缀）；国际站 key 才用 coding-intl.dashscope"),
                BillingPlan(id: "payg", region: "国内站", label: "按量付费",
                            baseURL: "https://dashscope.aliyuncs.com/apps/anthropic",
                            defaultModel: "qwen3-coder-plus",
                            keyNote: "百炼通用 API Key（sk- 前缀，控制台「密钥管理」创建）；与 Token Plan 的 sk-sp- key 不通用")
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
                            keyNote: "DeepSeek 开放平台按量 key")
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
                            keyNote: "Kimi Coding Plan key（platform.kimi.ai 办理）；模型名 kimi-for-coding（cc-switch 口径，kimi-k3 亦实测可用）"),
                BillingPlan(id: "payg", region: "国内站", label: "按量付费",
                            baseURL: "https://api.moonshot.cn/anthropic",
                            defaultModel: "kimi-k2.7-code",
                            keyNote: "Moonshot 开放平台按量 key；与 Coding Plan key 不通用（实测 401）；旗舰编程档 kimi-k2.7-code")
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
                            keyNote: "百度千帆 Coding Plan key；端点 /anthropic/coding，动态模型 qianfan-code-latest"),
                BillingPlan(id: "tokenplan", label: "Token Plan 订阅",
                            baseURL: "https://qianfan.baidubce.com/anthropic/tokenplan/personal",
                            defaultModel: "deepseek-v4-pro",
                            keyNote: "百度千帆 Token Plan 个人版 key；端点 /anthropic/tokenplan/personal（模型池含 deepseek/glm 等）")
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
                            keyNote: "LongCat 开放平台 APP_KEY（创建时仅显示一次）；Anthropic 端点 api.longcat.chat/anthropic")
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
                            keyNote: "京东云 TokenPlan key（pk- 前缀，控制台订阅详情页获取）；OpenAI 端点 /tokenPlan/openai/v1")
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
                            keyNote: "ZenMux 按量付费 key（订阅 key 调不了套餐外模型）；Claude 系模型名必须带 anthropic/ 前缀")
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
                            keyNote: "模型名以中转站文档为准")
            ]
        ),
    ]
}
