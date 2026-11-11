# Genos2 伴奏工作台

这是一个 macOS 编曲应用。选择 Yamaha Genos2 风格，输入段落和和弦，即可生成伴奏并导出分轨 MIDI、MuseScore 工程或 Guitar Pro 乐谱。

在「段落编排」上方点「乐器」，可按实际音色勾选节奏、贝斯、和弦、铺底和乐句声部。选择随歌曲草稿保存，并同时应用到试听和所有导出格式。未勾选的声部不会生成音轨。

需要 macOS 14 或更新版本以及 Xcode 命令行工具。构建脚本默认使用同级目录下的 `yamaha-sx900/Genos2` 曲库，也可将曲库放在本仓库的 `Genos2/` 下，或用 `GENOS2_STYLE_LIBRARY` 指定路径。构建会把曲库打包到应用内。Git 仓库包含伴奏引擎源码和打包脚本，Yamaha 曲库与安装产物在本地管理。

```sh
./build-workbench --dmg
./arrange SkyPop-demo.txt SkyPop-demo.mid
```

应用与 DMG 生成在项目根目录。导出 `.mscz` 时需要本机安装 MuseScore Studio。
