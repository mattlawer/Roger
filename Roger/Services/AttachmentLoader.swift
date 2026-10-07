import Foundation
import UniformTypeIdentifiers

enum AttachmentLoader {
    static let maxTextChars = 120_000
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff"]

    enum Loaded {
        case attachment(Attachment)
        case directory(URL)
        case unsupported(String)
    }

    /// A file URL Quick Look can show for an attachment: the original file when it still
    /// exists, otherwise a copy written from the stored image data or text.
    static func previewURL(for attachment: Attachment) -> URL? {
        if let p = attachment.path, FileManager.default.fileExists(atPath: p) { return URL(fileURLWithPath: p) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Roger/Previews/\(attachment.id.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(attachment.fileName.isEmpty ? "attachment" : attachment.fileName)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        if let b64 = attachment.imageBase64, let data = Data(base64Encoded: b64) {
            return (try? data.write(to: url)) != nil ? url : nil
        }
        if let text = attachment.text {
            return (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
        }
        return nil
    }

    static func load(_ url: URL) -> Loaded {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .unsupported("\(url.lastPathComponent) does not exist")
        }
        if isDir.boolValue { return .directory(url) }
        guard let data = try? Data(contentsOf: url) else { return .unsupported("Cannot read \(url.lastPathComponent)") }

        if imageExtensions.contains(url.pathExtension.lowercased()) {
            return .attachment(Attachment(fileName: url.lastPathComponent, path: url.path, imageBase64: data.base64EncodedString()))
        }
        if data.count > 5_000_000 { return .unsupported("\(url.lastPathComponent) is too large (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)))") }
        guard var text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return .unsupported("\(url.lastPathComponent) is not a text file")
        }
        if text.count > maxTextChars {
            text = String(text.prefix(maxTextChars)) + "\n… [truncated, \(text.count - maxTextChars) more characters]"
        }
        return .attachment(Attachment(fileName: url.lastPathComponent, path: url.path, text: text))
    }
}
