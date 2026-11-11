import AppKit
import Foundation
import UniformTypeIdentifiers

struct SoundFontReference: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    var isValid: Bool {
        !id.isEmpty && id == URL(fileURLWithPath: id).lastPathComponent && id.hasSuffix(".sf2") && !name.isEmpty
    }
}

enum SoundSources {
    static var bundledURL: URL { Bundle.main.resourceURL!.appendingPathComponent("SoundFonts/GeneralUser-GS.sf2") }
    static var libraryURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/libfluidsynth.3.dylib") }
    static var userDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Genos2 Workbench/SoundFonts", isDirectory: true)
    }
    static func url(for reference: SoundFontReference) -> URL? {
        guard reference.isValid else { return nil }
        let url = userDirectory.appendingPathComponent(reference.id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

extension Workspace {
    var soundFontURL: URL { draft.soundFont.flatMap(SoundSources.url) ?? SoundSources.bundledURL }
    var soundFontLabel: String {
        guard let reference = draft.soundFont else { return "内置精选音源 · GeneralUser GS" }
        return SoundSources.url(for: reference) == nil ? "自选音源缺失，使用内置音源" : reference.name
    }

    func chooseSoundFont() {
        guard !importingSound else { return }
        let panel = NSOpenPanel()
        panel.title = "导入 SoundFont 音源"
        panel.prompt = "导入"
        panel.allowedContentTypes = [UTType(filenameExtension: "sf2") ?? .data]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        importingSound = true
        let reference = SoundFontReference(id: UUID().uuidString + ".sf2", name: source.deletingPathExtension().lastPathComponent)
        let destination = SoundSources.userDirectory.appendingPathComponent(reference.id)
        let library = SoundSources.libraryURL
        Task {
            defer { importingSound = false }
            do {
                try await withCheckedThrowingContinuation { (result: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        result.resume(with: Result {
                            let access = source.startAccessingSecurityScopedResource()
                            defer { if access { source.stopAccessingSecurityScopedResource() } }
                            let resolved = source.resolvingSymlinksInPath()
                            let info = try resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                            guard info.isRegularFile == true, let size = info.fileSize, (12...536_870_912).contains(size) else {
                                throw invalid("请选择不超过 512 MB 的 .sf2 音源文件。")
                            }
                            let stream = try FileHandle(forReadingFrom: resolved)
                            defer { try? stream.close() }
                            let header = try stream.read(upToCount: 12) ?? Data()
                            guard header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("sfbk".utf8) else {
                                throw invalid("这不是有效的 SF2 音源。请使用完整的 General MIDI 音源库。")
                            }
                            try FileManager.default.createDirectory(at: SoundSources.userDirectory, withIntermediateDirectories: true)
                            do {
                                try FileManager.default.copyItem(at: resolved, to: destination)
                                try AudioRenderer.validate(soundFont: destination, library: library)
                            } catch {
                                try? FileManager.default.removeItem(at: destination)
                                throw error
                            }
                        })
                    }
                }
                registerSoundFont(reference)
                draft.soundFont = reference
            } catch { message = error.localizedDescription }
        }
    }
}
