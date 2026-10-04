import SwiftUI
import AppKit
import Foundation

// MARK: - Brand & design system

private let brandBlue = Color(red: 0.19, green: 0.43, blue: 0.98)
private let brandCyan = Color(red: 0.15, green: 0.78, blue: 0.95)
private let ink = Color(red: 0.08, green: 0.10, blue: 0.16)

struct BrandIcon: View {
    var size: CGFloat = 56
    var body: some View {
        Group {
            #if SWIFT_PACKAGE
            if let image = NSImage(contentsOf: Bundle.module.url(forResource: "cleanspace-icon-rounded", withExtension: "png")!) { Image(nsImage: image).resizable() } else { fallback }
            #else
            if let path = Bundle.main.path(forResource: "cleanspace-icon-rounded", ofType: "png"), let image = NSImage(contentsOfFile: path) { Image(nsImage: image).resizable() } else { fallback }
            #endif
        }.aspectRatio(contentMode: .fit).frame(width: size, height: size)
    }
    private var fallback: some View { Image(systemName: "sparkles.rectangle.stack.fill").resizable().scaledToFit().foregroundStyle(brandBlue) }
}

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View { content.padding(padding).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.20), lineWidth: 1)).shadow(color: .black.opacity(0.08), radius: 14, y: 6) }
}

// MARK: - Models

enum ScanCategory: String, CaseIterable, Identifiable {
    case appCache = "应用缓存", appSpace = "应用空间", systemCache = "系统缓存", leftovers = "卸载残留", deepLogs = "系统日志"
    var id: String { rawValue }
    var icon: String { switch self { case .appCache: "shippingbox.fill"; case .appSpace: "square.stack.3d.up.fill"; case .systemCache: "gearshape.2.fill"; case .leftovers: "arrow.triangle.2.circlepath"; case .deepLogs: "waveform.path.ecg" } }
    var tint: Color { switch self { case .appCache: .blue; case .appSpace: .purple; case .systemCache: .orange; case .leftovers: .pink; case .deepLogs: .teal } }
}

enum SafetyLevel: String, Codable { case safe = "建议清理", review = "建议复核", protect = "建议保留" }
struct AIAssessment: Hashable { let level: SafetyLevel; let confidence: Int; let reason: String }
struct CleanupItem: Identifiable, Hashable {
    let id = UUID(); let name: String; let path: URL; let size: Int64; let category: ScanCategory; let owner: String?; let assessment: AIAssessment?
    var isSelected = false
    var displaySize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}
struct InstalledApp: Identifiable, Hashable { let id = UUID(); let name: String; let url: URL; let size: Int64; let version: String; var displaySize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) } }

// MARK: - Conservative local AI-assisted analysis

struct AIResidueAnalyzer {
    // 本地保守模型：结合路径语义、文件类型、所属应用是否存在与系统保护路径进行评分；不上传文件内容。
    static func assess(path: URL, category: ScanCategory, knownApps: Set<String>) -> AIAssessment {
        let p = path.path.lowercased(); let name = path.lastPathComponent.lowercased()
        if p.contains("/system/") || p.contains("/private/var/db/") || p.contains("/library/launchdaemons") { return AIAssessment(level: .protect, confidence: 99, reason: "系统关键路径，AI 安全策略禁止清理") }
        if category == .deepLogs { return AIAssessment(level: .safe, confidence: 92, reason: "历史日志可由系统重新生成，不影响应用运行") }
        if category == .systemCache { return AIAssessment(level: name.contains("font") ? .review : .safe, confidence: name.contains("font") ? 68 : 88, reason: name.contains("font") ? "字体缓存可能影响首次渲染，建议复核" : "系统可自动重建的缓存") }
        if category == .appSpace { return AIAssessment(level: .protect, confidence: 98, reason: "应用本体，不作为清理建议") }
        let known = knownApps.contains { name.contains($0) || $0.contains(name.replacingOccurrences(of: ".plist", with: "")) }
        if known { return AIAssessment(level: .protect, confidence: 94, reason: "仍有对应应用存在，保留其运行所需数据") }
        if name.contains("crash") || name.contains("diagnostic") || name.hasSuffix(".log") || name.hasSuffix(".plist") { return AIAssessment(level: .safe, confidence: 81, reason: "AI 判断为孤立诊断或配置残留，可移入废纸篓") }
        return AIAssessment(level: .review, confidence: 59, reason: "无法确认所属应用，建议在 Finder 中复核")
    }
}

// MARK: - Scanner

@MainActor final class CleanupStore: ObservableObject {
    @Published var items: [CleanupItem] = []; @Published var apps: [InstalledApp] = []; @Published var isScanning = false; @Published var isDeepScanning = false; @Published var progress = 0.0; @Published var lastScan: Date?; @Published var message: String?; @Published var selectedCategory: ScanCategory? = nil
    private let fm = FileManager.default; private var task: Task<Void, Never>?; private var home: URL { fm.homeDirectoryForCurrentUser }
    var selectedItems: [CleanupItem] { items.filter(\.isSelected) }; var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }; var totalSize: Int64 { items.filter { $0.category != .appSpace }.reduce(0) { $0 + $1.size } }
    var knownAppNames: Set<String> { Set(apps.map { $0.name.lowercased() }) }
    func categorySize(_ c: ScanCategory) -> Int64 { items.filter { $0.category == c }.reduce(0) { $0 + $1.size } }
    func scan() { guard !isScanning && !isDeepScanning else { message = "已有扫描正在进行，请稍候"; return }; task?.cancel(); isScanning = true; progress = 0; message = nil; items.removeAll(); apps.removeAll(); task = Task { [weak self] in guard let self else { return }; let a = await scanApplications(); await MainActor.run { self.apps = a; self.progress = 0.22 }; let c = await scanDirectory(home.appendingPathComponent("Library/Caches"), category: .appCache, apps: a); await MainActor.run { self.items += c; self.progress = 0.50 }; let s = await scanDirectory(URL(fileURLWithPath: "/Library/Caches"), category: .systemCache, apps: a); await MainActor.run { self.items += s; self.progress = 0.70 }; let r = await scanLeftovers(a); await MainActor.run { self.items += r; self.progress = 1; self.lastScan = Date(); self.isScanning = false; self.message = "快速扫描完成：发现 \(self.items.count) 个项目" } } }
    func deepScan() { guard !isDeepScanning && !isScanning else { message = "已有扫描正在进行，请稍候"; return }; isDeepScanning = true; message = nil; Task { [weak self] in guard let self else { return }; let logs = await scanLogs(); await MainActor.run { self.items.removeAll { $0.category == .deepLogs }; self.items += logs; self.isDeepScanning = false; self.lastScan = Date(); self.message = "深度扫描完成：发现 \(logs.count) 个日志项目" } } }
    private func scanApplications() async -> [InstalledApp] { var out: [InstalledApp] = []; for root in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] { guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }; for u in urls where u.pathExtension == "app" { let plist = u.appendingPathComponent("Contents/Info.plist"); let version = (NSDictionary(contentsOf: plist)?["CFBundleShortVersionString"] as? String) ?? "未知"; out.append(InstalledApp(name: u.deletingPathExtension().lastPathComponent, url: u, size: folderSize(u), version: version)) } }; return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    private func scanDirectory(_ root: URL, category: ScanCategory, apps: [InstalledApp]) async -> [CleanupItem] { guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: []) else { return [] }; let names = Set(apps.map { $0.name.lowercased() }); return urls.compactMap { u in let size = folderSize(u); guard size > 0 else { return nil }; return CleanupItem(name: u.lastPathComponent, path: u, size: size, category: category, owner: nil, assessment: AIResidueAnalyzer.assess(path: u, category: category, knownApps: names)) }.sorted { $0.size > $1.size } }
    private func scanLeftovers(_ apps: [InstalledApp]) async -> [CleanupItem] { let roots = [home.appendingPathComponent("Library/Application Support"), home.appendingPathComponent("Library/Preferences"), home.appendingPathComponent("Library/LaunchAgents"), home.appendingPathComponent("Library/Containers")]; var out: [CleanupItem] = []; let names = Set(apps.map { $0.name.lowercased() }); for root in roots { guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }; for u in urls { let n = u.lastPathComponent.lowercased(); guard n.contains("helper") || n.contains("updater") || n.contains("crash") || n.hasSuffix(".plist") else { continue }; let a = AIResidueAnalyzer.assess(path: u, category: .leftovers, knownApps: names); if a.level != .protect { out.append(CleanupItem(name: u.lastPathComponent, path: u, size: folderSize(u), category: .leftovers, owner: "AI 辅助分析", assessment: a)) } } }; return out.filter { $0.size > 0 }.sorted { $0.size > $1.size } }
    private func scanLogs() async -> [CleanupItem] { let roots = [home.appendingPathComponent("Library/Logs"), URL(fileURLWithPath: "/Library/Logs"), home.appendingPathComponent("Library/DiagnosticReports"), URL(fileURLWithPath: "/Library/DiagnosticReports")]; var out: [CleanupItem] = []; for root in roots { guard let urls = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }; for u in urls { let size = folderSize(u); if size > 0 { out.append(CleanupItem(name: u.lastPathComponent, path: u, size: size, category: .deepLogs, owner: "深度日志扫描", assessment: AIResidueAnalyzer.assess(path: u, category: .deepLogs, knownApps: knownAppNames)) ) } } }; return out.sorted { $0.size > $1.size } }
    private func folderSize(_ u: URL) -> Int64 { if let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]), v.isDirectory == false { return Int64(v.fileSize ?? 0) }; guard let e = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }; var total: Int64 = 0; for case let child as URL in e { if let v = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), v.isRegularFile == true { total += Int64(v.fileSize ?? 0) } }; return total }
    func toggle(_ item: CleanupItem) { if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].isSelected.toggle() } }; func selectSafe() { for i in items.indices { items[i].isSelected = items[i].assessment?.level == .safe } }; func clearSelection() { for i in items.indices { items[i].isSelected = false } }
    func cleanSelected() { let t = selectedItems; guard !t.isEmpty else { message = "请先选择要清理的项目"; return }; for i in t { NSWorkspace.shared.recycle([i.path]) }; items.removeAll { t.contains($0) }; message = "已将 \(t.count) 项安全移到废纸篓" }
    func launch(_ app: InstalledApp) { NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) }; func reveal(_ app: InstalledApp) { NSWorkspace.shared.selectFile(app.url.path, inFileViewerRootedAtPath: "") }; func reveal(_ item: CleanupItem) { NSWorkspace.shared.selectFile(item.path.path, inFileViewerRootedAtPath: "") }; func uninstall(_ app: InstalledApp) { NSWorkspace.shared.recycle([app.url]); apps.removeAll { $0.id == app.id }; message = "已将 \(app.name) 移到废纸篓" }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @Binding var isPresented: Bool; @State private var step = 0
    private let pages = [("把空间还给你的 Mac", "CleanSpace 用清晰、保守的方式发现缓存、日志和卸载残留。"), ("AI 辅助判断，先保护再清理", "本地安全模型会解释每个项目的建议：建议清理、建议复核或建议保留。"), ("所有操作可恢复", "清理项目只会移动到废纸篓；你可以随时在 Finder 中恢复。")]
    var body: some View { ZStack { LinearGradient(colors: [Color(red: 0.04, green: 0.07, blue: 0.18), Color(red: 0.10, green: 0.20, blue: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea(); VStack(spacing: 28) { BrandIcon(size: 112).shadow(color: brandCyan.opacity(0.45), radius: 26); Text(pages[step].0).font(.system(size: 30, weight: .bold, design: .rounded)).foregroundStyle(.white); Text(pages[step].1).font(.title3).multilineTextAlignment(.center).foregroundStyle(.white.opacity(0.78)).frame(maxWidth: 420); HStack(spacing: 8) { ForEach(0..<pages.count, id: \.self) { i in Capsule().fill(i == step ? brandCyan : .white.opacity(0.25)).frame(width: i == step ? 24 : 8, height: 8) } }; Button(step == pages.count - 1 ? "开始使用 CleanSpace" : "继续") { if step == pages.count - 1 { isPresented = false } else { withAnimation { step += 1 } } }.buttonStyle(.borderedProminent).tint(brandCyan).controlSize(.large) }.padding(48) }.frame(width: 620, height: 520) }
}

// MARK: - Main UI

struct ContentView: View {
    @StateObject private var store = CleanupStore(); @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false; @AppStorage("appearanceMode") private var appearanceMode = "system"; @State private var tab = "概览"; @State private var showUninstall = false; @State private var appToRemove: InstalledApp?
    private let tabs = [("概览", "sparkles.rectangle.stack"), ("智能清理", "wand.and.stars"), ("深度扫描", "waveform.path.ecg"), ("应用管理", "square.grid.2x2"), ("设置", "slider.horizontal.3")]
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if tab == "概览" { overview }
                else if tab == "智能清理" { cleanup }
                else if tab == "深度扫描" { logs }
                else if tab == "应用管理" { applications }
                else { settings }
            }
            .background(
                ZStack {
                    LinearGradient(colors: [Color.blue.opacity(0.08), Color.clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Color(nsColor: .windowBackgroundColor).opacity(0.78)
                }
                .ignoresSafeArea()
            )
        }
        .frame(minWidth: 1040, minHeight: 700)
        .sheet(isPresented: Binding(get: { !hasSeenOnboarding }, set: { if !$0 { hasSeenOnboarding = true } })) {
            OnboardingView(isPresented: Binding(get: { !hasSeenOnboarding }, set: { hasSeenOnboarding = !$0 }))
        }
        .alert("确认卸载应用？", isPresented: $showUninstall, presenting: appToRemove) { app in
            Button("移到废纸篓", role: .destructive) { store.uninstall(app) }
            Button("取消", role: .cancel) {}
        } message: { app in
            Text("将卸载 \(app.name)。应用会先移动到废纸篓，可从废纸篓恢复。")
        }
        .preferredColorScheme(appearanceMode == "dark" ? .dark : appearanceMode == "light" ? .light : nil)
    }
    private var sidebar: some View { VStack(alignment: .leading, spacing: 8) { HStack(spacing: 10) { BrandIcon(size: 38); VStack(alignment: .leading) { Text("CleanSpace").font(.headline); Text("智能空间管家").font(.caption2).foregroundStyle(.secondary) } }.padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 16); ForEach(tabs, id: \.0) { item in Button { withAnimation(.easeOut(duration: 0.18)) { tab = item.0 } } label: { Label(item.0, systemImage: item.1).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(.horizontal, 16).padding(.vertical, 10).background(tab == item.0 ? brandBlue.opacity(0.14) : .clear).clipShape(RoundedRectangle(cornerRadius: 10)).foregroundStyle(tab == item.0 ? brandBlue : .primary) }; Spacer(); GlassCard(padding: 12) { HStack { Image(systemName: "lock.shield.fill").foregroundStyle(.green); VStack(alignment: .leading) { Text("本地优先").font(.caption.weight(.semibold)); Text("不上传文件内容").font(.caption2).foregroundStyle(.secondary) } } }.padding(12); Text("CleanSpace 1.1.0").font(.caption2).foregroundStyle(.tertiary).padding(18) }.frame(minWidth: 210).background(.regularMaterial) }
    private var toolbar: some View { HStack { VStack(alignment: .leading, spacing: 3) { Text(tab).font(.system(size: 23, weight: .bold, design: .rounded)); Text(store.lastScan.map { "上次扫描 \($0, style: .relative)" } ?? "准备好开始扫描").font(.caption).foregroundStyle(.secondary) }; Spacer(); if let message = store.message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 220, alignment: .trailing) }; if store.isScanning { ProgressView(value: store.progress).frame(width: 130) }; Button { store.scan() } label: { Label(store.isScanning ? "扫描中…" : "快速扫描", systemImage: store.isScanning ? "hourglass" : "arrow.clockwise") }.buttonStyle(.bordered).disabled(store.isScanning || store.isDeepScanning); Button { store.deepScan() } label: { Label(store.isDeepScanning ? "扫描中…" : "深度扫描", systemImage: "waveform.path.ecg") }.buttonStyle(.borderedProminent).tint(brandBlue).disabled(store.isScanning || store.isDeepScanning) }.padding(.horizontal, 28).padding(.vertical, 18).background(.thinMaterial) }
    private var overview: some View { ScrollView { VStack(alignment: .leading, spacing: 22) { ZStack(alignment: .leading) { RoundedRectangle(cornerRadius: 24).fill(LinearGradient(colors: [brandBlue, Color(red: 0.10, green: 0.72, blue: 0.86)], startPoint: .topLeading, endPoint: .bottomTrailing)); HStack { VStack(alignment: .leading, spacing: 12) { Text("让 Mac 轻盈一点").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.white); Text("已发现可安全复核的空间\n所有清理都可从废纸篓恢复").foregroundStyle(.white.opacity(0.78)); HStack(spacing: 10) { Button { store.scan() } label: { Label("快速扫描", systemImage: "bolt.fill") }.buttonStyle(.borderedProminent).tint(.white).foregroundStyle(brandBlue); Button { store.deepScan() } label: { Label("深度扫描", systemImage: "waveform.path.ecg") }.buttonStyle(.bordered).tint(.white) } }; Spacer(); Image(systemName: "sparkles").font(.system(size: 82)).foregroundStyle(.white.opacity(0.24)).padding(34) }.padding(28) }.frame(height: 190); HStack(spacing: 14) { metric("可清理空间", ByteCountFormatter.string(fromByteCount: store.totalSize, countStyle: .file), "externaldrive.fill", .blue); metric("应用数量", "\(store.apps.count)", "square.grid.2x2.fill", .purple); metric("AI 建议", "\(store.items.filter { $0.assessment?.level == .safe }.count)", "wand.and.stars", .teal) }; Text("扫描概览").font(.headline); LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) { ForEach(ScanCategory.allCases) { c in Button { tab = c == .deepLogs ? "深度扫描" : "智能清理"; store.selectedCategory = c } label: { HStack { Image(systemName: c.icon).font(.title3).foregroundStyle(c.tint); VStack(alignment: .leading) { Text(c.rawValue).font(.subheadline.weight(.semibold)); Text(ByteCountFormatter.string(fromByteCount: store.categorySize(c), countStyle: .file)).font(.caption).foregroundStyle(.secondary) }; Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }.padding(16).background(Color(nsColor: .controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius: 14)) }.buttonStyle(.plain) } }; GlassCard(padding: 14) { HStack { Image(systemName: "checkmark.shield.fill").foregroundStyle(.green); Text("CleanSpace 会优先保护系统目录、应用本体和仍在使用的数据。每个建议都附有原因和置信度。").font(.caption).foregroundStyle(.secondary) } } }.padding(28) } }
    private func metric(_ title: String, _ value: String, _ icon: String, _ color: Color) -> some View { GlassCard { VStack(alignment: .leading, spacing: 10) { Image(systemName: icon).foregroundStyle(color); Text(value).font(.title2.bold()); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading) } }
    private var cleanup: some View { VStack(spacing: 0) { HStack { Picker("分类", selection: Binding(get: { store.selectedCategory }, set: { store.selectedCategory = $0 })) { Text("全部").tag(ScanCategory?.none); ForEach(ScanCategory.allCases.filter { $0 != .deepLogs }) { Text($0.rawValue).tag(Optional($0)) } }.pickerStyle(.segmented).frame(maxWidth: 520); Spacer(); Button("只选建议清理") { store.selectSafe() }.buttonStyle(.bordered); Button("清除选择") { store.clearSelection() }.buttonStyle(.bordered) }.padding(.horizontal, 28).padding(.vertical, 16); Divider(); List(filteredItems) { item in itemRow(item) }.listStyle(.inset).scrollContentBackground(.hidden); bottomAction }.overlay { if store.items.isEmpty { VStack(spacing: 12) { Image(systemName: "sparkles.rectangle.stack").font(.largeTitle).foregroundStyle(brandBlue); Text("还没有扫描结果").font(.headline); Text("选择快速扫描开始检测缓存和卸载残留").font(.caption).foregroundStyle(.secondary); Button { store.scan() } label: { Label("开始快速扫描", systemImage: "bolt.fill") }.buttonStyle(.borderedProminent).tint(brandBlue).disabled(store.isScanning || store.isDeepScanning) } } } }
    private var filteredItems: [CleanupItem] { let base = store.items.filter { $0.category != .deepLogs }; return store.selectedCategory == nil ? base : base.filter { $0.category == store.selectedCategory } }
    private func itemRow(_ item: CleanupItem) -> some View { HStack(spacing: 12) { Button { store.toggle(item) } label: { Image(systemName: item.isSelected ? "checkmark.circle.fill" : "circle").foregroundStyle(item.isSelected ? brandBlue : .secondary) }.buttonStyle(.plain); Image(systemName: item.category.icon).foregroundStyle(item.category.tint); VStack(alignment: .leading, spacing: 3) { Text(item.name).lineLimit(1); Text(item.assessment?.reason ?? item.path.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }; Spacer(); if let a = item.assessment { if a.level == .review { Button { store.reveal(item) } label: { Label("Finder", systemImage: "folder") }.buttonStyle(.bordered).controlSize(.small) }; Label("\(a.confidence)%", systemImage: a.level == .safe ? "checkmark.seal.fill" : a.level == .protect ? "lock.fill" : "exclamationmark.triangle.fill").font(.caption).foregroundStyle(a.level == .safe ? .green : a.level == .protect ? .secondary : .orange) }; Text(item.displaySize).font(.callout.monospacedDigit()) }.padding(.vertical, 5) }
    private var bottomAction: some View { HStack { Text("已选择 \(store.selectedItems.count) 项 · \(ByteCountFormatter.string(fromByteCount: store.selectedSize, countStyle: .file))").font(.callout).foregroundStyle(.secondary); Spacer(); Button { store.cleanSelected() } label: { Label("安全移到废纸篓", systemImage: "trash") }.buttonStyle(.borderedProminent).tint(brandBlue).disabled(store.selectedItems.isEmpty || store.isScanning || store.isDeepScanning) }.padding(18).background(.thinMaterial) }
    private var logs: some View { VStack(alignment: .leading, spacing: 0) { HStack { VStack(alignment: .leading) { Text("深度扫描系统日志").font(.headline); Text("扫描用户日志、诊断报告和系统日志目录；AI 只建议清理可再生成的历史记录。").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { store.deepScan() } label: { Label(store.isDeepScanning ? "扫描中…" : "开始深度扫描", systemImage: "waveform.path.ecg") }.buttonStyle(.borderedProminent).tint(.teal).disabled(store.isScanning || store.isDeepScanning) }.padding(28); Divider(); List(store.items.filter { $0.category == .deepLogs }) { item in itemRow(item) }.listStyle(.inset).scrollContentBackground(.hidden); bottomAction }.overlay { if store.items.filter({ $0.category == .deepLogs }).isEmpty { VStack(spacing: 12) { Image(systemName: "waveform.path.ecg").font(.largeTitle).foregroundStyle(.teal); Text("还没有深度扫描结果").font(.headline); Text("深度扫描会检查日志、诊断报告和系统记录").font(.caption).foregroundStyle(.secondary); Button { store.deepScan() } label: { Label("开始深度扫描", systemImage: "waveform.path.ecg") }.buttonStyle(.borderedProminent).tint(.teal).disabled(store.isScanning || store.isDeepScanning) } } } }
    private var applications: some View { List(store.apps) { app in HStack { Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 44, height: 44); VStack(alignment: .leading) { Text(app.name).font(.subheadline.weight(.semibold)); Text("版本 \(app.version) · \(app.displaySize)").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("打开") { store.launch(app) }.buttonStyle(.bordered); Button { store.reveal(app) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.bordered); Button { appToRemove = app; showUninstall = true } label: { Image(systemName: "trash") }.buttonStyle(.bordered).tint(.red) }.padding(.vertical, 5) }.listStyle(.inset).scrollContentBackground(.hidden).padding(.horizontal, 12) }
    private var settings: some View { Form { Section("外观") { Picker("主题", selection: $appearanceMode) { Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark") }.pickerStyle(.segmented) }; Section("AI 与隐私") { Label("AI 辅助判定在本地运行，不读取或上传文件内容。", systemImage: "lock.shield"); Label("所有清理动作先移动到废纸篓。", systemImage: "trash") }; Section("后台自动清理") { Label("基于 macOS launchd，每 24 小时唤醒一次。", systemImage: "clock.arrow.circlepath"); Text("默认只处理当前用户中超过 14 天的可重建缓存，每次最多 80 项；不会访问系统关键目录。请运行 Scripts/install-daemon.sh 启用。" ).font(.caption).foregroundStyle(.secondary) }; Section("关于 CleanSpace") { LabeledContent("版本号", value: "1.1.0"); LabeledContent("系统要求", value: "macOS 13 Ventura 或更高"); Button("重新查看 Onboarding") { hasSeenOnboarding = false } }; Section("卸载本应用") { Text("将 CleanSpace 移到废纸篓，不会删除扫描到的用户文件。").font(.caption).foregroundStyle(.secondary); Button("卸载 CleanSpace") { NSWorkspace.shared.recycle([Bundle.main.bundleURL]) }.tint(.red) } }.formStyle(.grouped).padding(28) }
}

@main struct MacCleanUpApp: App { var body: some Scene { WindowGroup { ContentView() }.windowStyle(.hiddenTitleBar).commands { CommandGroup(replacing: .appInfo) { Button("关于 CleanSpace") { NSApplication.shared.orderFrontStandardAboutPanel(nil) } } } } }
