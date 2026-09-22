import Foundation

/// These are application operations, not JSON-RPC methods. The existing tool
/// host owns schemas, authentication, thread identity and MCP transport.
enum CapturedReadOperation: String, CaseIterable {
    case search = "captured_search", get = "captured_get", frames = "captured_frames"
    case around = "captured_around", summary = "captured_summary"
}

enum CapturedPictureDelivery { case metadataOnly, imageBytes, localFiles }
struct CapturedReadReply {
    let json: Data
    let pictures: [CapturedPictureBytes]
    let isError: Bool
}

struct CapturedReadService {
    let query: CapturedQuery

    /// The caller has already resolved its existing observe grant into
    /// query.mayRead. Recheck it on every request (including each picture).
    /// The shared UI uses metadataOnly and fetches picture bytes separately.
    func read(_ operation: CapturedReadOperation, arguments: Data, limits: CapturedLimits = .agent,
              delivery: CapturedPictureDelivery = .metadataOnly) throws -> CapturedReadReply {
        do {
            guard arguments.count <= 16_000 else { throw CapturedQueryFailure(.invalidArguments, "The request is too large.") }
            try query.checkReady()
            let decoder = JSONDecoder()
            var json: Data, pictures: [CapturedPictureBytes] = []
            var requested: [(String, TPPictureVariant?, [Int]?)] = []
            switch operation {
            case .search:
                json = try JSONEncoder().encode(query.search(decoder.decode(TPCapturedSearchInput.self, from: arguments), limits: limits))
            case .get:
                let input = try decoder.decode(TPCapturedGetInput.self, from: arguments)
                let params = TPCapturedGetInput(id: input.id, picture: delivery == .metadataOnly ? false : input.picture,
                                               region: input.region, textOffset: input.textOffset, variant: input.variant)
                let result = try query.get(params, limits: limits, includePath: false)
                if delivery != .metadataOnly, input.picture != false, result.item.picture?.state == .present {
                    requested = [(input.id, input.variant, input.region)]
                }
                json = try JSONEncoder().encode(result)
            case .frames:
                var input = try decoder.decode(TPCapturedFramesInput.self, from: arguments)
                if delivery != .metadataOnly {
                    input = .init(apps: input.apps, from: input.from, maxPictures: min(input.maxPictures ?? 6, 12), to: input.to)
                }
                let result = try query.frames(input, limits: limits, includePath: false)
                if delivery != .metadataOnly { requested = result.pictures.map { ($0.id, nil, nil) } }
                json = try JSONEncoder().encode(result)
            case .around:
                json = try JSONEncoder().encode(query.around(decoder.decode(TPCapturedAroundInput.self, from: arguments), limits: limits))
            case .summary:
                json = try JSONEncoder().encode(query.summary(decoder.decode(TPCapturedSummaryInput.self, from: arguments), limits: limits))
            }
            var localPaths: [String: String] = [:]
            var deliveredSize: (Int, Int)?
            var unavailable = Set<String>()
            for (id, variant, region) in requested.prefix(12) {
                do {
                    let picture = try query.picture(.init(id: id, maxPx: nil, region: region, variant: variant), byteLimit: 400_000)
                    if operation == .get { deliveredSize = (picture.width, picture.height) }
                    if delivery == .localFiles { localPaths[id] = try CapturedFiles.writeDerived(picture.data, root: query.root) }
                    else { pictures.append(picture) }
                } catch let failure as CapturedQueryFailure {
                    if operation == .get {
                        // Preserve the bounded indexed text when the file disappears
                        // after the metadata snapshot or fails to decode.
                        let input = try decoder.decode(TPCapturedGetInput.self, from: arguments)
                        let retained = try query.get(.init(id: input.id, picture: false, region: nil, textOffset: input.textOffset, variant: input.variant),
                                                     limits: limits, includePath: false)
                        let old = retained.item
                        let picture = old.picture.map {
                            TPCapturedPictureInfo(height: $0.height, path: nil, state: failure.error.code == .pictureGone ? .missing : $0.state, width: $0.width)
                        }
                        let item = TPCapturedItem(at: old.at, children: old.children, context: old.context, durationSeconds: old.durationSeconds,
                            id: old.id, kind: old.kind, links: old.links, marks: old.marks, picture: picture, text: old.text, textTotal: old.textTotal)
                        throw CapturedQueryFailure(failure.error.code, failure.error.message, item: item)
                    }
                    if failure.error.code != .pictureGone { throw failure }
                    unavailable.insert(id)
                }
            }
            if !localPaths.isEmpty || !unavailable.isEmpty || deliveredSize != nil {
                var object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
                if operation == .get, var item = object["item"] as? [String: Any], var picture = item["picture"] as? [String: Any] {
                    picture["path"] = localPaths[item["id"] as? String ?? ""]
                    if let (width, height) = deliveredSize { picture["width"] = width; picture["height"] = height }
                    item["picture"] = picture; object["item"] = item
                }
                if operation == .frames, let frames = object["pictures"] as? [[String: Any]] {
                    object["pictures"] = frames.compactMap { frame -> [String: Any]? in
                        guard let id = frame["id"] as? String, !unavailable.contains(id) else { return nil }
                        var frame = frame; frame["path"] = localPaths[id]; return frame
                    }
                    if !unavailable.isEmpty {
                        object["omitted"] = (object["omitted"] as? Int ?? 0) + unavailable.count
                        object["truncated"] = true
                    }
                }
                // Paths consume budget too. Drop the last frame and its matching
                // bytes together; never return an image detached from its item id.
                while try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).count > limits.resultBytes {
                    if var frames = object["pictures"] as? [[String: Any]], let last = frames.popLast() {
                        if let id = last["id"] as? String { pictures.removeAll { $0.id == id } }
                        object["pictures"] = frames
                        object["omitted"] = (object["omitted"] as? Int ?? 0) + 1; object["truncated"] = true
                    } else if var item = object["item"] as? [String: Any], let text = item["text"] as? String, !text.isEmpty {
                        item["text"] = String(text.prefix(text.count / 2)); object["item"] = item; object["truncated"] = true
                    } else { throw CapturedQueryFailure(.invalidArguments, "The result cannot fit the byte limit.") }
                }
                json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            }
            guard json.count <= limits.resultBytes, pictures.count <= 12,
                  pictures.reduce(0, { $0 + $1.data.count }) <= 4_800_000 else {
                throw CapturedQueryFailure(.invalidArguments, "The result cannot fit the byte limit.")
            }
            return CapturedReadReply(json: json, pictures: pictures, isError: false)
        } catch let failure as CapturedQueryFailure {
            return try failureReply(failure, limits: limits)
        } catch is DecodingError {
            return try failureReply(.init(.invalidArguments, "The request does not match the captured-data input schema."), limits: limits)
        }
    }
    private func failureReply(_ failure: CapturedQueryFailure, limits: CapturedLimits) throws -> CapturedReadReply {
        var item = failure.item
        var json = try JSONEncoder().encode(TPCapturedErrorResult(error: failure.error, item: item, notice: CapturedReadPolicy.notice, ok: false))
        if json.count > limits.resultBytes, let value = item {
            // Reserve space for the refusal without losing all retained text.
            item = TPCapturedItem(at: value.at, children: [], context: nil, durationSeconds: value.durationSeconds, id: value.id, kind: value.kind,
                links: [], marks: [], picture: value.picture, text: value.text.map { String($0.prefix(1_000)) }, textTotal: value.textTotal)
            json = try JSONEncoder().encode(TPCapturedErrorResult(error: failure.error, item: item, notice: CapturedReadPolicy.notice, ok: false))
        }
        guard json.count <= limits.resultBytes else { throw CapturedQueryFailure(.invalidArguments, "The result byte limit is too small.") }
        return CapturedReadReply(json: json, pictures: [], isError: true)
    }
}
