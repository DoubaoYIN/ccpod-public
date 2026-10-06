import SwiftUI

struct ModelResult: Identifiable {
    let id = UUID()
    let model: String
    let displayName: String
    var latencyMs: Int?
    var failed: Bool = false
    var error: String?
    var testing: Bool = true

    var rating: LatencyRating {
        guard let ms = latencyMs else { return .unavailable }
        switch ms {
        case ..<2000: return .excellent
        case ..<5000: return .good
        case ..<10000: return .slow
        default: return .verySlow
        }
    }
}

enum LatencyRating {
    case excellent, good, slow, verySlow, unavailable

    var label: String {
        switch self {
        case .excellent: return "极快"
        case .good: return "正常"
        case .slow: return "较慢"
        case .verySlow: return "很慢"
        case .unavailable: return "不可用"
        }
    }

    var color: Color {
        switch self {
        case .excellent: return .green
        case .good: return .blue
        case .slow: return .orange
        case .verySlow: return .red
        case .unavailable: return .gray
        }
    }

    var description: String {
        switch self {
        case .excellent: return "接近官方直连水平"
        case .good: return "网关转发正常范围"
        case .slow: return "可用但体验一般"
        case .verySlow: return "严重影响体验"
        case .unavailable: return "模型不可用"
        }
    }
}

struct ProviderTestResult: Identifiable {
    let id = UUID()
    let provider: String
    var models: [ModelResult]
    var testing: Bool { models.contains { $0.testing } }
}

final class SpeedTestViewModel: ObservableObject {
    @Published var results: [ProviderTestResult] = []
    @Published var running = false


    func loadProviders() {
        guard results.isEmpty else { return }
        results = HealthService.shared.allProviderNames().map { provider in
            ProviderTestResult(provider: provider, models: HealthService.shared.probeModels(for: provider).map {
                ModelResult(model: $0, displayName: gatewayModelDisplayName($0), testing: false)
            })
        }
    }

    func runAll() {
        let providers = HealthService.shared.allProviderNames()
        guard !providers.isEmpty else {
            running = false
            results = []
            return
        }
        running = true
        results = providers.map { p in
            ProviderTestResult(provider: p, models: HealthService.shared.probeModels(for: p).map {
                ModelResult(model: $0, displayName: gatewayModelDisplayName($0))
            })
        }

        let group = DispatchGroup()
        for (pi, provider) in providers.enumerated() {
            group.enter()
            HealthService.shared.runSpeedTest(provider: provider) { [weak self] latencies, lastError in
                DispatchQueue.main.async {
                    guard let self, pi < self.results.count else { group.leave(); return }
                    for (mi, key) in self.results[pi].models.map({ $0.model }).enumerated() {
                        guard mi < self.results[pi].models.count else { continue }
                        if let entry = latencies[key] {
                            self.results[pi].models[mi].latencyMs = entry
                            self.results[pi].models[mi].failed = entry == nil
                        } else {
                            self.results[pi].models[mi].failed = true
                        }
                        self.results[pi].models[mi].error = lastError
                        self.results[pi].models[mi].testing = false
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in self?.running = false }
    }
}

struct SpeedTestView: View {
    @StateObject private var vm = SpeedTestViewModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.results) { result in
                        providerSection(result)
                    }
                    if vm.results.isEmpty && !vm.running {
                        Text("暂无线路").foregroundColor(.secondary).padding(20)
                    }
                    legend
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 420, height: 480)
        .onAppear { vm.loadProviders() }
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .foregroundColor(.accentColor)
            Text("线路测速")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            if vm.running {
                ProgressView().controlSize(.small)
            }
        }
        .padding(12)
    }

    private func providerSection(_ result: ProviderTestResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(providerColor(result.provider)).frame(width: 8, height: 8)
                Text(providerDisplayName(result.provider)).font(.system(size: 13, weight: .semibold))
                providerReasonBadge(for: result.provider)
                if result.testing {
                    ProgressView().controlSize(.mini)
                }
            }
            providerReasonDetail(for: result.provider)
            ForEach(result.models) { m in modelRow(m) }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func providerReasonBadge(for provider: String) -> some View {
        if let health = HealthService.shared.cached(provider), health.availabilityReason == .quotaExhaustedDaily {
            Text("已用尽")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.12))
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func providerReasonDetail(for provider: String) -> some View {
        if let health = HealthService.shared.cached(provider), health.availabilityReason == .quotaExhaustedDaily, let detail = health.detail {
            Text(detail)
                .font(.system(size: 10))
                .foregroundColor(.orange)
        }
    }

    private func modelRow(_ m: ModelResult) -> some View {
        HStack(spacing: 8) {
            Text(m.displayName)
                .font(.system(size: 12, design: .monospaced))
                .frame(width: 90, alignment: .leading)
            if m.testing {
                ProgressView().controlSize(.mini)
                Spacer()
            } else if let ms = m.latencyMs {
                Text("\(ms) ms")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(m.rating.color)
                    .frame(width: 80, alignment: .trailing)
                HStack(spacing: 4) {
                    Circle().fill(m.rating.color).frame(width: 6, height: 6)
                    Text(m.rating.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(m.rating.color)
                }
                .frame(width: 50, alignment: .leading)
                Text(m.rating.description)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Spacer()
            } else {
                Text("不可用")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                if let err = m.error {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
                Spacer()
            }
        }
        .padding(.leading, 16)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("评级标准")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            HStack(spacing: 16) {
                legendItem(color: .green, label: "极快 <2s")
                legendItem(color: .blue, label: "正常 2-5s")
                legendItem(color: .orange, label: "较慢 5-10s")
                legendItem(color: .red, label: "很慢 >10s")
            }
            Text("基准: Anthropic 官方 Opus TTFT ~1.6s, Sonnet ~1.0s (artificialanalysis.ai)")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .padding(.top, 8)
    }

    private func legendItem(color: Color, label: String) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10)).foregroundColor(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(action: { vm.runAll() }) {
                Label("重新测试", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(vm.running)
            Spacer()
        }
        .padding(12)
    }

    private func providerColor(_ provider: String) -> Color {
        switch provider {
        case "official": return .green
        case "easyclaude": return .blue
        case "minimax": return .orange
        case "glm": return .purple
        case "volcengine": return .red
        case "aliyun": return .brown
        case "deepseek": return .cyan
        case "kimi": return .yellow
        default: return .gray
        }
    }
}
