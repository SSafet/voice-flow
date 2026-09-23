import AppKit

/// Projects the user's frozen overlay into the pixels of the exact selected
/// display JPEG. The rendered screenshot remains the visual source of truth;
/// these bounded marks retain positions, shapes and note text for the model.
enum ShellCaptureMarks {
    static func project(_ snapshot: AnnotationCaptureSnapshot, on display: DisplayContext,
                        width: Int, height: Int) throws -> [TPMark] {
        guard snapshot.visible else { return [] }
        guard (1...32_768).contains(width), (1...32_768).contains(height),
              (width, height) == display.shotGeometry else { throw ShellInputFailure.invalid }
        let items = try snapshot.decodedItems()
        guard items.count <= 128 else { throw ShellInputFailure.capacity }
        let scale = display.annotationPointScale
        guard scale.isFinite, scale > 0 else { throw ShellInputFailure.invalid }
        var result: [TPMark] = []
        var pointCount = 0

        func pixel(_ point: CGPoint) throws -> CGPoint {
            guard point.x.isFinite, point.y.isFinite else { throw ShellInputFailure.invalid }
            // AnnotationCanvas is flipped: its local y=0 is the panel top.
            let global = CGPoint(x: point.x + snapshot.canvasOrigin.x,
                                 y: snapshot.canvasOrigin.y + snapshot.canvasHeight - point.y)
            let mapped = display.screenshotPoint(forGlobalPoint: global)
            guard mapped.x.isFinite, mapped.y.isFinite,
                  abs(mapped.x) <= 32_768, abs(mapped.y) <= 32_768 else { throw ShellInputFailure.invalid }
            return mapped
        }
        func pair(_ point: CGPoint) throws -> [Int] {
            let value = try pixel(point)
            return [Int(value.x.rounded()), Int(value.y.rounded())]
        }
        func size(_ points: CGFloat) throws -> Int {
            guard points.isFinite, points > 0 else { throw ShellInputFailure.invalid }
            let pixels = (points / scale).rounded()
            guard pixels.isFinite, pixels <= 512 else { throw ShellInputFailure.invalid }
            return max(1, Int(pixels))
        }
        func box(_ minX: CGFloat, _ minY: CGFloat, _ maxX: CGFloat, _ maxY: CGFloat) throws -> [Int]? {
            guard [minX, minY, maxX, maxY].allSatisfy(\.isFinite) else { throw ShellInputFailure.invalid }
            let x0 = max(0, min(width, Int(floor(minX))))
            let y0 = max(0, min(height, Int(floor(minY))))
            let x1 = max(0, min(width, Int(ceil(maxX))))
            let y1 = max(0, min(height, Int(ceil(maxY))))
            guard x1 > x0, y1 > y0 else { return nil }
            return [x0, y0, x1 - x0, y1 - y0]
        }
        func bounds(_ points: [CGPoint], padding: CGFloat) throws -> [Int]? {
            guard !points.isEmpty else { throw ShellInputFailure.invalid }
            let mapped = try points.map(pixel)
            return try box(mapped.map(\.x).min()! - padding, mapped.map(\.y).min()! - padding,
                           mapped.map(\.x).max()! + padding, mapped.map(\.y).max()! + padding)
        }
        func color(_ value: NSColor) -> TPMarkColor {
            let rgb = value.usingColorSpace(.sRGB) ?? value
            let selected = AnnotationColors.enumerated().min { lhs, rhs in
                func distance(_ candidate: NSColor) -> CGFloat {
                    let c = candidate.usingColorSpace(.sRGB) ?? candidate
                    return pow(c.redComponent - rgb.redComponent, 2) +
                        pow(c.greenComponent - rgb.greenComponent, 2) +
                        pow(c.blueComponent - rgb.blueComponent, 2)
                }
                return distance(lhs.element) < distance(rhs.element)
            }?.offset ?? 0
            return [.red, .amber, .green, .blue, .magenta, .white][selected]
        }

        for item in items {
            let n = result.count + 1
            let mark: TPMark?
            switch item {
            case let .stroke(points, ink, width), let .highlight(points, ink, width):
                guard (2...2_048).contains(points.count) else { throw ShellInputFailure.capacity }
                pointCount += points.count
                guard pointCount <= 8_192 else { throw ShellInputFailure.capacity }
                let stroke = try size(width)
                let mappedPoints = try points.map(pair)
                guard let clipped = try bounds(points, padding: CGFloat(stroke) / 2 + 2) else { continue }
                let kind: TPMarkKind
                if case .highlight = item { kind = .highlight } else { kind = .pen }
                mark = TPMark(box: clipped, center: nil, color: color(ink), from: nil,
                    kind: kind, label: nil, n: n, note: nil, origin: nil,
                    points: mappedPoints, stroke: stroke, to: nil, underText: nil)
            case let .shape(kind, from, to, ink, width):
                let stroke = try size(width)
                // The rendered arrow head extends beyond its shaft endpoint.
                let padding = kind == .arrow ? max(14 / scale, CGFloat(stroke) * 3.5) : CGFloat(stroke) / 2 + 2
                guard let clipped = try bounds([from, to], padding: padding) else { continue }
                let mappedKind: TPMarkKind
                switch kind {
                case .line: mappedKind = .line
                case .arrow: mappedKind = .arrow
                case .rect: mappedKind = .rect
                case .ellipse: mappedKind = .ellipse
                }
                mark = TPMark(box: clipped, center: nil, color: color(ink),
                    from: mappedKind == .line || mappedKind == .arrow ? try pair(from) : nil,
                    kind: mappedKind, label: nil, n: n, note: nil, origin: nil,
                    points: nil, stroke: stroke,
                    to: mappedKind == .line || mappedKind == .arrow ? try pair(to) : nil,
                    underText: nil)
            case let .number(value, center, ink, diameter):
                let pixelCenter = try pixel(center)
                let radius = CGFloat(try size(diameter)) / 2
                guard let clipped = try box(pixelCenter.x - radius, pixelCenter.y - radius,
                                            pixelCenter.x + radius, pixelCenter.y + radius) else { continue }
                guard (0...9_999).contains(value) else { throw ShellInputFailure.invalid }
                mark = TPMark(box: clipped, center: try pair(center), color: color(ink), from: nil,
                    kind: .badge, label: value, n: n, note: nil, origin: nil,
                    points: nil, stroke: 3, to: nil, underText: nil)
            case let .text(string, origin, ink, fontSize, width, style):
                guard !string.isEmpty, string.utf16.count <= 2_000, string.utf8.count <= 8_000,
                      width.isFinite, width > 0, fontSize.isFinite, fontSize > 0 else { throw ShellInputFailure.capacity }
                let inset = AnnotationCanvas.textInset(style: style, pointSize: fontSize)
                let available = width - (inset.width + AnnotationCanvas.lineFragmentPadding) * 2
                guard available > 0 else { throw ShellInputFailure.invalid }
                let textBounds = NSString(string: string).boundingRect(
                    with: NSSize(width: available, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin],
                    attributes: [.font: AnnotationCanvas.annotationFont(ofSize: fontSize)])
                let noteHeight = max(textBounds.height + inset.height * 2 + 2, fontSize)
                let topLeft = try pixel(origin)
                let bottomRight = try pixel(CGPoint(x: origin.x + width, y: origin.y + noteHeight))
                guard let clipped = try box(topLeft.x, topLeft.y, bottomRight.x, bottomRight.y) else { continue }
                mark = TPMark(box: clipped, center: nil, color: color(ink), from: nil,
                    kind: .text, label: nil, n: n, note: string,
                    origin: try pair(origin),
                    points: nil, stroke: try size(max(1, fontSize * 0.1)), to: nil, underText: nil)
            }
            if let mark { result.append(mark) }
        }
        if !result.isEmpty {
            let bound = ShellMarkedCapture(captureId: "shot:synthetic", sha256: String(repeating: "0", count: 64),
                width: width, height: height, marks: result)
            guard bound.isValid else { throw ShellInputFailure.capacity }
        }
        return result
    }
}
