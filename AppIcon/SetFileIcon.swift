import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let image = NSImage(contentsOfFile: arguments[1]),
      NSWorkspace.shared.setIcon(image, forFile: arguments[2], options: []) else {
    FileHandle.standardError.write(Data("无法设置 DMG 的 Finder 图标。\n".utf8))
    exit(1)
}
