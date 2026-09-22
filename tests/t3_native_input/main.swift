import AppKit
import CryptoKit
import GRDB

func vflog(_ message: String) {}
final class PendingInteraction { var sessionId: String? }
final class UserSettings {
    static let shared = UserSettings()
    var watcherKeepDays = 30
    var watcherDenseApps: Set<String> = []
}

@main
struct NativeInputTests {
    static var count = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        count += 1
        if try !value() { throw NSError(domain: label, code: count) }
    }
    static func refuses(_ label: String, _ body: () throws -> Void) throws {
        var failed = false
        do { try body() } catch { failed = true }
        try check(failed, label)
    }
    @MainActor static func refusesAsync(_ label: String, _ body: () async throws -> Void) async throws {
        var failed = false
        do { try await body() } catch { failed = true }
        try check(failed, label)
    }
    static func png(_ width: Int = 128, _ height: Int = 96, salt: UInt32 = 1) -> Data {
        var state = salt
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in pixels.indices { state = state &* 1664525 &+ 1013904223; pixels[i] = UInt8(state >> 24) }
        for i in stride(from: 3, to: pixels.count, by: 4) { pixels[i] = 255 }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let paths = VoiceFlowPaths.shared
        try check(paths.isIsolated, "only isolated root")
        let root = paths.configRoot, fm = FileManager.default
        let service = try CapturedService(root: root)
        try service.catchUpNow()
        let native = ShellCapturedInput(paths: paths, service: service)
        var binding = ShellComposerBinding()
        let target = ShellComposerTarget(environmentId: "env", kind: .thread, id: "thread", composerId: "composer")
        _ = binding.publish(target, documentId: binding.documentId)
        let frozen = binding.freeze()!
        let id = try native.custody.reserve(frozen)
        try native.retainAudio(deliveryId: id)
        let audio = PendingAudioStore.save(pcm: Data(repeating: 9, count: 4000), runId: UUID(uuidString: id)!, sampleRate: 16000)!
        let audioHash = hash(try Data(contentsOf: audio))
        let display = DisplayContext(id: 0, frame: NSRect(x: 0, y: 0, width: 1200, height: 1000),
            visibleFrame: .zero, backingScaleFactor: 1, captureIndex: 1)
        let raw = png(1200, 1000)
        let shot = CaptureStore.saveShot(raw, on: display, pendingDelivery: try native.custody.reservation(id))!
        let shotURL = URL(fileURLWithPath: shot.path)
        let original = try Data(contentsOf: shotURL)
        let originalHash = hash(original)
        try check(original.count > 524_288, "real JPEG spans multiple maximum-sized chunks")
        let pictureId = try native.attachShot(path: shot.path, deliveryId: id)
        let input = try await native.complete(deliveryId: id, text: "retained narration", captureIds: [pictureId],
            attachments: [shot.path], capability: .snapshot)
        try check(input.destination == frozen && native.custody.owns(input), "immutable native admission")
        let saved = try CapturedPendingFiles.read(source: shotURL)
        try check(saved.completedInput != nil && saved.pictures.first?.sha256 == originalHash, "exact complete metadata persisted before dispatch")
        try check(try CapturedPendingFiles.read(source: audio) == saved, "all existing sources share exact completed payload")
        let query = CapturedQuery(index: service.index, root: root, indexProgress: { service.progress }, mayRead: { true })
        let readService = CapturedReadService(query: query)
        let readReply = try readService.read(.get, arguments: JSONEncoder().encode(
            TPCapturedGetInput(id: pictureId, picture: true, region: nil, textOffset: nil, variant: nil)), delivery: .imageBytes)
        try check(!readReply.isError && readReply.pictures.count == 1, "actual CapturedReadService resolves same native source")
        var assembled = Data(), offset = 0
        while offset < original.count {
            let chunk = try native.custody.read(.init(deliveryId: id, captureId: pictureId, offset: offset, maxBytes: 524_288), binding: binding)
            let bytes = Data(base64Encoded: chunk.base64)!
            try check(chunk.sha256 == originalHash && chunk.sizeBytes == original.count && chunk.offset == offset
                && bytes.count <= 524_288 && chunk.mimeType == "image/jpeg", "immutable bounded chunk metadata")
            assembled.append(bytes); offset += bytes.count
        }
        try check(assembled == original && hash(assembled) == originalHash, "chunk round trip is byte-for-byte original")
        try check(try native.custody.read(.init(deliveryId: id, captureId: pictureId, offset: offset, maxBytes: 1), binding: binding).base64 == "", "exact EOF")
        for request in [
            ShellCaptureReadRequest(deliveryId: UUID().uuidString, captureId: pictureId, offset: 0, maxBytes: 1),
            .init(deliveryId: id, captureId: "shot:unowned", offset: 0, maxBytes: 1),
            .init(deliveryId: id, captureId: pictureId, offset: -1, maxBytes: 1),
            .init(deliveryId: id, captureId: pictureId, offset: offset + 1, maxBytes: 1),
            .init(deliveryId: id, captureId: pictureId, offset: 0, maxBytes: 0),
            .init(deliveryId: id, captureId: pictureId, offset: 0, maxBytes: 524_289)
        ] { try refuses("unowned/out-of-bounds byte request") { _ = try native.custody.read(request, binding: binding) } }
        let request = ShellCaptureReadRequest(deliveryId: id, captureId: pictureId, offset: 0, maxBytes: 100)
        var remounted = binding; remounted.invalidate(); _ = remounted.publish(target, documentId: remounted.documentId)
        try refuses("remount cannot read old bytes") { _ = try native.custody.read(request, binding: remounted) }
        for status in [ShellInputReceipt.Status.staleTarget, .unavailable, .rejected, .unconfirmed] {
            try check(!native.custody.acknowledge(.init(deliveryId: id, status: status)), "failure retains custody")
        }
        PendingAudioStore.remove(runId: UUID(uuidString: id)!)
        try check(fm.fileExists(atPath: audio.path), "all ordinary WAV removal honors custody")

        // Actual store pruners must retain old pending sources across restart.
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: audio.path)
        for _ in 0...PendingAudioStore.keepLimit { _ = PendingAudioStore.save(pcm: Data([1,2]), runId: UUID(), sampleRate: 16000) }
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: shot.path)
        let shots = shotURL.deletingLastPathComponent()
        for n in 0..<62 { try Data([1]).write(to: shots.appendingPathComponent("shot-2099-01-01_12-00-00-\(n).jpg")) }
        _ = CaptureStore.saveShot(png(), on: display)
        try check(hash(try Data(contentsOf: audio)) == audioHash && hash(try Data(contentsOf: shotURL)) == originalHash,
                  "pruning preserves real pending WAV and JPEG hashes")
        let restarted = ShellCapturedInput(paths: paths, service: service)
        try check(restarted.custody.pendingIds.isEmpty, "startup does not auto-replay")
        let recovered = try await restarted.recover(deliveryId: id)
        try check(recovered == input && restarted.custody.owns(input), "explicit same-ID recovery verifies hashes")
        try refuses("restored delivery still stale after remount") { _ = try restarted.custody.read(request, binding: remounted) }
        try png(salt: 7).write(to: shotURL)
        let changed = ShellCapturedInput(paths: paths, service: service)
        try await refusesAsync("changed source cannot rehydrate") { _ = try await changed.recover(deliveryId: id) }
        try check(try native.custody.read(request, binding: binding).sha256 == originalHash, "admitted cached bytes never change after source replacement")
        try original.write(to: shotURL)

        // Privacy and no-follow apply on every read, even with cached bytes.
        try await service.index.pool.write { db in try db.execute(sql: "UPDATE item SET ocr_state='skipped_private' WHERE id=?", arguments: [pictureId]) }
        try refuses("privacy revocation removes byte capability") { _ = try native.custody.read(request, binding: binding) }
        _ = try ShotIngester(index: service.index, root: root).ingest(fileName: shotURL.lastPathComponent)
        try fm.removeItem(at: shotURL)
        try fm.createSymbolicLink(at: shotURL, withDestinationURL: audio)
        try refuses("no-follow denies replaced source symlink") { _ = try native.custody.read(request, binding: binding) }
        try fm.removeItem(at: shotURL); try original.write(to: shotURL)

        // Partial ACK cleanup retains the remaining source; receipt-only restart
        // verifies originals but cannot grant bytes for an uncommitted replay.
        let audioMarker = CapturedPendingFiles.marker(for: audio)
        let markerBytes = try Data(contentsOf: audioMarker)
        try Data("broken".utf8).write(to: audioMarker)
        try check(!native.custody.acknowledge(.init(deliveryId: id, status: .accepted)), "partial cleanup is not falsely complete")
        try check(CapturedPendingFiles.isProtected(audio) && !CapturedPendingFiles.isProtected(shotURL), "failed marker retained while clean marker released")
        try markerBytes.write(to: audioMarker)
        let receiptRestart = ShellCapturedInput(paths: paths, service: service)
        let receiptInput = try await receiptRestart.recover(deliveryId: id, receiptOnly: true)
        try check(receiptInput == input, "partial cleanup supports explicit identical receipt reconciliation")
        try refuses("receipt-only recovery never authorizes bytes") { _ = try receiptRestart.custody.read(request, binding: binding) }
        try check(receiptRestart.custody.acknowledge(.init(deliveryId: id, status: .accepted)), "exact accepted reconciliation clears remaining marker")
        try check(hash(try Data(contentsOf: shotURL)) == originalHash && hash(try Data(contentsOf: audio)) == audioHash,
                  "acceptance removes only custody, never source bytes")

        try await bundleAndFailureCases(paths, service: service, frozen: frozen, display: display)
        print("ok - \(count) native custody/source lifecycle assertions (real CapturedReadService, ImageIO, SQLite and hashes)")
        print("source JPEG SHA256 \(originalHash); WAV SHA256 \(audioHash)")
    }

    @MainActor static func bundleAndFailureCases(_ paths: VoiceFlowPaths, service: CapturedService,
        frozen: ShellFrozenTarget, display: DisplayContext) async throws {
        let fm = FileManager.default
        let native = ShellCapturedInput(paths: paths, service: service)
        let id = try native.custody.reserve(frozen)
        let reservation = try native.custody.reservation(id)
        let store = CaptureStore()
        try check(store.beginSession(runId: UUID(uuidString: id), pendingDelivery: reservation), "bundle reservation before frames")
        store.addFrame(png())
        let summary = store.endSession(transcript: "bundle narration")!
        await store.whenCommitted()
        let captureIds = try native.attachBundle(summary, deliveryId: id)
        let input = try await native.complete(deliveryId: id, text: "bundle narration", captureIds: captureIds,
            attachments: summary.framePaths, capability: .continuous)
        let frame = URL(fileURLWithPath: summary.framePaths[0])
        let frameHash = hash(try Data(contentsOf: frame))
        try check(CaptureStore.readMeta(in: summary.directory)?.pendingDelivery?.completedInput != nil, "bundle complete metadata on same source")
        for n in 0..<42 {
            let directory = paths.configRoot.appendingPathComponent("captures/2099-01-01_12-00-00-\(n)")
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let meta = CaptureBundleMeta(id: directory.lastPathComponent, startedAt: "2099-01-01T12:00:00Z", endedAt: "2099-01-01T12:00:00Z",
                durationSeconds: 0, transcript: "", frames: [])
            try JSONEncoder().encode(meta).write(to: directory.appendingPathComponent("meta.json"))
        }
        _ = store.beginSession(runId: UUID()); _ = store.endSession(transcript: "prune trigger")
        await store.whenCommitted()
        try check(hash(try Data(contentsOf: frame)) == frameHash, "bundle count pruning preserves pending frames")
        let restarted = ShellCapturedInput(paths: paths, service: service)
        let restored = try await restarted.recover(deliveryId: id)
        try check(restored == input, "bundle restart restores exact payload")
        try check(restarted.custody.acknowledge(.init(deliveryId: id, status: .accepted)), "bundle ACK clears custody")
        try check(CaptureStore.readMeta(in: summary.directory)?.pendingDelivery == nil && hash(try Data(contentsOf: frame)) == frameHash,
                  "bundle release leaves original frame hash intact")

        let emptyId = UUID().uuidString
        let emptyReservation = CapturedPendingDelivery(deliveryId: emptyId, reservation: reservation.reservation)
        try check(store.beginSession(runId: UUID(uuidString: emptyId), pendingDelivery: emptyReservation), "empty pending bundle starts")
        let empty = store.endSession(transcript: nil)
        await store.whenCommitted()
        try check(empty != nil && fm.fileExists(atPath: empty!.directory.path), "empty close never deletes pending custody")

        // Source metadata failures must not authorize delivery, overwrite another
        // reservation, evict pending input or create unbounded resident buffers.
        let bytes = png(), syntheticId = "shot:2026-09-22_00-00-00"
        let source = ShellInputSource.file(paths.file("owned.jpg"))
        var failPersist = true
        let bounded = ShellInputCustody(maxPending: 1, maxCachedBytes: bytes.count,
            load: { _ in bytes }, mayRead: { _ in true }, persist: { _, _ in
                if failPersist { throw ShellInputFailure.unavailable }
            }, release: { _, _ in })
        let boundedId = try bounded.reserve(frozen)
        try bounded.attach(source, deliveryId: boundedId, captureIds: [syntheticId])
        try await refusesAsync("metadata write failure blocks dispatch") { _ = try await bounded.complete(boundedId, text: "words", captureIds: [syntheticId]) }
        try check(bounded.input(boundedId) == nil && bounded.cachedBytes == 0 && bounded.pendingIds == [boundedId], "failed completion retains reservation without publishing bytes")
        try refuses("pending admission cannot evict an unconfirmed input") { _ = try bounded.reserve(frozen) }
        failPersist = false
        try await refusesAsync("input cannot reference an unattached capture ID") {
            _ = try await bounded.complete(boundedId, text: "words", captureIds: ["shot:unattached"])
        }
        _ = try await bounded.complete(boundedId, text: "words", captureIds: [syntheticId])
        try await refusesAsync("completed payload cannot be rewritten") { _ = try await bounded.complete(boundedId, text: "changed", captureIds: [syntheticId]) }
        let tiny = ShellInputCustody(maxCachedBytes: bytes.count - 1, load: { _ in bytes }, mayRead: { _ in true }, persist: { _, _ in }, release: { _, _ in })
        let tinyId = try tiny.reserve(frozen); try tiny.attach(source, deliveryId: tinyId, captureIds: [syntheticId])
        try await refusesAsync("byte capacity fails closed without source eviction") { _ = try await tiny.complete(tinyId, text: "", captureIds: [syntheticId]) }
        try check(tiny.pendingIds == [tinyId] && tiny.cachedBytes == 0, "byte capacity retains reservation")

        var resumeRead: CheckedContinuation<Data, Never>?
        let concurrent = ShellInputCustody(maxCachedBytes: bytes.count, load: { _ in
            await withCheckedContinuation { resumeRead = $0 }
        }, mayRead: { _ in true }, persist: { _, _ in }, release: { _, _ in })
        let firstId = try concurrent.reserve(frozen), secondId = try concurrent.reserve(frozen)
        try concurrent.attach(source, deliveryId: firstId, captureIds: [syntheticId])
        try concurrent.attach(source, deliveryId: secondId, captureIds: [syntheticId])
        let firstRead = Task { try await concurrent.complete(firstId, text: "first", captureIds: [syntheticId]) }
        while resumeRead == nil { await Task.yield() }
        try await refusesAsync("concurrent preparation cannot exceed cache admission") {
            _ = try await concurrent.complete(secondId, text: "second", captureIds: [syntheticId])
        }
        resumeRead?.resume(returning: bytes)
        _ = try await firstRead.value
        try check(concurrent.cachedBytes == bytes.count && concurrent.input(secondId) == nil,
                  "concurrent rejected source remains pending without hidden retry")
        let diskFull = ShellInputCustody(pendingOnDisk: { 32 }, load: { _ in bytes }, mayRead: { _ in true },
            persist: { _, _ in }, release: { _, _ in })
        try refuses("restart custody counts toward admission bound") { _ = try diskFull.reserve(frozen) }

        let wav = PendingAudioStore.directory(root: paths).appendingPathComponent("\(UUID().uuidString).wav")
        try Data([1,2,3]).write(to: wav)
        let malformed = CapturedPendingFiles.marker(for: wav)
        try Data("not JSON".utf8).write(to: malformed)
        try check(CapturedPendingFiles.isProtected(wav), "malformed marker still retains source")
        try refuses("malformed metadata cannot be adopted or overwritten") { try CapturedPendingFiles.write(reservation, source: wav) }
        try refuses("malformed metadata cannot authorize cleanup") { try CapturedPendingFiles.clear(source: wav, deliveryId: id) }
        try fm.removeItem(at: malformed)
        try fm.createSymbolicLink(at: malformed, withDestinationURL: paths.file("absent"))
        try check(CapturedPendingFiles.isProtected(wav), "dangling marker symlink is conservative retention")
        try refuses("symlink marker never authorizes bytes or cleanup") { _ = try CapturedPendingFiles.read(source: wav) }
        try check(native.pendingSources(limit: 2).count <= 2, "native recovery listing bounded")
        print("bundle frame SHA256 \(frameHash)")
    }
}
