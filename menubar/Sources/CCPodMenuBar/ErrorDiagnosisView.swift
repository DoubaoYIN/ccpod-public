import AppKit
import SwiftUI

private let errorKeywords: [String] = [
    "error", "Error", "ERROR",
    "exception", "Exception",
    "traceback", "Traceback",
    "status", "Status",
    "failed", "Failed",
    "timeout", "Timeout",
    "HTTP", "http",
    "401", "403", "404", "429", "500", "502", "503", "504", "524",
    "Cloudflare", "cloudflare",
    "overloaded_error", "invalid_api_key", "rate_limit",
]

private func clipboardLooksLikeError(_ text: String) -> Bool {
    guard text.count >= 20, text.count <= 30_000 else { return false }
    let hits = errorKeywords.filter { text.contains($0) }.count
    return hits >= 1
}

struct ErrorDiagnosisView: View {
    @ObservedObject private var history = ErrorDiagnosisHistoryStore.shared
    @State private var inputText: String = ""
    @State private var currentResult: ErrorDiagnosisResult? = nil
    @State private var isRunning: Bool = false
    @State private var errorMessage: String? = nil
    @State private var selectedEntryId: UUID? = nil
    @State private var currentModel: String = ""
    @State private var detailExpanded: Bool = false

    init() {
        if let cfg = ErrorDiagnosisService.shared.loadPrimaryConfig() {
            _currentModel = State(initialValue: cfg.model)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 220)
            Divider()
            mainPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            prefillFromClipboardIfNeeded()
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("历史").font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !history.entries.isEmpty {
                    Button(action: { history.clear(); selectedEntryId = nil }) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("清空全部历史")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            if history.entries.isEmpty {
                Spacer()
                Text("暂无历史")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(history.entries) { entry in
                            historyRow(entry)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    private func historyRow(_ entry: ErrorDiagnosisEntry) -> some View {
        let isSelected = selectedEntryId == entry.id
        return Button(action: {
            selectedEntryId = entry.id
            inputText = entry.input
            currentResult = ErrorDiagnosisResult(
                summary: entry.summary,
                providerLabel: entry.providerLabel,
                problemLabel: entry.problemLabel,
                action: entry.action,
                detail: entry.detail,
                model: entry.model,
                elapsed: 0,
                isPreview: false
            )
            errorMessage = nil
            detailExpanded = false
        }) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.tagLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .lineLimit(1)
                Text(entry.summary.isEmpty ? "(无摘要)" : entry.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(entry.timestampLabel)
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main pane

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("粘贴错误内容")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                Spacer()
                if !currentModel.isEmpty {
                    Text("模型：\(currentModel)")
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                }
                Button(action: clearInput) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help("清空输入与输出")
                .disabled(inputText.isEmpty && currentResult == nil)
            }

            TextEditor(text: $inputText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 100, maxHeight: 160)
                .padding(4)
                .background(Color(NSColor.textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )

            HStack {
                Button(action: runDiagnose) {
                    HStack(spacing: 6) {
                        if isRunning {
                            ProgressView()
                                .scaleEffect(0.5)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "stethoscope")
                        }
                        Text(isRunning ? "诊断中…" : "诊断")
                    }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(isRunning || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(action: pasteFromClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.on.clipboard")
                        Text("粘贴")
                    }
                }
                .help("从剪贴板覆盖当前输入")

                Spacer()

                if let err = errorMessage {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
            }

            Divider()

            resultPane
        }
        .padding(14)
    }

    @ViewBuilder
    private var resultPane: some View {
        if let r = currentResult {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    summaryCard(r)
                    detailSection(r)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
            }
        } else {
            HStack {
                Spacer()
                Text(isRunning ? "正在分析…" : "在上方粘贴错误内容后点 “诊断”")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 30)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summaryCard(_ r: ErrorDiagnosisResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                tagPill(text: r.providerLabel.isEmpty ? "未识别" : r.providerLabel,
                        color: .accentColor)
                tagPill(text: r.problemLabel.isEmpty ? "未分类" : r.problemLabel,
                        color: .orange)
                Spacer()
                if r.isPreview {
                    HStack(spacing: 3) {
                        ProgressView()
                            .scaleEffect(0.45)
                            .frame(width: 10, height: 10)
                        Text("快速预览，等待精修…")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                } else if r.elapsed > 0 {
                    Text(String(format: "%@ · %.1fs", r.model, r.elapsed))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }

            Text(r.summary)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if !r.action.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text(r.action)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary.opacity(0.85))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((r.isPreview ? Color.orange : Color.accentColor).opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke((r.isPreview ? Color.orange : Color.accentColor).opacity(0.25), lineWidth: 0.8)
        )
    }

    private func tagPill(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
            .overlay(
                Capsule().stroke(color.opacity(0.3), lineWidth: 0.5)
            )
    }

    @ViewBuilder
    private func detailSection(_ r: ErrorDiagnosisResult) -> some View {
        if !r.detail.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Button(action: { detailExpanded.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: detailExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                        Text(detailExpanded ? "收起详细分析" : "展开详细分析")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                if detailExpanded {
                    Text(r.detail)
                        .font(.system(size: 12))
                        .foregroundColor(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.primary.opacity(0.04))
                        )
                }
            }
        }
    }

    // MARK: - Actions

    private func clearInput() {
        inputText = ""
        currentResult = nil
        errorMessage = nil
        selectedEntryId = nil
        detailExpanded = false
    }

    private func pasteFromClipboard() {
        if let s = NSPasteboard.general.string(forType: .string) {
            inputText = s
            currentResult = nil
            errorMessage = nil
            selectedEntryId = nil
            detailExpanded = false
        }
    }

    private func prefillFromClipboardIfNeeded() {
        guard inputText.isEmpty,
              let s = NSPasteboard.general.string(forType: .string),
              clipboardLooksLikeError(s) else { return }
        inputText = s
    }

    private func runDiagnose() {
        let text = inputText
        isRunning = true
        currentResult = nil
        errorMessage = nil
        detailExpanded = false

        ErrorDiagnosisService.shared.diagnose(
            errorText: text,
            onPreview: { preview in
                DispatchQueue.main.async {
                    if currentResult == nil || currentResult?.isPreview == true {
                        currentResult = preview
                    }
                }
            },
            onFinal: { result in
                DispatchQueue.main.async {
                    isRunning = false
                    switch result {
                    case .success(let r):
                        currentResult = r
                        let entry = ErrorDiagnosisEntry(
                            model: r.model,
                            input: text,
                            summary: r.summary,
                            providerLabel: r.providerLabel,
                            problemLabel: r.problemLabel,
                            action: r.action,
                            detail: r.detail
                        )
                        ErrorDiagnosisHistoryStore.shared.add(entry)
                        selectedEntryId = entry.id
                    case .failure(let err):
                        errorMessage = (err as? LocalizedError)?.errorDescription ?? "\(err)"
                    }
                }
            }
        )
    }
}
