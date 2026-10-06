import Foundation

@main
struct DevelopmentChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let now = Date()
        let oldDate = now.addingTimeInterval(-50 * 86_400)
        let recentDate = now.addingTimeInterval(-86_400)
        func git(_ repo: URL, _ args: [String], date: Date = Date()) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", repo.path] + args
            var env = ProcessInfo.processInfo.environment
            env["GIT_AUTHOR_DATE"] = "\(Int(date.timeIntervalSince1970)) +0000"
            env["GIT_COMMITTER_DATE"] = env["GIT_AUTHOR_DATE"]
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            precondition(p.terminationStatus == 0, "git fixture failed: \(args)")
        }
        func repo(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            try git(url, ["init"])
            try git(url, ["config", "user.email", "test@example.invalid"])
            try git(url, ["config", "user.name", "Test"])
            try git(url, ["config", "commit.gpgsign", "false"])
            return url
        }
        let old = try repo("old")
        let recent = try repo("recent")
        for (url, date) in [(old, oldDate), (recent, recentDate)] {
            try Data("print(1)\n".utf8).write(to: url.appendingPathComponent("app.py"))
            try git(url, ["add", "."])
            try git(url, ["commit", "-m", "source"], date: date)
        }
        let baseline = ProjectDevelopmentActivity.read(path: old.path)
        precondition(Int(baseline.latest!.timeIntervalSince1970) == Int(oldDate.timeIntervalSince1970))
        try Data("updated notes".utf8).write(to: old.appendingPathComponent("README.md"))
        try git(old, ["add", "."])
        try git(old, ["commit", "-m", "notes"])
        let notes = ProjectDevelopmentActivity.read(path: old.path)
        precondition(notes.latest == baseline.latest)
        precondition(notes.score(at: now) < ProjectDevelopmentActivity.read(path: recent.path).score(at: now))
        print("PASS 最近代码提交优先；今天更新笔记不会抬高旧项目")
        try Data("print(2)\n".utf8).write(to: old.appendingPathComponent("app.py"))
        let editDate = now.addingTimeInterval(-30 * 86_400)
        try fm.setAttributes([.modificationDate: editDate], ofItemAtPath: old.appendingPathComponent("app.py").path)
        let stale = ProjectDevelopmentActivity.read(path: old.path)
        precondition(abs(stale.latest!.timeIntervalSince(editDate)) < 1)
        precondition(stale.score(at: now) < ProjectDevelopmentActivity.read(path: recent.path).score(at: now))
        print("PASS 陈旧未提交改动按文件时间计算，不当作今天开发")
        try fm.createDirectory(at: old.appendingPathComponent(".local"), withIntermediateDirectories: true)
        try Data("print(3)\n".utf8).write(to: old.appendingPathComponent(".local/generated.py"))
        try git(old, ["add", ".local/generated.py"])
        try git(old, ["commit", "-m", "generated"])
        precondition(ProjectDevelopmentActivity.read(path: old.path).latest == stale.latest)
        print("PASS 已提交与未提交的 .local 产物均不计入开发")
        let fresh = try repo("fresh")
        try Data("print(4)\n".utf8).write(to: fresh.appendingPathComponent("new.py"))
        precondition(ProjectDevelopmentActivity.read(path: fresh.path).latest != nil)
        print("PASS 尚无提交的新仓库可检测新增代码")
        let single = ProjectDevelopmentActivity(dates: [recentDate], unavailable: false)
        let repeated = ProjectDevelopmentActivity(dates: [recentDate, recentDate], unavailable: false)
        precondition(single.score(at: now) == repeated.score(at: now))
        print("PASS 同一天的重复提交不会重复累计开发频率")
    }
}
