import SwiftUI
import AppKit
import SXCore

@main
struct WorkbenchApp: App {
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        WindowGroup("伴奏工作台") {
            WorkbenchView(workspace: workspace)
                .frame(minWidth: 1050, minHeight: 690)
                .preferredColorScheme(.light)
                .environment(\.locale, Locale(identifier: "zh_Hans"))
        }
        .defaultSize(width: 1240, height: 790)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

private let ink = Color(hex: 0x171831)
private let muted = Color(hex: 0x62647A)
private let line = Color(hex: 0xE4E3EB)
private let canvas = Color(hex: 0xF5F5FA)
private let violet = Color(hex: 0x5042CA)
private let violetTint = Color(hex: 0xEEEAFD)
private let dark = Color(hex: 0x1D1C34)
private let darkText = Color(hex: 0xC8C6DF)
private let dragSpace = "arrangementWorkspace"

private enum DropLocation: Hashable {
    case segment(UUID)
    case bar(UUID, Int)
}

private enum DragSource: Equatable {
    case segment(UUID, String)
    case measure(UUID, Int, String)
    case chord(String)

    var label: String {
        switch self {
        case let .segment(_, name), let .measure(_, _, name), let .chord(name): return name
        }
    }

    func accepts(_ target: DropLocation) -> Bool {
        switch (self, target) {
        case let (.segment(source, _), .segment(destination)): return source != destination
        case let (.measure(source, index, _), .bar(destination, bar)): return source != destination || index != bar
        case (.chord, .bar): return true
        default: return false
        }
    }
}

private struct DropFrames: PreferenceKey {
    static let defaultValue: [DropLocation: CGRect] = [:]
    static func reduce(value: inout [DropLocation: CGRect], nextValue: () -> [DropLocation: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private extension View {
    func targetFrame(_ target: DropLocation) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(key: DropFrames.self, value: [target: geometry.frame(in: .named(dragSpace))])
            }
        }
    }

    func arrangeDrag(_ item: DragSource, action: @escaping (DragSource, CGPoint, Bool) -> Void) -> some View {
        highPriorityGesture(DragGesture(minimumDistance: 5, coordinateSpace: .named(dragSpace))
            .onChanged { action(item, $0.location, false) }
            .onEnded { action(item, $0.location, true) })
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double(hex >> 16) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

private struct SectionTint {
    let foreground: Color
    let background: Color

    init(_ pattern: String) {
        switch patternLabel(pattern) {
        case "前奏": (foreground, background) = (Color(hex: 0x297366), Color(hex: 0xE0F1EC))
        case "加花", "间奏": (foreground, background) = (Color(hex: 0x905B21), Color(hex: 0xF8EEDC))
        case "尾奏": (foreground, background) = (Color(hex: 0x5D657A), Color(hex: 0xEEF0F5))
        default: (foreground, background) = (violet, violetTint)
        }
    }
}

private struct WorkbenchView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.undoManager) private var undoManager
    @State private var query = ""
    @State private var category = "pop"
    @State private var showExport = false
    @State private var showDemo = false
    @State private var showInstruments = false
    @State private var showPaste = false
    @State private var pasteText = ""
    @State private var confirmNew = false
    @State private var paletteRoot = 0
    @State private var paletteMode = PaletteMode.triads
    @State private var dropFrames: [DropLocation: CGRect] = [:]
    @State private var drag: (item: DragSource, point: CGPoint)?
    @FocusState private var editingBar: Int?
    @FocusState private var titleFocused: Bool
    @State private var editingTitle = false
    @State private var songTitle = ""

    private enum PaletteMode: String, CaseIterable, Identifiable {
        case triads = "三和弦"
        case sevenths = "七和弦"
        case colors = "挂留与加音"
        var id: Self { self }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 254)
            VStack(spacing: 0) {
                header
                timeline
                editor
                if workspace.current != nil { palette }
                if let exported = workspace.exported { exportNotice(exported) }
            }
            .background(canvas)
            .foregroundStyle(ink)
        }
        .coordinateSpace(name: dragSpace)
        .onPreferenceChange(DropFrames.self) { dropFrames = $0 }
        .overlay(alignment: .topLeading) {
            if let drag {
                Text(drag.item.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(violet, in: RoundedRectangle(cornerRadius: 7))
                    .shadow(color: .black.opacity(0.17), radius: 5, y: 2)
                    .position(x: drag.point.x + 24, y: drag.point.y - 22)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .alert("请检查编曲", isPresented: Binding(get: { workspace.message != nil }, set: {
            if !$0 { workspace.message = nil }
        })) {
            Button("好", role: .cancel) { workspace.message = nil }
        } message: {
            Text(workspace.message ?? "")
        }
        .alert("新建编曲", isPresented: $confirmNew) {
            Button("取消", role: .cancel) {}
            Button("新建") { workspace.newDraft() }
        } message: {
            Text("当前草稿将由新编曲替换。")
        }
        .sheet(isPresented: $showPaste) { pastePanel }
    }

    private var target: DropLocation? {
        guard let drag else { return nil }
        return target(for: drag.item, at: drag.point)
    }

    private func target(for item: DragSource, at point: CGPoint) -> DropLocation? {
        dropFrames.first { item.accepts($0.key) && $0.value.contains(point) }?.key
    }

    private func handleDrag(_ item: DragSource, point: CGPoint, finished: Bool) {
        guard finished else {
            drag = (item, point)
            return
        }
        drag = nil
        guard let location = target(for: item, at: point) else { return }
        switch (item, location) {
        case let (.segment(source, _), .segment(destination)):
            _ = workspace.move(source, to: destination)
        case let (.chord(chord), .bar(block, index)):
            editingBar = nil
            workspace.setBar(block, at: index, to: chord)
            workspace.selectedBar = index
        case let (.measure(source, original, _), .bar(block, index)):
            editingBar = nil
            workspace.swapBars(source, original, block, index)
        default: break
        }
    }

    private var filteredStyles: [StyleEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return workspace.entries.filter { entry in
            (category.isEmpty || entry.category == category) &&
                (text.isEmpty || entry.name.localizedCaseInsensitiveContains(text) ||
                 entry.originalName.localizedCaseInsensitiveContains(text) ||
                 (categoryLabels[entry.category] ?? "").localizedCaseInsensitiveContains(text))
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color(hex: 0x6F5AE4), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text("伴奏工作台").font(.system(size: 17, weight: .bold))
                    Text("YAMAHA GENOS2").font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1.0).foregroundStyle(darkText)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 38)
            .padding(.bottom, 32)

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("风格曲库").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("\(workspace.entries.count) 首").font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(darkText)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(darkText)
                    ZStack(alignment: .leading) {
                        if query.isEmpty {
                            Text("搜索风格").foregroundStyle(darkText)
                                .allowsHitTesting(false).accessibilityHidden(true)
                        }
                        TextField("", text: $query)
                            .textFieldStyle(.plain).foregroundStyle(.white)
                            .accessibilityLabel("搜索风格")
                    }
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(darkText)
                            .accessibilityLabel("清除搜索")
                    }
                }
                .font(.system(size: 12))
                .padding(10)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))

                Picker("分类", selection: $category) {
                    Text("全部分类").tag("")
                    ForEach(Set(workspace.entries.map(\.category)).sorted(), id: \.self) { key in
                        Text(categoryLabels[key] ?? key).tag(key)
                    }
                }
                .labelsHidden()
                .colorScheme(.dark)
                .accessibilityLabel("风格分类")
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 11)

            if filteredStyles.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(workspace.entries.isEmpty ? "没有可用的风格，请导入 .prs 文件" : "没有匹配的风格")
                        .font(.system(size: 12))
                    if !query.isEmpty && !category.isEmpty {
                        Button("搜索所有分类") { category = "" }.buttonStyle(.plain).underline()
                    }
                }
                .foregroundStyle(darkText)
                .padding(.horizontal, 19)
                .padding(.top, 15)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(filteredStyles) { entry in
                                styleRow(entry).id(entry.id)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                    }
                    .onAppear {
                        proxy.scrollTo(workspace.draft.stylePath, anchor: .center)
                    }
                }
            }

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
            HStack {
                Menu {
                    Button("导入到\(categoryLabels[category] ?? categoryLabels[workspace.activeEntry?.category ?? "pop"] ?? "流行")…") {
                        workspace.importStyles(category: category)
                        query = ""
                    }
                    Button("替换当前风格…") { workspace.importStyles(category: category, replacing: true) }
                        .disabled(workspace.activeEntry == nil)
                    if let entry = workspace.activeEntry {
                        Button("设置当前风格的中文名…") { workspace.renameStyle(entry) }
                    }
                    if workspace.canRestoreActiveStyle {
                        Button("恢复当前风格的内置版本") { workspace.restoreActiveStyle() }
                    }
                } label: {
                    Label("导入／更新风格", systemImage: "square.and.arrow.down")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .colorScheme(.dark)
                Spacer()
                Button { confirmNew = true } label: { Image(systemName: "square.and.pencil") }
                    .buttonStyle(.plain).help("新建编曲").accessibilityLabel("新建编曲")
            }
            .padding(.horizontal, 19).padding(.vertical, 15)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(darkText)
        }
        .foregroundStyle(.white)
        .background(dark)
    }

    private func styleRow(_ entry: StyleEntry) -> some View {
        let selected = entry.id == workspace.draft.stylePath
        return Button {
            workspace.selectStyle(entry)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? "waveform" : "music.note")
                    .frame(width: 15)
                    .foregroundStyle(selected ? .white : darkText.opacity(0.65))
                Text(entry.name).lineLimit(1).font(.system(size: 12, weight: selected ? .semibold : .regular))
                Spacer(minLength: 2)
                if entry.isUpdate {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 9))
                        .accessibilityLabel("本地版本")
                }
                if selected { Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold)) }
            }
            .padding(.horizontal, 9).padding(.vertical, 9)
            .background(selected ? Color(hex: 0x5848BC) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? .white : darkText)
        .help("原始文件：\(entry.path)")
        .contextMenu {
            Button("设置中文名…") { workspace.renameStyle(entry) }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 17) {
            VStack(alignment: .leading, spacing: 6) {
                titleEditor
                HStack(spacing: 6) {
                    Image(systemName: "music.note")
                    Text(workspace.activeEntry?.name ?? "选择风格")
                    if let entry = workspace.activeEntry {
                        Text("·").foregroundStyle(muted.opacity(0.65))
                        Text(categoryLabels[entry.category] ?? entry.category)
                    }
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                Menu {
                    ForEach([false, true], id: \.self) { minor in
                        Menu(minor ? "小调" : "大调") {
                            ForEach(SongKey.choices.filter { $0.minor == minor }, id: \.self) { key in
                                Button {
                                    workspace.setKey(key)
                                    paletteRoot = key.tonic
                                } label: {
                                    if key == workspace.key { Label(key.name, systemImage: "checkmark") }
                                    else { Text(key.name) }
                                }
                            }
                        }
                    }
                } label: {
                    Text(workspace.key.name).font(.system(size: 13, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 8)
                .accessibilityLabel("整曲调号")
                .accessibilityValue(workspace.key.name)
                .help("改变整曲调号并移调和弦")
                Divider().frame(height: 21)
                HStack(spacing: 3) {
                    TextField(workspace.style.map { String(format: "%.0f", $0.bpm) } ?? "原速", text: $workspace.draft.bpm)
                        .textFieldStyle(.plain).multilineTextAlignment(.center)
                        .frame(width: 48)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .accessibilityLabel("速度 BPM")
                    Text("BPM").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
                }
                .padding(.horizontal, 10)
                Divider().frame(height: 21)
                Menu {
                    Button("跟随风格\(workspace.style.map { "（\(SongMeter($0).name)）" } ?? "")") { workspace.setMeter(nil) }
                    Divider()
                    ForEach(SongMeter.choices, id: \.self) { meter in
                        Button {
                            workspace.setMeter(meter)
                        } label: {
                            if workspace.draft.meter == meter { Label(meter.name, systemImage: "checkmark") }
                            else { Text(meter.name) }
                        }
                    }
                } label: {
                    Text(workspace.meter?.name ?? "–")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(.horizontal, 8)
                .accessibilityLabel("整曲拍号")
                .accessibilityValue(workspace.meter?.name ?? "")
                .help("调整整曲拍号，原风格按新小节长度缩放")
            }
            .frame(height: 38)
            .background(.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(line) }

            Button {
                editingBar = nil
                workspace.togglePreview()
            } label: {
                Label(workspace.preview == .idle ? "试听" : workspace.preview == .loading ? "取消" : "停止",
                      systemImage: workspace.preview == .idle ? "play.fill" : "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(violet)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(violetTint, in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain)
            .disabled(workspace.enabledParts.isEmpty)
            .help("用本机音源试听整曲伴奏")

            Button {
                showExport.toggle()
            } label: {
                HStack(spacing: 7) {
                    if workspace.busy { ProgressView().controlSize(.small).tint(.white) }
                    else { Image(systemName: "square.and.arrow.up") }
                    Text(workspace.busy ? "正在导出…" : "导出")
                    if !workspace.busy { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(violet, in: RoundedRectangle(cornerRadius: 9))
                .opacity(workspace.enabledParts.isEmpty ? 0.45 : 1)
            }
            .buttonStyle(.plain)
            .disabled(workspace.busy || workspace.enabledParts.isEmpty)
            .keyboardShortcut("e", modifiers: .command)
            .popover(isPresented: $showExport, arrowEdge: .bottom) { exportPicker }
        }
        .padding(.horizontal, 27)
        .padding(.top, 34)
        .padding(.bottom, 17)
    }

    private var titleEditor: some View {
        Group {
            if editingTitle {
                TextField("歌曲名称", text: $songTitle)
                    .textFieldStyle(.plain)
                    .focused($titleFocused)
                    .onSubmit { finishTitle() }
                    .onExitCommand { editingTitle = false; titleFocused = false }
                    .onChange(of: titleFocused) { _, focused in if !focused && editingTitle { finishTitle() } }
                    .accessibilityLabel("歌曲名称")
            } else {
                HStack(spacing: 8) {
                    Text(workspace.draft.title).lineLimit(1)
                    Image(systemName: "pencil")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(muted)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { beginTitle() }
                .help("双击修改歌名")
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(workspace.draft.title)
                .accessibilityAction(named: Text("修改歌名")) { beginTitle() }
            }
        }
        .font(.system(size: 27, weight: .bold))
    }

    private func beginTitle() {
        songTitle = workspace.draft.title
        editingTitle = true
        titleFocused = true
    }

    private func finishTitle() {
        let value = songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        editingTitle = false
        titleFocused = false
        if !value.isEmpty, value != workspace.draft.title { workspace.draft.title = value }
    }

    private var timeline: some View {
        let available = workspace.availableParts
        let enabled = available.subtracting(workspace.draft.mutedParts ?? []).count
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("段落编排").font(.system(size: 14, weight: .bold))
                Text("\(workspace.barCount) 小节").font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(muted)
                Spacer()
                Button { showInstruments = true } label: {
                    Label("乐器 \(enabled)/\(available.count)", systemImage: "slider.horizontal.3")
                }
                .disabled(workspace.style == nil)
                .help("选择参加试听和导出的乐器声部")
                .popover(isPresented: $showInstruments) { instrumentPicker }
                Button { showDemo = true } label: {
                    Label("风格示例", systemImage: "music.note.list")
                }
                .disabled(workspace.style == nil)
                .popover(isPresented: $showDemo) { demoPicker }
                Button {
                    if let block = workspace.current { delete(block.id) }
                } label: {
                    Label("删除所选段落", systemImage: "trash")
                }
                .disabled(workspace.current == nil)
                .help("删除选中的段落，按 ⌘Z 可撤销")
                Menu {
                    ForEach(workspace.patterns, id: \.self) { pattern in
                        Button(patternDisplayName(pattern)) { workspace.add(pattern) }
                    }
                } label: {
                    Label("添加段落", systemImage: "plus")
                }
                .fixedSize()
                .disabled(workspace.patterns.isEmpty)
            }
            if let position = workspace.previewPosition {
                HStack(spacing: 10) {
                    Text("试听中 · 第 \(position.barNumber) 小节 · \(position.chord ?? "–")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(violet)
                    ProgressView(value: workspace.previewProgress)
                        .tint(violet)
                        .accessibilityLabel("试听进度")
                }
            }
            if workspace.draft.blocks.isEmpty {
                Text("点击「添加段落」开始编排。")
                    .font(.system(size: 12)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 9) {
                            ForEach(workspace.draft.blocks) { block in
                                SectionCard(block: block, workspace: workspace, targeted: target == .segment(block.id),
                                            dragAction: handleDrag)
                                    .targetFrame(.segment(block.id))
                                    .contextMenu {
                                        Button("删除段落", role: .destructive) { delete(block.id) }
                                    }
                                    .id(block.id)
                            }
                        }
                        .padding(1)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: workspace.previewPosition?.sectionID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
        .padding(15)
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(line) }
        .padding(.horizontal, 27)
        .padding(.bottom, 13)
    }

    private var instrumentPicker: some View {
        let available = workspace.availableParts
        let enabled = workspace.enabledParts
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("乐器声部").font(.system(size: 16, weight: .bold))
                Spacer()
                Button("全选") { workspace.setAllParts(enabled: true) }
                    .disabled(enabled == available)
                Button("清空") { workspace.setAllParts(enabled: false) }
                    .disabled(enabled.isEmpty)
            }
            if let style = workspace.style {
                ForEach(AccompanimentPart.allCases) { part in
                    let present = available.contains(part)
                    let instrument = part.instrumentName(in: style)
                    Toggle(isOn: Binding(get: { present && workspace.isPartEnabled(part) }, set: {
                        workspace.setPart(part, enabled: $0)
                    })) {
                        HStack {
                            Text(part.name).fontWeight(.medium)
                            Spacer()
                            Text(present ? instrument : "当前段落未使用").foregroundStyle(muted)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!present)
                    .accessibilityLabel(part.name + "，" + (present ? instrument : "当前段落未使用"))
                }
            }
            Text(enabled.isEmpty ? "至少选择一个声部，即可试听或导出。" : "仅试听和导出已勾选的声部。")
                .font(.system(size: 11)).foregroundStyle(muted)
        }
        .frame(width: 280, alignment: .leading)
        .padding(16)
        .foregroundStyle(ink)
    }

    private var demoPicker: some View {
        VStack(alignment: .leading, spacing: 11) {
            if let example = workspace.demo {
                Text(example.name).font(.system(size: 16, weight: .bold))
                Text(example.description).font(.system(size: 12)).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text("\(example.draft.key?.name ?? "")  ·  \(example.draft.bpm) BPM  ·  \(workspace.style.map { SongMeter($0).name } ?? "")")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(violet)
                Text(example.draft.blocks.map(\.name).joined(separator: " → "))
                    .font(.system(size: 11)).foregroundStyle(muted)
                HStack {
                    Spacer()
                    Button("载入示例") {
                        showDemo = false
                        editingBar = nil
                        let window = NSApp.keyWindow
                        window?.makeFirstResponder(nil)
                        workspace.loadDemo(example, undoManager: window?.undoManager ?? undoManager)
                        paletteRoot = workspace.key.tonic
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(violet)
                    .help("载入后可按 ⌘Z 恢复当前编曲")
                }
            }
        }
        .frame(width: 310, alignment: .leading)
        .padding(16)
        .foregroundStyle(ink)
    }

    private func delete(_ id: UUID) {
        editingBar = nil
        let window = NSApp.keyWindow
        window?.makeFirstResponder(nil)
        workspace.remove(id, undoManager: window?.undoManager ?? undoManager)
    }

    private var editor: some View {
        let playingBar = workspace.previewPosition.map { DropLocation.bar($0.sectionID, $0.barIndex) }
        return ScrollViewReader { proxy in
            chordEditor.onChange(of: playingBar) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private var chordEditor: some View {
        ScrollView {
            if let block = workspace.current {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("段落和弦").font(.system(size: 11, weight: .semibold)).foregroundStyle(muted)
                            TextField("段落名称", text: Binding(get: {
                                workspace.draft.blocks.first(where: { $0.id == block.id })?.name ?? ""
                            }, set: { value in workspace.update(block.id) { $0.name = value } }))
                            .font(.system(size: 23, weight: .bold))
                            .textFieldStyle(.plain)
                            .accessibilityLabel("段落名称")
                        }
                        Spacer()
                        Menu {
                            ForEach(workspace.patterns, id: \.self) { pattern in
                                Button {
                                    workspace.update(block.id) { $0.pattern = pattern }
                                    workspace.selectedBar = 0
                                } label: {
                                    if block.pattern == pattern { Label(patternDisplayName(pattern), systemImage: "checkmark") }
                                    else { Text(patternDisplayName(pattern)) }
                                }
                            }
                        } label: { Text(patternDisplayName(block.pattern)) }
                        .fixedSize()
                        .help("切换本段使用的风格变奏")
                        Button {
                            pasteText = (0..<workspace.count(block)).map { workspace.bar(block.id, at: $0) }.joined(separator: " | ")
                            showPaste = true
                        } label: { Label("批量输入", systemImage: "text.line.first.and.arrowtriangle.forward") }
                        Menu {
                            Button("复制段落") { workspace.duplicate(block.id) }
                            if let index = workspace.draft.blocks.firstIndex(where: { $0.id == block.id }) {
                                if index > 0 { Button("向左移动") { _ = workspace.move(block.id, to: workspace.draft.blocks[index - 1].id) } }
                                if index + 1 < workspace.draft.blocks.count {
                                    Button("向右移动") { _ = workspace.move(block.id, to: workspace.draft.blocks[index + 1].id) }
                                }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .fixedSize()
                        .accessibilityLabel("段落操作")
                    }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 112), spacing: 9), count: 4), spacing: 9) {
                        ForEach(0..<workspace.count(block), id: \.self) { index in
                            BarCell(block: block, index: index, workspace: workspace, editing: $editingBar,
                                    targeted: target == .bar(block.id, index), dragAction: handleDrag)
                                .targetFrame(.bar(block.id, index))
                                .id(DropLocation.bar(block.id, index))
                        }
                        if block.allowsResizing {
                            Button { workspace.addBar(to: block) } label: {
                                Label("添加小节", systemImage: "plus")
                                    .frame(maxWidth: .infinity, minHeight: 61)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(violet)
                            .background(violetTint.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(violet.opacity(0.26), style: StrokeStyle(dash: [4, 4])) }
                        }
                    }
                    .id(block.id)

                    if block.bars.count > workspace.count(block) {
                        Text("当前变奏使用前 \(workspace.count(block)) 小节，其余和弦仍保存在草稿里。")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    } else {
                        Text("小节内用空格分隔和弦；可用 Dm7:1 G7:3 指定拍数。")
                            .font(.system(size: 11)).foregroundStyle(muted)
                    }
                }
                .padding(16)
                .background(.white, in: RoundedRectangle(cornerRadius: 13))
                .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(line) }
                .padding(.horizontal, 27)
                .padding(.bottom, 14)
            }
        }
        .frame(maxHeight: .infinity)
        .onChange(of: workspace.selectedBlock) { editingBar = nil }
        .onChange(of: editingBar) { _, index in
            if let index { workspace.selectedBar = index }
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: "pianokeys").font(.system(size: 15, weight: .medium)).foregroundStyle(violet)
                Text("和弦面板").font(.system(size: 13, weight: .bold))
                Spacer()
                if let block = workspace.current {
                    Text("第 \(workspace.startBar(block.id) + min(workspace.selectedBar, max(0, workspace.count(block) - 1))) 小节")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(violet)
                }
                Picker("根音", selection: $paletteRoot) {
                    ForEach(0..<12, id: \.self) { index in Text(Chord(root: index).name).tag(index) }
                }.labelsHidden().frame(width: 64).accessibilityLabel("和弦面板根音")
                Picker("和弦类型", selection: $paletteMode) {
                    ForEach(PaletteMode.allCases) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 106).accessibilityLabel("和弦面板类型")
            }

            HStack(spacing: 7) {
                ForEach(paletteChords, id: \.self) { chord in
                    Button {
                        editingBar = nil
                        workspace.apply(chord)
                    } label: {
                        Text(chord)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .frame(minWidth: 36)
                            .padding(.horizontal, 8)
                            .frame(height: 31)
                            .background(violetTint, in: RoundedRectangle(cornerRadius: 7))
                            .foregroundStyle(violet)
                    }
                    .buttonStyle(.plain)
                    .arrangeDrag(.chord(chord), action: handleDrag)
                    .help("点击填入所选小节，或拖到任意小节")
                }
                Spacer(minLength: 5)
                Text("点击填入，或拖到小节").font(.system(size: 11)).foregroundStyle(muted)
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 11)
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(line) }
        .padding(.horizontal, 27)
        .padding(.bottom, 13)
    }

    private var paletteChords: [String] {
        let steps = [0, 2, 4, 5, 7, 9, 11]
        switch paletteMode {
        case .triads:
            let qualities: [Chord.Quality] = [.major, .minor, .minor, .major, .major, .minor, .diminished]
            return zip(steps, qualities).map { Chord(root: paletteRoot + $0, quality: $1).name }
        case .sevenths:
            let qualities: [Chord.Quality] = [.majorSeventh, .minorSeventh, .minorSeventh, .majorSeventh, .seventh, .minorSeventh, .halfDiminished]
            return zip(steps, qualities).map { Chord(root: paletteRoot + $0, quality: $1).name }
        case .colors:
            return [Chord.Quality.suspended, .suspendedSecond, .addNine, .sixth, .majorSeventhNine, .seventhSuspended]
                .map { Chord(root: paletteRoot, quality: $0).name }
        }
    }

    private var exportPicker: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("选择导出格式").font(.system(size: 14, weight: .bold)).padding(.bottom, 2)
            ForEach(ArrangementFormat.allCases) { format in
                Button {
                    showExport = false
                    Task { @MainActor in
                        await Task.yield()
                        workspace.beginExport(format)
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: format.symbol).frame(width: 25).foregroundStyle(violet)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(format.title)  .\(format.extensionName)").font(.system(size: 13, weight: .semibold))
                            Text(format.subtitle).font(.system(size: 11)).foregroundStyle(muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(muted)
                    }
                    .padding(9)
                    .background(canvas, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Text("在 Logic 打开 .mid 后，按 ⌘S 存成 .logicx。")
                .font(.system(size: 11)).foregroundStyle(muted)
        }
        .foregroundStyle(ink)
        .padding(15)
        .frame(width: 342)
    }

    private func exportNotice(_ exported: Workspace.Exported) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x297366))
            Text("已导出 \(exported.url.lastPathComponent)").lineLimit(1)
            Spacer()
            Button("在 \(exported.format.title) 中打开") { workspace.openExport(exported) }
            Button { workspace.exported = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("关闭导出提示")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 27).padding(.vertical, 8)
        .background(Color(hex: 0xE5F2EE))
    }

    private var pastePanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("批量输入和弦").font(.system(size: 19, weight: .bold))
            Text("用 | 或换行分隔小节，小节内用空格分隔和弦。")
                .font(.system(size: 12)).foregroundStyle(muted)
            TextEditor(text: $pasteText)
                .font(.system(size: 14, design: .monospaced))
                .frame(height: 92)
                .padding(6)
                .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(line) }
                .accessibilityLabel("和弦序列")
            HStack {
                Spacer()
                Button("取消") { showPaste = false }.keyboardShortcut(.cancelAction)
                Button("应用") {
                    guard let block = workspace.current else { return }
                    do {
                        try workspace.pasteBars(pasteText, into: block)
                        showPaste = false
                    } catch { pasteError = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
            if let pasteError { Text(pasteError).font(.system(size: 11)).foregroundStyle(.red) }
        }
        .padding(22)
        .frame(width: 490)
        .onDisappear { pasteError = nil }
    }

    @State private var pasteError: String?
}

private struct SectionCard: View {
    let block: Draft.Block
    @ObservedObject var workspace: Workspace
    let targeted: Bool
    let dragAction: (DragSource, CGPoint, Bool) -> Void

    var body: some View {
        let selected = workspace.selectedBlock == block.id
        let tint = SectionTint(block.pattern)
        let playing = workspace.previewPosition?.sectionID == block.id
        Button {
            workspace.stopPreview()
            workspace.select(block.id)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Text(patternDisplayName(block.pattern))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(tint.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 1)
                    Image(systemName: playing ? "waveform" : "line.3.horizontal")
                        .font(.system(size: 10)).foregroundStyle(muted)
                        .padding(3).contentShape(Rectangle())
                        .help("拖动以调整段落顺序")
                }
                Text(block.name.isEmpty ? patternLabel(block.pattern) : block.name)
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(ink).lineLimit(1)
                Text("第 \(workspace.startBar(block.id)) 小节 · \(workspace.count(block)) 小节")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            }
            .padding(9)
            .frame(width: 133, alignment: .leading)
            .background(tint.background, in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(
                playing ? violet : targeted || selected ? tint.foreground : tint.foreground.opacity(0.1),
                lineWidth: targeted || playing ? 2 : 1
            ) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .arrangeDrag(.segment(block.id, block.name), action: dragAction)
    }
}

private struct BarCell: View {
    let block: Draft.Block
    let index: Int
    @ObservedObject var workspace: Workspace
    var editing: FocusState<Int?>.Binding
    let targeted: Bool
    let dragAction: (DragSource, CGPoint, Bool) -> Void

    var body: some View {
        let selected = workspace.selectedBar == index
        let text = workspace.bar(block.id, at: index)
        let playhead = workspace.previewPosition
        let playing = playhead?.sectionID == block.id && playhead?.barIndex == index
        let invalidChord = workspace.style.map {
            (try? chordChanges(in: text, style: $0, meter: workspace.meter, context: "")) == nil
        } ?? false
        let bar = workspace.startBar(block.id) + index

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(String(format: "%02d", bar)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(selected ? violet : muted)
                Spacer()
                if playing {
                    Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(violet)
                        .accessibilityHidden(true)
                } else if invalidChord {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0xB74746)).help("检查和弦名称或拍数")
                }
                Image(systemName: "line.3.horizontal").font(.system(size: 9)).foregroundStyle(muted)
                    .padding(3).contentShape(Rectangle())
                    .arrangeDrag(.measure(block.id, index, text), action: dragAction)
                    .help("拖动以交换两个小节的和弦")
            }
            if playing, let playhead {
                playingChords(text, position: playhead)
            } else if playhead != nil {
                Text(text).font(.system(size: 15, weight: .semibold, design: .monospaced)).lineLimit(1)
            } else {
                TextField("输入和弦", text: Binding(get: {
                    workspace.bar(block.id, at: index)
                }, set: { workspace.setBar(block.id, at: index, to: $0) }))
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .textFieldStyle(.plain)
                .focused(editing, equals: index)
                .accessibilityLabel("第 \(bar) 小节和弦")
                .accessibilityIdentifier("bar-\(index + 1)")
                .onSubmit {
                    if index + 1 < workspace.count(block) { editing.wrappedValue = index + 1 }
                    else { editing.wrappedValue = nil }
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(minHeight: 61)
        .background(playing || selected || targeted ? violetTint.opacity(0.72) : canvas,
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(
            playing ? violet : invalidChord ? Color(hex: 0xD57877) : (selected || targeted ? violet : line),
            lineWidth: playing || targeted ? 2 : 1
        ) }
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.stopPreview()
            workspace.selectedBar = index
            editing.wrappedValue = index
        }
        .contextMenu {
            if block.allowsResizing {
                Button("删除这个小节", role: .destructive) { workspace.removeBar(from: block, at: index) }
                    .disabled(workspace.count(block) <= 1)
            }
        }
    }

    private func playingChords(_ text: String, position: PreviewTimeline.Position) -> some View {
        let written = text.split(whereSeparator: \.isWhitespace).map { String($0.prefix { $0 != ":" }) }
        let symbols = position.chordIndex == nil ? [position.chord ?? "–"] : written
        let activeIndex = position.chordIndex ?? 0
        return HStack(spacing: 5) {
            ForEach(symbols.indices, id: \.self) { index in
                let active = index == activeIndex
                Text(symbols[index])
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.75)
                    .padding(.horizontal, 4)
                    .foregroundStyle(active ? Color.white : muted)
                    .background(active ? violet : .clear, in: RoundedRectangle(cornerRadius: 4))
                    .layoutPriority(active ? 1 : 0)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(position.barNumber) 小节，正在播放 \(position.chord ?? "")")
    }
}
