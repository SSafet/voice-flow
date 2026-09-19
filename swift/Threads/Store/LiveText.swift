import Foundation

/// The text of an unfinished item, held in memory only (06 §3.2).
///
/// Live fragments are sent to subscribers as they arrive and are never stored;
/// the buffer keeps the text so far only so a client that opens mid-answer gets
/// one catch-up delta from offset 0, and so the completed item is written once
/// when its owner is done. It opens no database and reads none.
final class LiveTextBuffer {
    private var buffers: [String: [TPDeltaStream: String]] = [:]
    private let lock = NSLock()

    /// Returns a delta whose `offset` is the number of UTF-16 code units
    /// already held for this item and stream, then keeps the fragment. Each
    /// stream of an item counts on its own.
    func append(threadID: String, itemID: String, stream: TPDeltaStream,
                delta: String) -> TPLiveDelta {
        lock.lock()
        defer { lock.unlock() }
        var streams = buffers[itemID] ?? [:]
        let existing = streams[stream] ?? ""
        let offset = existing.utf16.count
        streams[stream] = existing + delta
        buffers[itemID] = streams
        return TPLiveDelta(delta: delta, itemID: itemID, offset: offset, stream: stream,
                           threadID: threadID)
    }

    /// One delta at offset 0 carrying everything held for this stream, or `nil`
    /// when nothing is held.
    func catchUp(threadID: String, itemID: String, stream: TPDeltaStream) -> TPLiveDelta? {
        lock.lock()
        defer { lock.unlock() }
        guard let text = buffers[itemID]?[stream], !text.isEmpty else { return nil }
        return TPLiveDelta(delta: text, itemID: itemID, offset: 0, stream: stream,
                           threadID: threadID)
    }

    /// The text held for one stream, empty when there is none.
    func text(itemID: String, stream: TPDeltaStream) -> String {
        lock.lock()
        defer { lock.unlock() }
        return buffers[itemID]?[stream] ?? ""
    }

    /// Every stream's text and forgets the item, so it is stored once.
    func take(itemID: String) -> [TPDeltaStream: String] {
        lock.lock()
        defer { lock.unlock() }
        return buffers.removeValue(forKey: itemID) ?? [:]
    }

    /// Forgets the item without returning anything.
    func drop(itemID: String) {
        lock.lock()
        defer { lock.unlock() }
        buffers.removeValue(forKey: itemID)
    }
}
