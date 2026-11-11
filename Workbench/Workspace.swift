import AppKit
import AVFoundation
import Foundation
@preconcurrency import SXCore
import UniformTypeIdentifiers

struct StyleEntry: Identifiable {
    let path: String
    let url: URL
    let isUpdate: Bool
    let name: String
    let originalName: String
    var id: String { path }
    var category: String { String(path.split(separator: "/").first ?? "") }

    init(path: String, url: URL, isUpdate: Bool, customName: String?) {
        self.path = path
        self.url = url
        self.isUpdate = isUpdate
        self.name = customName ?? StyleNames.localized(path)
        originalName = StyleNames.originalName(path)
    }
}

struct Draft: Codable {
    struct Block: Codable, Identifiable {
        var id = UUID()
        var name: String
        var pattern: String
        var bars: [String]
        var introLength: Int?

        var isIntro: Bool { pattern.hasPrefix("Intro ") }
        var isMain: Bool { pattern.hasPrefix("Main ") }
        var allowsResizing: Bool { isIntro || isMain }

        mutating func fillBars(to length: Int) {
            if bars.count < length { bars += Array(repeating: bars.last ?? "C", count: length - bars.count) }
        }
    }

    var title = "未命名编曲"
    var stylePath = "pop/SkyPop.T547.prs"
    var bpm = "112"
    var key: SongKey?
    var meter: SongMeter?
    var mutedParts: Set<AccompanimentPart>?
    var blocks: [Block]

    static let demo = Draft(title: "天空流行编曲示例", blocks: [
        Block(name: "前奏", pattern: "Intro A", bars: ["C"]),
        Block(name: "主歌", pattern: "Main A", bars: ["C", "G/B", "Am7", "Fadd9", "C/E", "F", "Dm7 G7", "C"]),
        Block(name: "加花", pattern: "Fill In DD", bars: ["G7"]),
        Block(name: "副歌", pattern: "Main D", bars: ["F", "G", "Em7", "Am7", "F", "C/E", "Dm7:1 G7:3", "C"]),
        Block(name: "尾奏", pattern: "Ending A", bars: ["C"])
    ])
}

let categoryLabels = [
    "ballroom": "舞厅", "classic-events": "古典与庆典", "country": "乡村", "dance": "舞曲",
    "easylistening": "轻音乐", "entertainer": "综艺", "jazz": "爵士", "latin": "拉丁",
    "movie-show": "影视与舞台", "oldies": "怀旧", "pop": "流行", "r-b": "节奏布鲁斯",
    "retropop": "复古流行", "rock": "摇滚", "trad-folk": "传统与民谣"
]

func patternLabel(_ pattern: String) -> String {
    switch pattern {
    case "Fill In BA", "Break": return "间奏"
    case _ where pattern.hasPrefix("Intro"): return "前奏"
    case _ where pattern.hasPrefix("Main"): return "主奏"
    case _ where pattern.hasPrefix("Fill"): return "加花"
    case _ where pattern.hasPrefix("Ending"): return "尾奏"
    default: return pattern
    }
}

func patternDisplayName(_ pattern: String) -> String {
    let label = patternLabel(pattern)
    guard label != pattern, label != "间奏", let letter = pattern.last else { return label }
    return "\(label) \(letter)"
}

@MainActor
final class Workspace: ObservableObject {
    @Published var draft: Draft { didSet { stopPreview(); persist() } }
    @Published private(set) var entries: [StyleEntry] = []
    @Published private(set) var style: Style?
    @Published var selectedBlock: UUID?
    @Published var selectedBar = 0
    @Published var message: String?
    @Published var busy = false
    @Published var exported: Exported?
    @Published private(set) var preview: PreviewState = .idle
    @Published private(set) var previewProgress = 0.0
    @Published private(set) var previewPosition: PreviewTimeline.Position?

    enum PreviewState { case idle, loading, playing }
    private var player: AVMIDIPlayer?
    private var previewTimer: Timer?
    private var previewToken: UUID?

    struct Exported {
        let url: URL
        let format: ArrangementFormat
    }

    private let bundledLibrary: URL
    private let userLibrary: URL
    private let formats = Set(["prs", "sst", "fps", "sty", "scp"])
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        bundledLibrary = Bundle.main.resourceURL!.appendingPathComponent("Genos2", isDirectory: true)
        userLibrary = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Genos2 Workbench/Styles", isDirectory: true)
        draft = defaults.data(forKey: "arrangementDraft")
            .flatMap { try? JSONDecoder().decode(Draft.self, from: $0) } ?? .demo
        if draft.title == "SkyPop 编曲示例", draft.stylePath == Draft.demo.stylePath { draft.title = Draft.demo.title }
        selectedBlock = draft.blocks.first(where: { $0.pattern.hasPrefix("Main") })?.id ?? draft.blocks.first?.id
        readLibrary()
    }

    var current: Draft.Block? { draft.blocks.first { $0.id == selectedBlock } }
    var activeEntry: StyleEntry? { entries.first { $0.path == draft.stylePath } }
    var key: SongKey { draft.key ?? .cMajor }
    var meter: SongMeter? { draft.meter ?? style.map(SongMeter.init) }
    var availableParts: Set<AccompanimentPart> {
        guard let style, style.ticksPerBar > 0 else { return [] }
        var parts: Set<AccompanimentPart> = []
        for block in draft.blocks {
            guard let section = style.sections.first(where: { $0.name == block.pattern }) else { continue }
            let bars = count(block)
            for (channel, tick) in section.firstNoteTickByPart where tick < section.length {
                guard !block.allowsResizing || tick / style.ticksPerBar < bars else { continue }
                if let part = AccompanimentPart(rawValue: channel) { parts.insert(part) }
            }
        }
        return parts
    }
    var enabledParts: Set<AccompanimentPart> { availableParts.subtracting(draft.mutedParts ?? []) }
    var demo: StyleDemo? {
        guard let entry = activeEntry, let style else { return nil }
        return StyleDemo(entry: entry, style: style)
    }
    var canRestoreActiveStyle: Bool {
        guard let entry = activeEntry, entry.isUpdate else { return false }
        return FileManager.default.fileExists(atPath: bundledLibrary.appendingPathComponent(entry.path).path)
    }
    var barCount: Int { draft.blocks.reduce(0) { $0 + count($1) } }
    var patterns: [String] {
        let names = style?.sections.map(\.name) ?? []
        return names.filter { $0.hasPrefix("Intro") } + names.filter { $0.hasPrefix("Main") }
            + names.filter { $0.hasPrefix("Fill") || $0 == "Break" } + names.filter { $0.hasPrefix("Ending") }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(draft) { defaults.set(data, forKey: "arrangementDraft") }
    }

    private func readLibrary() {
        var indexed: [String: StyleEntry] = [:]
        let customNames = defaults.dictionary(forKey: "customStyleNames") as? [String: String] ?? [:]
        for (root, isUpdate) in [(bundledLibrary, false), (userLibrary, true)] {
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                                                              options: [.skipsHiddenFiles]) else { continue }
            let prefix = root.standardizedFileURL.path + "/"
            for case let url as URL in files {
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(prefix), formats.contains(url.pathExtension.lowercased()),
                      (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let relative = String(path.dropFirst(prefix.count))
                indexed[relative] = StyleEntry(path: relative, url: url, isUpdate: isUpdate, customName: customNames[relative])
            }
        }
        entries = indexed.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
        style = nil
        if let entry = activeEntry { loadStyle(entry) }
        else if let first = entries.first { selectStyle(first) }
    }

    func importStyles(category: String, replacing: Bool = false) {
        let active = activeEntry
        guard !replacing || active != nil else { return }
        let panel = NSOpenPanel()
        panel.title = replacing ? "选择新的风格文件" : "导入 Yamaha 风格文件"
        panel.prompt = "打开"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = !replacing
        panel.allowedContentTypes = formats.sorted().compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }

        do {
            let targetCategory = categoryLabels[category] == nil ? active?.category ?? "pop" : category
            let imports = try panel.urls.map { url -> (path: String, data: Data) in
                let path = (replacing ? active?.path : nil) ?? targetCategory + "/" + url.lastPathComponent
                let data = try Data(contentsOf: url)
                do { _ = try Style(data: data, name: url.lastPathComponent) }
                catch { throw invalid("无法导入「\(url.lastPathComponent)」：\(error.localizedDescription)") }
                return (path, data)
            }
            guard Set(imports.map(\.path)).count == imports.count else {
                throw invalid("选中的文件里有同名风格，请分开导入。")
            }
            let existing = Set(entries.map(\.path))
            let replacements = imports.filter { existing.contains($0.path) }
            if !replacements.isEmpty {
                let alert = NSAlert()
                alert.messageText = replacing ? "更新「\(active?.name ?? "")」？" : "更新 \(replacements.count) 个同名风格？"
                alert.informativeText = "新版本会优先使用，安装包内的原始风格仍可恢复。"
                alert.addButton(withTitle: "更新")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            defer { readLibrary() }
            for item in imports {
                let destination = userLibrary.appendingPathComponent(item.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try item.data.write(to: destination, options: .atomic)
            }
            if let first = imports.first { draft.stylePath = first.path }
        } catch { message = error.localizedDescription }
    }

    func renameStyle(_ entry: StyleEntry) {
        let alert = NSAlert()
        alert.messageText = "设置风格显示名称"
        alert.informativeText = "原始文件：\(entry.originalName)"
        let nameField = NSTextField(string: entry.name)
        nameField.frame = NSRect(x: 0, y: 0, width: 248, height: 24)
        nameField.placeholderString = "输入中文名称"
        alert.accessoryView = nameField
        alert.window.initialFirstResponder = nameField
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "使用默认名称")
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertThirdButtonReturn else { return }
        var names = defaults.dictionary(forKey: "customStyleNames") as? [String: String] ?? [:]
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        names[entry.path] = response == .alertFirstButtonReturn && !name.isEmpty ? name : nil
        defaults.set(names, forKey: "customStyleNames")
        readLibrary()
    }

    func restoreActiveStyle() {
        guard let entry = activeEntry, canRestoreActiveStyle else { return }
        let alert = NSAlert()
        alert.messageText = "恢复「\(entry.name)」的内置版本？"
        alert.informativeText = "此操作会移除该风格的本地更新副本。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.removeItem(at: entry.url)
            readLibrary()
        } catch { message = error.localizedDescription }
    }

    private func loadStyle(_ entry: StyleEntry) {
        stopPreview()
        do { style = try Style(url: entry.url) }
        catch { message = error.localizedDescription }
    }

    func selectStyle(_ entry: StyleEntry) {
        if style != nil, entry.path == draft.stylePath { return }
        do {
            let newStyle = try Style(url: entry.url)
            let oldMeter = meter
            let newMeter = draft.meter ?? SongMeter(newStyle)
            if let previous = oldMeter { adaptChordTiming(from: previous, to: newMeter, style: newStyle) }
            style = newStyle
            draft.stylePath = entry.path
            selectedBar = 0
        } catch { message = error.localizedDescription }
    }

    func setKey(_ target: SongKey) {
        let previous = key
        guard target != previous else { return }
        var updated = draft
        updated.key = target
        for index in updated.blocks.indices {
            updated.blocks[index].bars = updated.blocks[index].bars.map { target.transpose($0, from: previous) }
        }
        draft = updated
    }

    func setMeter(_ override: SongMeter?) {
        guard let style, let previous = meter else { return }
        adaptChordTiming(from: previous, to: override ?? SongMeter(style), style: style)
        draft.meter = override
    }

    func isPartEnabled(_ part: AccompanimentPart) -> Bool {
        draft.mutedParts?.contains(part) != true
    }

    func setPart(_ part: AccompanimentPart, enabled: Bool) {
        var muted = draft.mutedParts ?? []
        if enabled { muted.remove(part) } else { muted.insert(part) }
        draft.mutedParts = muted.isEmpty ? nil : muted
    }

    func setAllParts(enabled: Bool) {
        draft.mutedParts = enabled ? nil : Set(AccompanimentPart.allCases)
    }

    private func adaptChordTiming(from previous: SongMeter, to next: SongMeter, style: Style) {
        guard previous != next else { return }
        var updated = draft
        for index in updated.blocks.indices {
            updated.blocks[index].bars = updated.blocks[index].bars.map {
                retimeChordBar($0, from: previous, to: next, style: style)
            }
        }
        draft = updated
    }

    func loadDemo(_ example: StyleDemo, undoManager: UndoManager?) {
        replaceDraft(example.draft, selection: example.draft.blocks.first(where: \.isMain)?.id, undoManager: undoManager)
        undoManager?.setActionName("载入风格示例")
    }

    private func replaceDraft(_ value: Draft, selection: UUID?, undoManager: UndoManager?) {
        let previous = draft, previousSelection = selectedBlock
        draft = value
        selectedBlock = selection ?? value.blocks.first?.id
        selectedBar = 0
        if style == nil || value.stylePath != previous.stylePath { readLibrary() }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] workspace in
            workspace.replaceDraft(previous, selection: previousSelection, undoManager: undoManager)
        }
    }

    func newDraft() {
        let first = patterns.first { $0 == "Main A" } ?? patterns.first ?? "Main A"
        let tonic = key.tonicName + (key.minor ? "m" : "")
        let block = Draft.Block(name: "主歌", pattern: first, bars: Array(repeating: tonic, count: 4))
        var updated = draft
        updated.title = "未命名编曲"
        updated.blocks = [block]
        updated.mutedParts = nil
        draft = updated
        select(block.id)
    }

    func select(_ id: UUID) {
        selectedBlock = id
        selectedBar = 0
    }

    func count(_ block: Draft.Block) -> Int {
        if block.isMain { return block.bars.count }
        if block.isIntro, let length = block.introLength { return length }
        guard let style, let pattern = style.sections.first(where: { $0.name == block.pattern }) else { return block.bars.count }
        let ticks = max(1, style.ticksPerBar)
        return (pattern.length + ticks - 1) / ticks
    }

    func startBar(_ id: UUID) -> Int {
        1 + draft.blocks.prefix { $0.id != id }.reduce(0) { $0 + count($1) }
    }

    func add(_ pattern: String) {
        let name = patternLabel(pattern)
        let number = draft.blocks.filter { $0.name == name || $0.name.hasPrefix(name + " ") }.count
        let chord = current.map { bar($0.id, at: max(0, count($0) - 1)) } ?? "C"
        let bars = pattern.hasPrefix("Main") ? Array(repeating: chord, count: 4) : [chord]
        let block = Draft.Block(name: number == 0 ? name : "\(name) \(number + 1)", pattern: pattern, bars: bars)
        let after = draft.blocks.firstIndex(where: { $0.id == selectedBlock }).map { $0 + 1 } ?? draft.blocks.count
        draft.blocks.insert(block, at: after)
        select(block.id)
    }

    func remove(_ id: UUID, undoManager: UndoManager?) {
        guard let index = draft.blocks.firstIndex(where: { $0.id == id }) else { return }
        let block = draft.blocks.remove(at: index)
        if selectedBlock == id {
            if draft.blocks.isEmpty {
                selectedBlock = nil
                selectedBar = 0
            } else {
                select(draft.blocks[min(index, draft.blocks.count - 1)].id)
            }
        }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] workspace in
            workspace.restoreRemoved(block, at: index, undoManager: undoManager)
        }
        undoManager?.setActionName("删除段落")
    }

    private func restoreRemoved(_ block: Draft.Block, at index: Int, undoManager: UndoManager?) {
        draft.blocks.insert(block, at: min(index, draft.blocks.count))
        select(block.id)
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] workspace in
            workspace.remove(block.id, undoManager: undoManager)
        }
    }

    func duplicate(_ id: UUID) {
        guard let index = draft.blocks.firstIndex(where: { $0.id == id }) else { return }
        var copy = draft.blocks[index]
        copy.id = UUID()
        copy.name += " 副本"
        draft.blocks.insert(copy, at: index + 1)
        select(copy.id)
    }

    func move(_ source: UUID, to target: UUID) -> Bool {
        guard source != target, let from = draft.blocks.firstIndex(where: { $0.id == source }),
              let to = draft.blocks.firstIndex(where: { $0.id == target }) else { return false }
        let block = draft.blocks.remove(at: from)
        draft.blocks.insert(block, at: to)
        return true
    }

    func update(_ id: UUID, _ change: (inout Draft.Block) -> Void) {
        guard let index = draft.blocks.firstIndex(where: { $0.id == id }) else { return }
        change(&draft.blocks[index])
    }

    func bar(_ id: UUID, at index: Int) -> String {
        guard let block = draft.blocks.first(where: { $0.id == id }) else { return "" }
        return index < block.bars.count ? block.bars[index] : block.bars.last ?? ""
    }

    func setBar(_ id: UUID, at index: Int, to text: String) {
        update(id) { block in
            if index >= block.bars.count {
                block.bars += Array(repeating: block.bars.last ?? "", count: index + 1 - block.bars.count)
            }
            block.bars[index] = text
        }
    }

    func apply(_ chord: String) {
        guard let block = current else { return }
        let index = min(selectedBar, max(0, count(block) - 1))
        setBar(block.id, at: index, to: chord)
    }

    func addBar(to block: Draft.Block) {
        guard block.allowsResizing else { return }
        let length = count(block)
        update(block.id) {
            $0.fillBars(to: length + 1)
            if $0.isIntro { $0.introLength = length + 1 }
        }
        selectedBar = length
    }

    func removeBar(from block: Draft.Block, at index: Int) {
        let length = count(block)
        guard block.allowsResizing, length > 1, (0..<length).contains(index) else { return }
        update(block.id) {
            $0.fillBars(to: length)
            $0.bars.remove(at: index)
            if $0.isIntro { $0.introLength = length - 1 }
        }
        selectedBar = min(index, length - 2)
    }

    func swapBars(_ source: UUID, _ from: Int, _ destination: UUID, _ to: Int) {
        let incoming = bar(source, at: from)
        let outgoing = bar(destination, at: to)
        setBar(destination, at: to, to: incoming)
        setBar(source, at: from, to: outgoing)
        selectedBar = to
    }

    func pasteBars(_ text: String, into block: Draft.Block) throws {
        guard let style else { return }
        let bars = text.components(separatedBy: CharacterSet(charactersIn: "|｜\n\r"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !bars.isEmpty else { throw invalid("请至少填写一个小节。") }
        let previousLength = count(block)
        guard block.allowsResizing || bars.count <= previousLength else {
            throw invalid("这个段落最多可以填写 \(count(block)) 小节。")
        }
        for (index, bar) in bars.enumerated() {
            _ = try chordChanges(in: bar, style: style, meter: meter, context: "第 \(index + 1) 小节")
        }
        update(block.id) {
            $0.bars = bars
            if $0.isIntro && bars.count != previousLength { $0.introLength = bars.count }
        }
        selectedBar = 0
    }

    private func makeChart(style: Style) throws -> Chart {
        let text = draft.bpm.trimmingCharacters(in: .whitespaces)
        let bpm = text.isEmpty ? style.bpm : Double(text)
        guard let bpm, (20...400).contains(bpm) else { throw invalid("请输入 20 到 400 之间的速度。") }
        let segments = draft.blocks.map {
            Chart.Segment(styleSection: $0.pattern, name: $0.name.isEmpty ? patternLabel($0.pattern) : $0.name,
                          bars: Array($0.bars.prefix(count($0))), lengthInBars: $0.isIntro ? $0.introLength : nil)
        }
        guard !segments.isEmpty else { throw invalid("请先添加段落。") }
        for segment in segments { _ = try PlannedSegment(entry: segment, style: style, meter: meter) }
        guard !enabledParts.isEmpty else { throw invalid("请至少选择一个当前编曲中使用的乐器声部。") }
        return Chart(style: draft.stylePath, bpm: bpm, key: key, meter: meter,
                     mutedParts: draft.mutedParts ?? [], segments: segments)
    }

    func togglePreview() {
        guard preview == .idle else { stopPreview(); return }
        guard let style else { return }
        do {
            let chart = try makeChart(style: style)
            let sectionIDs = draft.blocks.map(\.id)
            let token = UUID()
            previewToken = token
            preview = .loading
            Task {
                do {
                    let rendered = try await withCheckedThrowingContinuation {
                        (result: CheckedContinuation<ArrangementResult, Error>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            result.resume(with: Result { try renderArrangement(chart, style: style) })
                        }
                    }
                    guard previewToken == token else { return }
                    let timeline = PreviewTimeline(arrangement: rendered, chart: chart, sectionIDs: sectionIDs)
                    try play(rendered.midi, timeline: timeline, token: token)
                } catch {
                    guard previewToken == token else { return }
                    stopPreview()
                    message = error.localizedDescription
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func play(_ midi: Data, timeline: PreviewTimeline, token: UUID) throws {
        let player = try AVMIDIPlayer(data: midi, soundBankURL: nil)
        player.prepareToPlay()
        self.player = player
        preview = .playing
        followPreview(timeline.position(at: 0))
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.previewToken == token, let player = self.player else { return }
                let time = player.currentPosition
                let progress = min(1, time / timeline.duration)
                if progress - self.previewProgress >= 0.002 { self.previewProgress = progress }
                self.followPreview(timeline.position(at: time))
            }
        }
        previewTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        player.play { [weak self] in
            Task { @MainActor in
                if self?.previewToken == token { self?.stopPreview() }
            }
        }
    }

    private func followPreview(_ position: PreviewTimeline.Position?) {
        guard let position, previewPosition != position else { return }
        if previewPosition?.barNumber != position.barNumber {
            if selectedBlock != position.sectionID { selectedBlock = position.sectionID }
            if selectedBar != position.barIndex { selectedBar = position.barIndex }
        }
        previewPosition = position
    }

    func stopPreview() {
        guard preview != .idle else { return }
        previewToken = nil
        previewTimer?.invalidate()
        previewTimer = nil
        player?.stop()
        player = nil
        previewPosition = nil
        previewProgress = 0
        preview = .idle
    }

    func beginExport(_ format: ArrangementFormat) {
        guard !busy, !draft.blocks.isEmpty, let style else { return }
        do {
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let projectTitle = title.isEmpty ? "未命名编曲" : title
            let safeTitle = projectTitle.replacingOccurrences(of: "/", with: "／")
            let chart = try makeChart(style: style)
            let museScore = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ArrangementFormat.museScore.bundleID)
            if format == .museScore && museScore == nil { throw invalid("请先安装 MuseScore Studio，再导出 .mscz 工程。") }

            let panel = NSSavePanel()
            panel.title = "导出到 \(format.title)"
            panel.prompt = "保存"
            panel.nameFieldLabel = "保存为："
            panel.nameFieldStringValue = "\(safeTitle).\(format.extensionName)"
            panel.allowedContentTypes = [UTType(filenameExtension: format.extensionName) ?? .data]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            busy = true
            exported = nil
            Task {
                defer { busy = false }
                do {
                    try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                        DispatchQueue.global(qos: .userInitiated).async {
                            result.resume(with: Result {
                                try ArrangementExport.write(chart, style: style, title: projectTitle, format: format,
                                                            destination: destination, museScore: museScore)
                            })
                        }
                    }
                    exported = Exported(url: destination, format: format)
                } catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }

    func openExport(_ file: Exported) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: file.format.bundleID) else {
            message = "找不到 \(file.format.title)。文件已保存。"
            return
        }
        NSWorkspace.shared.open([file.url], withApplicationAt: app, configuration: .init()) { _, error in
            if let error { Task { @MainActor in self.message = error.localizedDescription } }
        }
    }
}
