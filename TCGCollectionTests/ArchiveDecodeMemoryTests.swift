import Darwin
import Foundation
import Testing
@testable import TCGCollection2

/// Phase 5B memory check: does a decode of a daily archive through `ArchiveGate` keep memory after it ends? The same
/// archive is decoded many times in one process, each time from a fresh copy into a fresh `price-days` folder, and the
/// process's current footprint (`phys_footprint`, not the lifetime peak `ru_maxrss`) is read before and after each
/// decode. Runs only with `TCG_MEMCHECK_ARCHIVE=<path of a copy of a real archive>` (forwarded by xcodebuild as
/// `TEST_RUNNER_TCG_MEMCHECK_ARCHIVE`); the archive at that path is copied, never decoded or deleted itself.
struct ArchiveDecodeMemoryTests {
    static let archivePath = ProcessInfo.processInfo.environment["TCG_MEMCHECK_ARCHIVE"]

    /// The process's current physical footprint in MB.
    static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1_048_576
    }

    @Test(.enabled(if: archivePath != nil), .timeLimit(.minutes(10)))
    func repeatedDecodesKeepNoMemory() async throws {
        let source = URL(fileURLWithPath: Self.archivePath!)
        let name = source.lastPathComponent
        let day = try #require(name.wholeMatch(of: /prices-(\d{4}-\d{2}-\d{2})\.ppmd\.7z/)).1
        let iterations = Int(ProcessInfo.processInfo.environment["TCG_MEMCHECK_ITERATIONS"] ?? "") ?? 15
        var lines = ["iteration\tbefore\tafter decode\tafter drain"]
        var drained: [Double] = []
        for i in 1...iterations {
            let root = tempRoot()
            let paths = AppPaths(root: root)
            defer { try? FileManager.default.removeItem(at: root) }
            try FileManager.default.createDirectory(at: paths.archives, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.priceDays, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: paths.archives.appending(path: name))
            let before = Self.footprint()
            let gate = ArchiveGate(paths: paths)
            let decoded = try await gate.decodeDay(day: String(day), games: Games.all)
            #expect(decoded.wroteDayFile)
            let after = Self.footprint()
            _ = decoded.tables.count
            try await Task.sleep(for: .milliseconds(300))
            let rest = autoreleasepool { Self.footprint() }
            drained.append(rest)
            lines.append(String(format: "%d\t%.1f\t%.1f\t%.1f", i, before, after, rest))
        }
        let table = lines.joined(separator: "\n")
        print("memcheck\n" + table)
        if let out = ProcessInfo.processInfo.environment["TCG_MEMCHECK_OUT"] {
            try? table.write(toFile: out, atomically: true, encoding: .utf8)
        }
        // Retention: the footprint after the last decode is not more than 50 MB over the one after the second.
        if drained.count >= 3 {
            #expect(drained.last! - drained[1] < 50, "footprint grew \(drained.last! - drained[1]) MB over \(iterations - 2) decodes")
        }
    }
}
