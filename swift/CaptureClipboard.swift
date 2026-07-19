import Cocoa

/// One capture copied as several representations of the SAME pasteboard item.
/// Receivers choose their richest supported format; plain text always retains
/// the narration and durable local paths.
enum CaptureClipboard {
    struct Content {
        let plainText: String
        let html: Data?
        let rtfd: Data?
        let imageCount: Int
    }

    private struct ImageAttachment {
        let path: String
        let data: Data
        let image: NSImage
        let mimeType: String
    }

    static func makeContent(text: String, attachmentPaths: [String]) -> Content {
        let images = attachmentPaths.compactMap(loadAttachment)
        let pathLines = attachmentPaths.map { "[Image: \($0)]" }
        let plain = ([text] + pathLines)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !images.isEmpty else {
            return Content(plainText: plain, html: nil, rtfd: nil, imageCount: 0)
        }
        return Content(
            plainText: plain,
            html: makeHTML(text: text, images: images),
            rtfd: makeRTFD(text: text, images: images),
            imageCount: images.count)
    }

    @discardableResult
    static func copy(text: String, attachmentPaths: [String],
                     to pasteboard: NSPasteboard = .general) -> Content {
        let content = makeContent(text: text, attachmentPaths: attachmentPaths)
        let item = NSPasteboardItem()
        item.setString(content.plainText, forType: .string)
        if let html = content.html { item.setData(html, forType: .html) }
        if let rtfd = content.rtfd { item.setData(rtfd, forType: .rtfd) }
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        return content
    }

    private static func loadAttachment(_ path: String) -> ImageAttachment? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = NSImage(data: data) else { return nil }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        default: mime = "image/jpeg"
        }
        return ImageAttachment(path: path, data: data, image: image, mimeType: mime)
    }

    private static func makeHTML(text: String, images: [ImageAttachment]) -> Data {
        let body = escapeHTML(text).replacingOccurrences(of: "\n", with: "<br>")
        let imageHTML = images.map { item in
            let encoded = item.data.base64EncodedString()
            return "<figure style=\"margin:12px 0\"><img src=\"data:\(item.mimeType);base64,\(encoded)\" style=\"max-width:100%;height:auto\"><figcaption style=\"font-size:11px;color:#666\">\(escapeHTML(item.path))</figcaption></figure>"
        }.joined()
        return Data("<div>\(body)<br>\(imageHTML)</div>".utf8)
    }

    private static func makeRTFD(text: String, images: [ImageAttachment]) -> Data? {
        let result = NSMutableAttributedString(string: text)
        for item in images {
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            let wrapper = FileWrapper(regularFileWithContents: item.data)
            wrapper.preferredFilename = URL(fileURLWithPath: item.path).lastPathComponent
            let attachment = NSTextAttachment(fileWrapper: wrapper)
            let cell = NSTextAttachmentCell(imageCell: item.image)
            attachment.attachmentCell = cell
            result.append(NSAttributedString(attachment: attachment))
            result.append(NSAttributedString(string: "\n\(item.path)"))
        }
        return try? result.data(
            from: NSRange(location: 0, length: result.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
