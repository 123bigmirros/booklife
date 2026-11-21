import Foundation
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// Makes an in-memory reader copy; the original Apple Books package is never changed.
public enum EPUBArchive {
    public static func coverData(at url: URL) -> Data? {
        guard (try? url.resourceValues(forKeys:[.isDirectoryKey]).isDirectory) == true,
              let files = FileManager.default.enumerator(at:url,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey]) else { return nil }
        let root = url.resolvingSymlinksInPath().path + "/"
        var count = 0
        for case let file as URL in files {
            count += 1; if count > 15000 { break }
            let name = file.lastPathComponent.lowercased()
            guard name == "itunesartwork" || (name.contains("cover") && ["jpg","jpeg","png"].contains(file.pathExtension.lowercased())),
                  file.resolvingSymlinksInPath().path.hasPrefix(root),
                  let values = try? file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]), values.isRegularFile == true,
                  let size = values.fileSize, size <= 4 * 1024 * 1024, let data = try? Data(contentsOf:file) else { continue }
            return data
        }
        return nil
    }
    public static func data(at url: URL) throws -> Data {
        guard (try url.resourceValues(forKeys:[.isDirectoryKey])).isDirectory == true else { return try BookImportFile.read(url) }
        guard FileManager.default.fileExists(atPath:url.appendingPathComponent("META-INF/container.xml").path) else { throw TextError("书籍未下载完整，请先在 Apple Books 下载") }
        guard let files = FileManager.default.enumerator(at:url,includingPropertiesForKeys:[.isSymbolicLinkKey,.fileSizeKey,.isRegularFileKey]) else { throw TextError("无法读取书籍目录") }
        var total = 0, count = 0
        for case let file as URL in files {
            count += 1
            let values = try file.resourceValues(forKeys:[.isSymbolicLinkKey,.fileSizeKey,.isRegularFileKey])
            guard values.isSymbolicLink != true else { throw TextError("书籍资源包含不支持的符号链接") }
            if values.isRegularFile == true { total += values.fileSize ?? 0 }
            guard count <= 15000, total <= 50 * 1024 * 1024 else { throw TextError("书籍资源过大，暂时无法打开") }
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("BookSlide-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let archive = temporary.appendingPathComponent("reader.epub")
        let zip = Process(); zip.executableURL = URL(fileURLWithPath:"/usr/bin/zip")
        zip.currentDirectoryURL = url; zip.arguments = ["-q","-r",archive.path,"."]
        zip.standardInput = FileHandle.nullDevice; zip.standardOutput = FileHandle.nullDevice; zip.standardError = FileHandle.nullDevice
        try zip.run(); zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw TextError("无法准备书籍，请确认书籍已完整下载") }
        return try Data(contentsOf:archive)
    }
}
