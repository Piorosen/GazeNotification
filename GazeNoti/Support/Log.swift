import Foundation
import os

/// os.Logger + ~/Library/Logs/GazeNoti/gazenoti.log 에 동시에 기록.
/// 파일 로그는 권한/AX 구조 문제를 사후에 진단하기 위한 용도라 이벤트성 메시지만 남긴다.
enum Log {
    private static let logger = Logger(subsystem: "party.udon.GazeNoti", category: "app")
    private static let queue = DispatchQueue(label: "gazenoti.log")
    private static let maxFileSize = 1_000_000

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GazeNoti", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("gazenoti.log") }

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        append("INFO  \(message)")
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        append("ERROR \(message)")
    }

    /// 별도 파일로 덤프 (AX 트리 등). 저장된 경로를 반환.
    @discardableResult
    static func writeDump(named name: String, contents: String) -> URL? {
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Self.error("dump 저장 실패: \(error.localizedDescription)")
            return nil
        }
    }

    private static func append(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        let data = Data("\(stamp) \(line)\n".utf8)
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size]) as? Int, size > maxFileSize {
                try? fm.removeItem(at: fileURL)
            }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
