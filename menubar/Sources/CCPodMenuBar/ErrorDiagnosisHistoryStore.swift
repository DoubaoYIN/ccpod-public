import Foundation

struct ErrorDiagnosisEntry: Identifiable, Codable, Equatable {
    let id: UUID
    let timestamp: Date
    let model: String
    let input: String
    let summary: String
    let providerLabel: String
    let problemLabel: String
    let action: String
    let detail: String

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        model: String,
        input: String,
        summary: String,
        providerLabel: String,
        problemLabel: String,
        action: String,
        detail: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.model = model
        self.input = input
        self.summary = summary
        self.providerLabel = providerLabel
        self.problemLabel = problemLabel
        self.action = action
        self.detail = detail
    }

    var tagLabel: String {
        let provider = providerLabel.isEmpty ? "未识别" : providerLabel
        let problem = problemLabel.isEmpty ? "未分类" : problemLabel
        return "\(provider) · \(problem)"
    }

    var timestampLabel: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateFormat = "MM-dd HH:mm"
        return fmt.string(from: timestamp)
    }
}

final class ErrorDiagnosisHistoryStore: ObservableObject {
    static let shared = ErrorDiagnosisHistoryStore()
    static let maxEntries = 20

    @Published private(set) var entries: [ErrorDiagnosisEntry] = []
    private let url: URL
    private let queue = DispatchQueue(label: "ccpod.error-diagnosis-history", qos: .utility)

    private init() {
        url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ccpod/error-diagnosis-history.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let arr = try? dec.decode([ErrorDiagnosisEntry].self, from: data) {
            entries = arr
        }
    }

    func add(_ entry: ErrorDiagnosisEntry) {
        var next = entries
        // 落盘前脱敏：input 是用户粘贴的**报错原文**，summary/action/detail 是模型据它生成的，
        // 两边都可能原样带着密钥（例如 `curl -H "x-api-key: sk-…"` 的失败输出）。
        // 历史文件长期留存，一次粘贴 = 密钥永久落盘——旧审批日志里实测出现过 160 处。
        next.insert(entry.redactedForStorage(), at: 0)
        if next.count > Self.maxEntries {
            next = Array(next.prefix(Self.maxEntries))
        }
        entries = next
        persist()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        let snapshot = entries
        let target = url
        queue.async {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? enc.encode(snapshot) else { return }
            let dir = target.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? data.write(to: target, options: .atomic)
        }
    }
}

extension ErrorDiagnosisEntry {
    /// 把可能被模型原样抄进结论的文本字段全部脱敏；标签类字段（provider/problem）不含密钥，原样保留
    func redactedForStorage() -> ErrorDiagnosisEntry {
        ErrorDiagnosisEntry(
            id: id, timestamp: timestamp, model: model,
            input: SecretRedactor.redact(input),
            summary: SecretRedactor.redact(summary),
            providerLabel: providerLabel,
            problemLabel: problemLabel,
            action: SecretRedactor.redact(action),
            detail: SecretRedactor.redact(detail))
    }
}
