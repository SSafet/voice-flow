import Foundation

/// Turns one record-sync record and the device that made it into a dictation.
enum RemoteDictation {
    /// A tombstoned record is a deletion and never becomes a dictation.
    static func isDeletion(_ record: CloudRecord) -> Bool { record.deletedAt != nil }

    static func entry(from record: CloudRecord, actorDeviceID: String?,
                      thisDeviceID: String?, existing: HistoryEntry?) -> HistoryEntry? {
        guard !isDeletion(record), let payload = record.payload, let text = payload.text else { return nil }
        let timestamp = payload.modifiedAt ?? payload.createdAt ?? payload.legacyTimestamp
        // Changes arrive in order, so the change that created the record is the
        // one that names its device; a later edit never moves it.
        let originDevice: String?
        if let existing {
            originDevice = existing.originDevice
        } else if let actorDeviceID, actorDeviceID != thisDeviceID {
            originDevice = actorDeviceID
        } else {
            originDevice = nil
        }
        return HistoryEntry(text: text,
                            time: timestamp.map { String($0.suffix(8)) } ?? "",
                            timestamp: timestamp,
                            id: record.recordId,
                            destination: CaptureDestination(rawValue: payload.destination ?? "kept"),
                            seen: existing?.text == text ? existing?.seen : false,
                            capability: existing?.capability,
                            attachments: existing?.attachments,
                            captureId: existing?.captureId,
                            originDevice: originDevice)
    }
}
