import AppKit
import Foundation
import SXCore
import UniformTypeIdentifiers

private struct SongProject: Codable {
    let version: Int
    let draft: Draft

    static let maximumBytes = 8 * 1_024 * 1_024
    static let maximumBars = 10_000
    static var contentType: UTType { UTType(exportedAs: "com.local.genos2.song", conformingTo: .json) }
}

extension Workspace {
    func chooseProjectFile(undoManager: UndoManager?) {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "打开歌曲工程"
        panel.prompt = "打开"
        panel.allowedContentTypes = [SongProject.contentType]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try loadProject(at: url, undoManager: undoManager) }
        catch { message = error.localizedDescription }
    }

    func saveProject() {
        guard !busy else { return }
        do {
            let data = try projectData()
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let filename = (title.isEmpty ? "未命名编曲" : title)
                .replacingOccurrences(of: "/", with: "／")
                .replacingOccurrences(of: ":", with: "：")
            let panel = NSSavePanel()
            panel.title = "保存歌曲工程"
            panel.prompt = "保存"
            panel.nameFieldLabel = "保存为："
            panel.nameFieldStringValue = filename + ".genos2song"
            panel.allowedContentTypes = [SongProject.contentType]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try data.write(to: url, options: .atomic)
        } catch { message = error.localizedDescription }
    }

    /// Validates the complete project before replacing the current autosaved draft.
    func loadProject(at url: URL, undoManager: UndoManager?) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= SongProject.maximumBytes else { throw invalid("歌曲工程不能超过 8 MB。") }
        let data = try Data(contentsOf: url)
        guard data.count <= SongProject.maximumBytes else { throw invalid("歌曲工程不能超过 8 MB。") }
        let project: SongProject
        do { project = try JSONDecoder().decode(SongProject.self, from: data) }
        catch { throw invalid("无法读取歌曲工程，文件格式不正确或内容不完整。") }
        guard project.version == 1 else { throw invalid("暂不支持这个歌曲工程版本，请更新伴奏工作台。") }
        try validateProject(project.draft)
        replaceDraft(project.draft, selection: project.draft.blocks.first?.id, undoManager: undoManager)
        exported = nil
        pendingIRealImport = nil
        undoManager?.setActionName("打开歌曲工程")
    }

    func projectData() throws -> Data {
        try validateProject(draft)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(SongProject(version: 1, draft: draft))
        guard data.count <= SongProject.maximumBytes else { throw invalid("歌曲工程不能超过 8 MB。") }
        return data
    }

    private func validateProject(_ candidate: Draft) throws {
        if let key = candidate.key, !(-7...7).contains(key.fifths) {
            throw invalid("歌曲工程中的调号无效。")
        }
        if let meter = candidate.meter, !SongMeter.choices.contains(meter) {
            throw invalid("歌曲工程中的拍号不受支持。")
        }
        guard let entry = entries.first(where: { $0.path == candidate.stylePath }) else {
            throw invalid("找不到工程使用的风格「\(candidate.stylePath)」，请先导入对应的 Yamaha 风格文件。")
        }
        let sourceStyle = try Style(url: entry.url)
        guard sourceStyle.ticksPerBar > 0 else { throw invalid("工程使用的风格文件小节时值无效。") }
        let meter = candidate.meter ?? SongMeter(sourceStyle)
        let tempo = candidate.bpm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let bpm = tempo.isEmpty ? sourceStyle.bpm : Double(tempo), (20...400).contains(bpm) else {
            throw invalid("歌曲工程中的速度必须在 20 到 400 之间。")
        }
        guard Set(candidate.blocks.map(\.id)).count == candidate.blocks.count else {
            throw invalid("歌曲工程中有重复的段落标识。")
        }
        var totalTicks = 0
        var totalBars = 0
        guard candidate.blocks.count <= SongProject.maximumBars else {
            throw invalid("歌曲工程最多支持 10000 个小节。")
        }
        for block in candidate.blocks {
            guard block.bars.count <= SongProject.maximumBars,
                  block.introLength.map({ (1...SongProject.maximumBars).contains($0) }) ?? true else {
                throw invalid("歌曲工程的小节数必须在 1 到 10000 之间。")
            }
            guard let pattern = sourceStyle.sections.first(where: { $0.name == block.pattern }) else {
                throw invalid("风格「\(sourceStyle.name)」没有段落「\(block.pattern)」。")
            }
            // Hidden bars are intentionally retained when switching to a shorter variation.
            for (index, bar) in block.bars.enumerated() {
                _ = try chordChanges(in: bar, style: sourceStyle, meter: meter,
                                     context: "「\(block.name)」第 \(index + 1) 小节")
            }
            let naturalLength = (pattern.length + sourceStyle.ticksPerBar - 1) / sourceStyle.ticksPerBar
            let length = block.isMain ? block.bars.count : block.isIntro ? block.introLength ?? naturalLength : naturalLength
            guard length > 0 else { throw invalid("「\(block.name)」至少需要一个小节。") }
            let storedLength = max(length, block.bars.count)
            guard storedLength <= SongProject.maximumBars - totalBars else {
                throw invalid("歌曲工程最多支持 10000 个小节（包含隐藏的小节）。")
            }
            totalBars += storedLength
            let segment = Chart.Segment(styleSection: block.pattern, name: block.name,
                                        bars: Array(block.bars.prefix(length)),
                                        lengthInBars: block.isIntro ? block.introLength : nil)
            let plan = try PlannedSegment(entry: segment, style: sourceStyle, meter: meter)
            guard plan.span <= 0x0fff_ffff - totalTicks else { throw invalid("歌曲长度超出 MIDI 格式范围。") }
            totalTicks += plan.span
        }
    }
}
