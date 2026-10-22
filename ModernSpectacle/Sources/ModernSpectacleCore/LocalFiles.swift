import Foundation

/// The app's own files (history, saved layouts, the status log). They hold window titles, so the folder is readable
/// only by the user (0700) and each file too (0600).
public enum LocalFiles {
    public static func write(_ data: Data, to url: URL) throws {
        try prepareFolder(of: url)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Appends to a log file, starting it over once it passes `limit` bytes.
    public static func append(_ data: Data, to url: URL, limit: Int = 512_000) {
        guard (try? prepareFolder(of: url)) != nil else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size + data.count > limit || !FileManager.default.fileExists(atPath: url.path) {
            try? write(data, to: url)
            return
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) // files from older versions
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    private static func prepareFolder(of url: URL) throws {
        let folder = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
    }
}
