import AppKit
import Foundation

@main
struct VerifyProject {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("genos2-project-check-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("roundtrip.genos2song")
        let suite = "com.local.genos2.project-test.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = Workspace(defaults: defaults)
        precondition(workspace.style != nil)
        workspace.draft = Draft(title: "F 小调测试", bpm: "128.5", key: .init(fifths: -4, minor: true),
                                meter: .init(3, 4), mutedParts: [.rhythm2, .phrase1], blocks: [
            .init(name: "前奏", pattern: "Intro A", bars: ["Fm7:1 Abmaj7:2", "C7", "Db"], introLength: 2),
            .init(name: "A", pattern: "Main A", bars: ["Fm7", "Eb", "Db Eb", "Fm7"])
        ])
        let expected = workspace.draft
        let data = try workspace.projectData()
        try data.write(to: url, options: .atomic)
        workspace.draft.title = "打开前的歌曲"
        let previous = workspace.draft
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.beginUndoGrouping()
        try workspace.loadProject(at: url, undoManager: manager)
        manager.endUndoGrouping()
        precondition(workspace.draft.title == expected.title)
        precondition(workspace.draft.key == expected.key && workspace.draft.meter == expected.meter)
        precondition(workspace.draft.mutedParts == expected.mutedParts)
        precondition(workspace.draft.blocks.map(\.id) == expected.blocks.map(\.id))
        precondition(workspace.draft.blocks.map(\.bars) == expected.blocks.map(\.bars))
        precondition(workspace.draft.blocks.first?.introLength == 2)
        manager.undo()
        precondition(workspace.draft.title == previous.title)
        manager.redo()
        precondition(workspace.draft.title == expected.title)

        func reject(_ mutate: (inout [String: Any]) -> Void) throws {
            var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            mutate(&json)
            try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
            let before = try workspace.projectData()
            do { try workspace.loadProject(at: url, undoManager: nil); fatalError("Accepted invalid project") }
            catch { let after = try workspace.projectData(); precondition(after == before) }
        }
        func badDraft(_ mutate: (inout [String: Any]) -> Void) throws {
            try reject { json in
                var draft = json["draft"] as! [String: Any]
                mutate(&draft)
                json["draft"] = draft
            }
        }
        try reject { $0["version"] = 999 }
        try badDraft { $0["stylePath"] = "missing.prs" }
        try badDraft { $0["key"] = ["fifths": 100, "minor": true] }
        try badDraft { $0["meter"] = ["beats": Int.max, "unit": 0] }
        try badDraft { $0["bpm"] = "nan" }
        try badDraft { draft in
            var blocks = draft["blocks"] as! [[String: Any]]
            blocks[0]["introLength"] = Int.max
            draft["blocks"] = blocks
        }
        try badDraft { draft in
            var blocks = draft["blocks"] as! [[String: Any]]
            blocks[1]["id"] = blocks[0]["id"]
            draft["blocks"] = blocks
        }
        try badDraft { draft in
            var blocks = draft["blocks"] as! [[String: Any]]
            blocks[1]["bars"] = ["Fm7", "NotAChord"]
            draft["blocks"] = blocks
        }
        try badDraft { draft in
            var blocks = draft["blocks"] as! [[String: Any]]
            blocks[1]["bars"] = Array(repeating: "Fm", count: 10_001)
            draft["blocks"] = blocks
        }
        try badDraft { draft in
            var blocks = draft["blocks"] as! [[String: Any]]
            blocks[0]["bars"] = ["Fm", "Fm", "NotAChord"]
            draft["blocks"] = blocks
        }
        try badDraft { draft in
            var blocks = draft["blocks"] as! [[String: Any]]
            for i in blocks.indices {
                blocks[i]["bars"] = Array(repeating: "Fm", count: 5_001)
            }
            draft["blocks"] = blocks
        }
        try Data(repeating: 32, count: 8 * 1_024 * 1_024 + 1).write(to: url)
        do { try workspace.loadProject(at: url, undoManager: nil); fatalError("Accepted oversized project") }
        catch { precondition(error.localizedDescription.contains("8 MB")) }
        workspace.draft.blocks = []
        _ = try workspace.projectData()
        print("工程回读、段落与乐器保留、撤销/重做、11 类无效字段保护（含隐藏小节及总量）、8 MB 限制及空草稿保存通过。")
    }
}
