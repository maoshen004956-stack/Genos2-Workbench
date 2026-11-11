import SwiftUI

struct IRealImportView: View {
    let batch: IRealImportBatch
    @ObservedObject var workspace: Workspace
    var undoManager: UndoManager? = nil
    @State private var selection = 0
    @State private var useSuggestedStyle = true
    @State private var importError: String?

    private var song: IRealSong { batch.songs[selection] }
    private var style: StyleEntry? {
        useSuggestedStyle ? workspace.suggestedStyle(for: song) : workspace.activeEntry
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("导入 iReal Pro").font(.title2.bold())
                Spacer()
                if batch.songs.count > 1 { Text("\(batch.songs.count) 首歌曲").foregroundStyle(.secondary) }
            }
            if batch.songs.count > 1 {
                Picker("歌曲", selection: $selection) {
                    ForEach(batch.songs.indices, id: \.self) { index in
                        Text(batch.songs[index].title).tag(index)
                    }
                }
                .onChange(of: selection) { importError = nil }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(song.title).font(.title3.bold())
                if !song.composer.isEmpty { Text(song.composer).foregroundStyle(.secondary) }
                Text([song.key.name, song.meter?.name ?? "拍号跟随伴奏风格", song.style].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline)
                Text(song.bpm.map { "速度 \(String(format: "%g", $0)) BPM" } ?? "文件未指定速度，使用伴奏风格原速。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(song.sections.indices, id: \.self) { index in
                        let section = song.sections[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(section.name) · \(section.bars.count) 小节").font(.subheadline.bold())
                            if let detail = section.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                            Text(section.bars.joined(separator: "  |  "))
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(song.warnings, id: \.self) { warning in
                        Label(warning, systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(12)
            }
            .frame(minHeight: 130, maxHeight: 260)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))

            if let suggested = workspace.suggestedStyle(for: song), suggested.path != workspace.activeEntry?.path {
                Picker("伴奏风格", selection: $useSuggestedStyle) {
                    Text(suggested.name + "（建议）").tag(true)
                    Text((workspace.activeEntry?.name ?? "当前风格") + "（当前）").tag(false)
                }
            } else {
                Text("伴奏风格 · \(style?.name ?? "请先导入风格曲库")").font(.subheadline)
            }
            Text("共 \(song.sections.count) 个段落、\(song.sections.reduce(0) { $0 + $1.bars.count }) 小节 · 可继续编辑，按 ⌘Z 恢复原编曲。")
                .font(.caption).foregroundStyle(.secondary)
            if let importError { Text(importError).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("取消") { workspace.pendingIRealImport = nil }.keyboardShortcut(.cancelAction)
                Button("载入编曲") {
                    guard let style else { return }
                    do { try workspace.loadIRealSong(song, stylePath: style.path, undoManager: undoManager) }
                    catch { importError = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(style == nil)
            }
        }
        .padding(24)
        .frame(width: 580)
    }
}
