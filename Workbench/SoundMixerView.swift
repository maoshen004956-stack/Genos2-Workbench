import SwiftUI

struct SoundMixerView: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    private let families = ["钢琴", "钟琴与键盘打击", "风琴与手风琴", "吉他", "贝斯", "弦乐", "合奏与人声", "铜管",
                            "萨克斯与簧管", "笛管", "合成主音", "合成铺底", "合成音效", "民族乐器", "打击乐器", "环境音效"]

    private var fonts: [SoundFontReference] {
        var values = workspace.soundFonts
        if let current = workspace.draft.soundFont, !values.contains(where: { $0.id == current.id }) { values.append(current) }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("音色与混音").font(.title2.bold())
                    Text("边听边调，每首歌单独保存。未调整的声部自动跟随风格。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                Picker("音源", selection: Binding(get: { workspace.draft.soundFont?.id ?? "builtin" }, set: { id in
                    workspace.draft.soundFont = fonts.first { $0.id == id }
                })) {
                    Text("内置精选 · GeneralUser GS").tag("builtin")
                    ForEach(fonts) { Text($0.name).tag($0.id) }
                }
                Button(workspace.importingSound ? "正在检查…" : "导入音源…") { workspace.chooseSoundFont() }
                    .disabled(workspace.importingSound)
                    .help("导入完整的 General MIDI SF2 音源；会自动复制到本机曲库。")
            }
            if workspace.draft.soundFont != nil && SoundSources.url(for: workspace.draft.soundFont!) == nil {
                Label("这台电脑没有该自选音源，试听与 WAV 暂用内置音源。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button { workspace.togglePreview() } label: {
                    Label(workspace.preview == .playing ? "暂停" : workspace.preview == .loading ? "取消" : "试听",
                          systemImage: workspace.preview == .playing ? "pause.fill" : "play.fill")
                }.disabled(workspace.preview == .idle && workspace.enabledParts.isEmpty)
                Button("停止") { workspace.stopPreview() }.disabled(workspace.preview == .idle)
                Spacer()
                Image(systemName: "speaker.wave.2")
                Slider(value: $workspace.masterGain, in: 0...1).frame(width: 125).accessibilityLabel("总音量")
                Text("\(Int(workspace.masterGain * 100))%").monospacedDigit().frame(width: 35)
            }
            Divider()
            HStack(spacing: 12) {
                Text("输出 / 独听").frame(width: 94, alignment: .leading)
                Text("乐器音色").frame(width: 220, alignment: .leading)
                Text("音量").frame(width: 112)
                Text("左右位置").frame(width: 86)
                Text("混响").frame(width: 86)
                Spacer(minLength: 0)
            }.font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(AccompanimentPart.allCases) { part in channel(part) }
                }
                .padding(.vertical, 3)
            }.frame(height: 320)
            Divider()
            HStack {
                Button("全部输出") { workspace.setAllParts(enabled: true) }
                Button("恢复风格混音") { workspace.resetMix() }
                if workspace.soloPart != nil { Button("取消独听") { workspace.soloPart = nil } }
                Spacer()
                Button("导出 WAV 音频…") { workspace.beginExport(.audio) }
                    .disabled(workspace.busy || workspace.enabledParts.isEmpty)
            }
            Text("勾选的声部参加试听与导出；独听仅用于试听。WAV 保留当前音源及完整混音，MIDI 和乐谱在目标软件中使用其音源。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(24).frame(width: 760)
    }

    private func channel(_ part: AccompanimentPart) -> some View {
        let present = workspace.availableParts.contains(part)
        let mix = workspace.partMix(part)
        return HStack(spacing: 12) {
            HStack(spacing: 5) {
                Toggle(part.name, isOn: Binding(get: { present && workspace.isPartEnabled(part) }, set: {
                    workspace.setPart(part, enabled: $0)
                })).toggleStyle(.checkbox).font(.system(size: 12))
                Button {
                    workspace.soloPart = workspace.soloPart == part ? nil : part
                } label: {
                    Image(systemName: "headphones")
                        .foregroundStyle(workspace.soloPart == part ? Color.accentColor : .secondary)
                }.buttonStyle(.borderless).help("独听" + part.name)
            }.frame(width: 94, alignment: .leading)
            instrument(part).frame(width: 220, alignment: .leading)
            control(part, key: \.volume, controller: 7, fallback: 100, width: 112, name: "音量")
            control(part, key: \.pan, controller: 10, fallback: 64, width: 86, name: "左右位置")
            control(part, key: \.reverb, controller: 91, fallback: 40, width: 86, name: "混响")
            Button { workspace.setMix(part) { $0 = PartMix() } } label: {
                Image(systemName: "arrow.uturn.backward")
            }.buttonStyle(.borderless).disabled(mix.isDefault).help("恢复这个声部的风格设置")
        }
        .disabled(!present)
        .opacity(present ? 1 : 0.4)
        .frame(height: 28)
    }

    private func instrument(_ part: AccompanimentPart) -> some View {
        let program = workspace.partMix(part).program
        let automatic = workspace.style.map { part.instrumentName(in: $0) } ?? "风格音色"
        let label = program.map { value in
            part.isDrum ? generalMIDIDrumKits.first { $0.program == value }?.name ?? "鼓组 \(value)" : generalMIDIInstrumentNames[Int(value)]
        } ?? "跟随风格 · \(automatic)"
        return Menu {
            Button("跟随风格音色") { workspace.setMix(part) { $0.program = nil } }
            Divider()
            if part.isDrum {
                ForEach(generalMIDIDrumKits, id: \.program) { kit in
                    Button(kit.name) { workspace.setMix(part) { $0.program = kit.program } }
                }
            } else {
                ForEach(families.indices, id: \.self) { family in
                    Menu(families[family]) {
                        ForEach((family * 8)..<(family * 8 + 8), id: \.self) { index in
                            Button(generalMIDIInstrumentNames[index]) { workspace.setMix(part) { $0.program = UInt8(index) } }
                        }
                    }
                }
            }
        } label: { Text(label).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading) }
        .accessibilityLabel(part.name + "音色")
    }

    private func control(_ part: AccompanimentPart, key: WritableKeyPath<PartMix, UInt8?>,
                         controller: UInt8, fallback: UInt8, width: CGFloat, name: String) -> some View {
        let binding = Binding<Double>(get: {
            Double(workspace.partMix(part)[keyPath: key] ?? workspace.style?.initialControllers[part.rawValue]?[controller] ?? fallback)
        }, set: { value in workspace.setMix(part) { $0[keyPath: key] = UInt8(min(127, max(0, value.rounded()))) } })
        return HStack(spacing: 3) {
            Slider(value: binding, in: 0...127, step: 1).accessibilityLabel(part.name + name)
            if controller == 7 { Text("\(Int(binding.wrappedValue))").font(.caption2).monospacedDigit().frame(width: 24) }
        }.frame(width: width).help("\(name)：\(Int(binding.wrappedValue))；点恢复可继续跟随风格。")
    }
}
