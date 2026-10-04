import Foundation

/// CleanSpace 的 launchd 后台守护进程。
/// 安全边界：只触碰当前用户 ~/Library/Caches 下的可重建缓存；
/// 不访问 /Library/Caches、系统目录、应用包或正在运行进程的数据。
struct DaemonSettings: Codable {
    var enabled: Bool = true
    var minimumAgeDays: Int = 14
    var maximumItemsPerRun: Int = 80
}

struct RunReport: Codable {
    let startedAt: Date
    let finishedAt: Date
    let scannedItems: Int
    let trashedItems: Int
    let reclaimedBytes: Int64
    let skippedItems: Int
    let dryRun: Bool
}

final class CleanSpaceDaemon {
    private let fm = FileManager.default
    private let calendar = Calendar.current
    private var home: URL { fm.homeDirectoryForCurrentUser }
    private var supportDirectory: URL { home.appendingPathComponent("Library/Application Support/CleanSpace", isDirectory: true) }
    private var logDirectory: URL { home.appendingPathComponent("Library/Logs/CleanSpace", isDirectory: true) }
    private var settingsURL: URL { supportDirectory.appendingPathComponent("daemon.json") }
    private var cacheRoot: URL { home.appendingPathComponent("Library/Caches", isDirectory: true) }

    func run(dryRun: Bool = false) -> Int32 {
        do {
            try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let settings = try loadSettings()
            guard settings.enabled else { log("disabled=true"); return 0 }
            let started = Date()
            let cutoff = calendar.date(byAdding: .day, value: -max(1, settings.minimumAgeDays), to: started) ?? started
            let children = try fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey, .totalFileSizeKey], options: [.skipsHiddenFiles])
            var scanned = 0, trashed = 0, skipped = 0
            var reclaimed: Int64 = 0
            for url in children {
                scanned += 1
                guard scanned <= settings.maximumItemsPerRun else { skipped += 1; continue }
                guard isSafeCacheCandidate(url), let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .totalFileSizeKey, .fileSizeKey]), let modified = values.contentModificationDate, modified < cutoff else { skipped += 1; continue }
                let size = Int64(values.totalFileSize ?? values.fileSize ?? 0)
                if dryRun { trashed += 1; reclaimed += size; continue }
                do { try fm.trashItem(at: url, resultingItemURL: nil); trashed += 1; reclaimed += size } catch { skipped += 1; log("skip path=\(url.path) error=\(error.localizedDescription)") }
            }
            let report = RunReport(startedAt: started, finishedAt: Date(), scannedItems: scanned, trashedItems: trashed, reclaimedBytes: reclaimed, skippedItems: skipped, dryRun: dryRun)
            try append(report)
            return 0
        } catch {
            log("fatal=\(error.localizedDescription)")
            return 1
        }
    }

    private func loadSettings() throws -> DaemonSettings {
        guard fm.fileExists(atPath: settingsURL.path) else { return DaemonSettings() }
        return try JSONDecoder().decode(DaemonSettings.self, from: Data(contentsOf: settingsURL))
    }

    private func isSafeCacheCandidate(_ url: URL) -> Bool {
        guard url.path.hasPrefix(cacheRoot.path + "/") else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { return false }
        let name = url.lastPathComponent.lowercased()
        let blocked = ["com.apple.screencapture", "com.apple.cloudkit", "com.apple.nsurlsessiond", "com.apple.iconservices", "com.apple.sharedfilelist"]
        return !blocked.contains(where: { name.contains($0) })
    }

    private func append(_ report: RunReport) throws {
        let data = try JSONEncoder().encode(report)
        var line = data; line.append(10)
        if fm.fileExists(atPath: logFile.path) { let handle = try FileHandle(forWritingTo: logFile); try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.close() } else { try line.write(to: logFile, options: .atomic) }
    }

    private var logFile: URL { logDirectory.appendingPathComponent("daemon.jsonl") }
    private func log(_ message: String) { do { try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true) } catch { return }; let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"; if let data = line.data(using: .utf8) { if fm.fileExists(atPath: logFile.path), let h = try? FileHandle(forWritingTo: logFile) { try? h.seekToEnd(); try? h.write(contentsOf: data); try? h.close() } else { try? data.write(to: logFile) } } }
}

func usage() { print("CleanSpaceDaemon --run [--dry-run] | --status | --help") }
let daemon = CleanSpaceDaemon()
switch CommandLine.arguments.dropFirst().first {
case "--run": exit(daemon.run(dryRun: CommandLine.arguments.contains("--dry-run")))
case "--status": print("CleanSpaceDaemon: ready; schedule is owned by launchd")
case "--help", nil: usage()
default: usage(); exit(2)
}
