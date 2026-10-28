import Foundation

struct CameraRecording: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let fileName: String
    let createdAt: Date
    let grade: GradeSettings
    let profile: CameraProfile?

    init(id: UUID, fileName: String, createdAt: Date, grade: GradeSettings, profile: CameraProfile? = nil) {
        self.id = id; self.fileName = fileName; self.createdAt = createdAt
        self.grade = grade; self.profile = profile
    }

    var displayName: String {
        String(localized: "Capture · \(createdAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

/// A durable receipt is written BEFORE recording starts. The original lives in
/// the same managed Imports folder as other project media. Only the receipt is
/// removed after the project database has committed. A confirmed Photos copy
/// also releases its local take; failed saves never delete footage. Names,
/// rather than container URLs, survive container moves.
struct CameraRecordingStore: Sendable {
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GradeLab", isDirectory: true)
    }

    private var receipts: URL { root.appendingPathComponent("PendingCaptures", isDirectory: true) }
    func mediaURL(for recording: CameraRecording) -> URL {
        root.appendingPathComponent("Imports", isDirectory: true).appendingPathComponent(recording.fileName)
    }

    func prepare(grade: GradeSettings, profile: CameraProfile = .sdr) throws -> CameraRecording {
        let id = UUID()
        let recording = CameraRecording(id: id, fileName: "\(id.uuidString).mov", createdAt: .now, grade: grade, profile: profile)
        try FileManager.default.createDirectory(at: receipts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Imports"), withIntermediateDirectories: true)
        try JSONEncoder().encode(recording).write(to: receiptURL(recording), options: .atomic)
        return recording
    }

    func pending() throws -> [CameraRecording] {
        guard FileManager.default.fileExists(atPath: receipts.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                // Leave damaged receipts and their media in place.
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(CameraRecording.self, from: data),
                      record.fileName == "\(record.id.uuidString).mov" else { return nil }
                return record
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func complete(_ recording: CameraRecording) throws {
        let url = receiptURL(recording)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// Call only after Photos confirms its copy is committed. A failed Photos
    /// save must leave both the original and its recovery receipt untouched.
    func removeAfterPhotoSave(_ recording: CameraRecording) throws {
        try complete(recording)
        let url = mediaURL(for: recording)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// An explicit user deletion of a pending take. A stale recovery receipt
    /// may coexist with a saved project; its media must remain in that case.
    func delete(_ recording: CameraRecording, preserving referencedMedia: Set<URL>) throws {
        guard recording.fileName == "\(recording.id.uuidString).mov" else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard FileManager.default.fileExists(atPath: receiptURL(recording).path) else { return }
        let url = mediaURL(for: recording)
        let references = Set(referencedMedia.map(\.standardizedFileURL))
        if !references.contains(url.standardizedFileURL), FileManager.default.fileExists(atPath: url.path) {
            // Keep the receipt retryable if removal of the original fails.
            try FileManager.default.removeItem(at: url)
        }
        try complete(recording)
    }

    /// A capture that never produced bytes can be forgotten. A partial movie
    /// is retained for recovery or sharing even when AVFoundation reports an error.
    func discardEmpty(_ recording: CameraRecording) throws {
        let url = mediaURL(for: recording)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard bytes == 0 else { return }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try complete(recording)
    }

    private func receiptURL(_ recording: CameraRecording) -> URL {
        receipts.appendingPathComponent(recording.id.uuidString).appendingPathExtension("json")
    }
}
