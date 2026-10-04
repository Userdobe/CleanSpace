# CleanSpace

CleanSpace 是一款原生 SwiftUI macOS 空间清理工具，目标是：**先解释，再清理；先保护，再释放**。

当前版本：**1.1.0**  
最低系统：**macOS 13 Ventura**  
当前交付架构：**Apple Silicon arm64**

## 功能概览

- 应用缓存扫描
- 应用占用空间统计
- 用户级系统缓存扫描
- 常见卸载残留扫描
- 深度日志与诊断报告扫描
- 本地保守型 AI 辅助分析：建议清理、建议复核、建议保留
- 应用启动器、Finder 定位、版本号和卸载入口
- 三步首次启动 Onboarding
- 浅色、深色、跟随系统主题
- 所有交互式清理默认移动到废纸篓，可恢复
- 基于 macOS `launchd` 的自动定时缓存清理后台守护进程

## 应用架构

```text
CleanSpace
├── SwiftUI App
│   ├── OnboardingView       首次启动引导
│   ├── ContentView          主窗口、导航、主题和页面路由
│   ├── CleanupStore         扫描状态、选择状态、清理操作
│   ├── AIResidueAnalyzer    本地可解释的保守安全评分
│   └── BrandIcon / GlassCard 视觉设计系统
│
├── CleanSpaceDaemon
│   ├── DaemonSettings       后台策略配置
│   ├── CleanSpaceDaemon     缓存扫描、年龄过滤、废纸篓移动
│   └── RunReport            JSONL 执行报告
│
├── Resources
│   └── com.cleanspace.daemon.plist.template
│
└── Scripts
    ├── install-daemon.sh
    └── uninstall-daemon.sh
```

### 1. SwiftUI App

主应用使用 `NavigationSplitView` 组织五个工作区：

- **概览**：Hero 区、空间统计、扫描分类
- **智能清理**：缓存、残留和系统缓存项目列表
- **深度扫描**：用户日志、系统日志和诊断报告
- **应用管理**：打开、Finder 定位、查看版本、卸载
- **设置**：主题、隐私说明、版本信息和后台守护进程安装指南

扫描任务通过 `Task` 执行，状态由 `CleanupStore` 发布到 SwiftUI。文件大小使用 `FileManager` 和 URL resource values 计算；应用包会递归计算其内部文件大小。

### 2. 本地 AI 辅助分析

`AIResidueAnalyzer` 是一个本地、可解释、保守的分析层。它综合以下信息：

- 路径是否位于系统保护目录
- 文件名是否像日志、崩溃报告、Updater 或 Helper
- 是否存在同名或相关应用
- 项目属于应用本体、缓存、系统缓存、残留还是日志

输出三种结果：

| 建议 | 含义 |
|---|---|
| 建议清理 | 通常是可由系统或应用重新生成的缓存、历史日志或孤立诊断文件 |
| 建议复核 | 无法确认归属，用户应先在 Finder 中确认 |
| 建议保留 | 应用本体、系统关键路径或仍可能被使用的数据 |

该分析器不读取文件内容，也不上传数据。它不是对系统安全性的绝对保证；用户仍可以逐项查看路径和原因。

### 3. 后台守护进程

`CleanSpaceDaemon` 是独立的 Swift executable target，由 macOS `launchd` 负责调度。它不是一个常驻轮询进程，而是每 24 小时被系统唤醒一次，执行完后退出。

默认安全策略：

- 只访问当前用户的 `~/Library/Caches`
- 不访问 `/Library/Caches`
- 不访问 `/System`、`/private/var/db` 或 LaunchDaemon
- 跳过符号链接
- 跳过若干系统服务缓存，例如 CloudKit、URLSession、IconServices 等
- 只处理修改时间超过 **14 天** 的一级缓存目录
- 单次最多处理 **80** 项
- 使用 macOS 废纸篓机制，不直接永久删除
- 将每次执行写入 `~/Library/Logs/CleanSpace/daemon.jsonl`

后台守护进程默认是关闭的，必须由用户显式运行安装脚本后才会启用。

## 本地构建

### 环境要求

- macOS 13 或更高
- Xcode 15 或更高（推荐 Xcode 16）
- Swift 5.9 或更高
- Apple Silicon Mac 推荐使用 arm64 构建

检查工具链：

```bash
swift --version
xcodebuild -version
```

### 使用 Swift Package Manager 构建

```bash
cd MacCleanUp
swift build -c release
```

构建两个可执行文件：

```text
.build/arm64-apple-macosx/release/MacCleanUp
.build/arm64-apple-macosx/release/CleanSpaceDaemon
```

在 Intel Mac 上，路径中的架构目录可能是 `x86_64-apple-macosx`。

### 使用 Xcode 构建

1. 用 Xcode 打开 `Package.swift`。
2. 选择 `MacCleanUp` 作为主应用 scheme。
3. 选择 My Mac 作为运行目标。
4. 运行或 Archive。
5. 如需发布，配置 Apple Developer Team、Signing Certificate 和 Hardened Runtime。
6. `CleanSpaceDaemon` 是同一个 package 中的第二个 executable target，可以单独构建。

### 直接使用 Xcode 工具链类型检查

```bash
cd MacCleanUp
SDK=$(xcrun --show-sdk-path --sdk macosx)
xcrun swiftc -typecheck \
  -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  Sources/CleanSpaceDaemon/main.swift

xcrun swiftc -typecheck -parse-as-library \
  -sdk "$SDK" \
  -target arm64-apple-macos13.0 \
  Sources/MacCleanUpApp/App.swift
```

## 安装后台自动清理

安装脚本会完成以下操作：

1. 构建 `CleanSpaceDaemon`
2. 安装到 `~/Library/Application Support/CleanSpace/bin/`
3. 创建默认配置 `daemon.json`
4. 生成 `~/Library/LaunchAgents/com.cleanspace.daemon.plist`
5. 使用 `launchctl bootstrap gui/<uid>` 注册当前用户的 LaunchAgent

执行：

```bash
cd MacCleanUp
./Scripts/install-daemon.sh
```

默认调度：每 24 小时一次。默认配置：

```json
{
  "enabled": true,
  "minimumAgeDays": 14,
  "maximumItemsPerRun": 80
}
```

### 先进行 dry-run

安装前可以只分析、不移动任何文件：

```bash
.build/arm64-apple-macosx/release/CleanSpaceDaemon --run --dry-run
```

查看守护进程状态：

```bash
.build/arm64-apple-macosx/release/CleanSpaceDaemon --status
launchctl print gui/$(id -u)/com.cleanspace.daemon
```

查看运行报告：

```bash
cat "$HOME/Library/Logs/CleanSpace/daemon.jsonl"
```

### 卸载或停用后台守护进程

```bash
cd MacCleanUp
./Scripts/uninstall-daemon.sh
```

该脚本只停用 LaunchAgent 并删除 plist；配置和日志会保留，方便审计和恢复。

## 手动修改后台策略

编辑：

```text
~/Library/Application Support/CleanSpace/daemon.json
```

修改后重新加载 LaunchAgent：

```bash
launchctl kickstart -k gui/$(id -u)/com.cleanspace.daemon
```

建议不要将 `minimumAgeDays` 设置为小于 7，也不要把 `maximumItemsPerRun` 设置得过大。守护进程只处理一级缓存目录，避免递归清理应用仍在使用的内部文件。

## launchd 配置

模板文件位于：

```text
Resources/com.cleanspace.daemon.plist.template
```

关键字段：

- `Label`: `com.cleanspace.daemon`
- `ProgramArguments`: 守护进程路径和 `--run`
- `StartInterval`: `86400` 秒，即 24 小时
- `RunAtLoad`: `false`，注册时不立即执行
- `ProcessType`: `Background`
- `StandardOutPath` / `StandardErrorPath`: launchd 标准输出和错误日志

## 安全与隐私

- 清理操作默认移到废纸篓，而不是直接 unlink。
- 后台守护进程不需要管理员权限，不会尝试提权。
- 后台守护进程只处理当前用户缓存，不清理其他用户数据。
- 不上传文件内容、文件名列表或日志内容。
- 若文件权限、路径或时间属性无法安全确认，则跳过。
- 守护进程的日志采用 JSONL，便于排查每次运行的扫描数量、跳过数量和估算释放空间。

## 项目文件

```text
Package.swift
Sources/MacCleanUpApp/App.swift
Sources/MacCleanUpApp/cleanspace-icon-rounded.png
Sources/CleanSpaceDaemon/main.swift
Resources/com.cleanspace.daemon.plist.template
Scripts/install-daemon.sh
Scripts/uninstall-daemon.sh
```

## 许可证与发布建议

当前工程是开发原型。正式发布前建议：

- 使用 Developer ID 对 App 和 daemon 签名
- 开启 Hardened Runtime
- 使用 notarization 公证
- 在干净用户账户中测试安装、升级、卸载和废纸篓恢复
- 对不同 macOS 版本的 `launchctl bootstrap` 行为进行回归测试
- 为后台设置增加图形化开关和最近一次运行报告展示

## 安装应用

推荐使用 `outputs/CleanSpace-1.1.0.dmg`：双击打开后，将 CleanSpace 拖入 **Applications（应用程序）** 文件夹即可完成安装。首次打开应用不会自动扫描，必须点击 **快速扫描** 或 **深度扫描** 后才会开始工作。
