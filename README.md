# CleanSpace

原生 SwiftUI macOS 清理工具，版本 1.0.0。

## 功能
- 扫描用户应用缓存、系统缓存、应用占用空间与常见卸载残留
- 按项目显示路径、类别和文件大小
- 将选中项目安全地移动到废纸篓，而非永久删除
- 应用启动器：打开、在 Finder 中显示、卸载应用
- 设置页显示版本号、系统要求和本应用卸载入口

## 构建

```bash
cd MacCleanUp
swift build -c release
```

应用需要在 macOS 13+ 上运行。将生成的可执行文件放入 `.app/Contents/MacOS/` 并补充 `Info.plist` 即可打包为应用；推荐使用 Xcode 打开此 Swift Package 进行签名和归档。
