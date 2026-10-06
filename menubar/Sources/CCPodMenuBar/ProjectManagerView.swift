import SwiftUI

struct ProjectManagerView: View {
    @ObservedObject var manager: ProjectManager
    let onAdd: () -> Void
    @State private var projects: [ProjectInfo] = []
    @State private var drafts: [String: String] = [:]
    @State private var search = ""
    @State private var errorMessage: String?
    @State private var saved = false

    private var visibleProjects: [ProjectInfo] {
        projects.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                || $0.path.localizedCaseInsensitiveContains(search)
                || (drafts[$0.path] ?? "").localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("项目名称与目录").font(.title2.weight(.semibold))
            Text("按近期代码开发活跃度排序；打开目录、聊天和笔记更新不计入。")
                .font(.callout).foregroundColor(.secondary)
            TextField("搜索名称或路径", text: $search).textFieldStyle(.roundedBorder)
            HStack {
                Text("显示名称").frame(width: 180, alignment: .leading)
                Text("对应目录")
            }
            .font(.caption).foregroundColor(.secondary).padding(.horizontal, 12)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleProjects, id: \.path) { project in
                        HStack(spacing: 16) {
                            TextField(project.name, text: Binding(
                                get: { drafts[project.path] ?? project.name },
                                set: { drafts[project.path] = $0; saved = false }
                            ))
                            .textFieldStyle(.roundedBorder).frame(width: 180)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled)
                                if let activity = manager.development[project.path] {
                                    if let date = activity.latest {
                                        Text("最近代码改动：" + date.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                    } else {
                                        Text(activity.unavailable ? "开发记录未读取" : "未发现代码开发记录")
                                            .font(.caption)
                                    }
                                } else {
                                    Text("正在读取开发记录…").font(.caption)
                                }
                            }
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        Divider()
                    }
                }
            }
            .background(Color.primary.opacity(0.025)).cornerRadius(8)
            Text("临时目录默认隐藏；如有需要，可通过「添加项目」手动加入。")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Button("添加项目…") {
                    onAdd()
                    projects = manager.recentProjects()
                }
                Spacer()
                if saved { Text("已保存").foregroundColor(.secondary) }
                Button("保存修改") {
                    do {
                        try manager.renameProjects(drafts)
                        projects = manager.recentProjects()
                        drafts.removeAll()
                        saved = true
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut("s", modifiers: .command).disabled(drafts.isEmpty)
            }
        }
        .padding(20)
        .onAppear { projects = manager.recentProjects() }
        .onReceive(manager.$development.dropFirst()) { _ in
            // @Published 在赋值前通知，下一轮主线程读取完整的新快照。
            DispatchQueue.main.async { projects = manager.recentProjects() }
        }
        .alert("保存失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
