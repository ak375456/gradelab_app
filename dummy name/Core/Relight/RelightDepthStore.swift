import Foundation

// ---------------------------------------------------------------------------
// The depth cache
//
// Depth is rebuildable cache data and is treated exactly like it: it lives in
// Caches, outside the project document, so the system may reclaim it and the
// worst that happens is a re-analysis. The document records only which
// analysis the lights were set up against (`RelightAnalysisReference`).
//
// One file per stored source frame, at analysis resolution — a few hundred
// pixels on the long edge, sixteen-bit depth and eight-bit confidence,
// LZFSE-compressed. Depth is smooth, so it compresses well, and a minute of
// footage is a few tens of megabytes rather than the gigabytes full-resolution
// maps would be. The renderers upsample it against the frame being drawn.
// ---------------------------------------------------------------------------

/// Which estimator produced a frame's depth.
enum RelightEstimatorKind: UInt8, Codable, Sendable {
    /// Geometry built from Vision's people, object and face analysis. Always
    /// available, strongest on people.
    case structural = 1
    /// A monocular depth model run through Core ML, when one is installed.
    case coreML = 2
    /// Depth recorded by the camera itself. Reserved: no capture path reads
    /// it yet, and nothing claims to.
    case captured = 3

    var title: String {
        switch self {
        case .structural: String(localized: "Built-in scene geometry")
        case .coreML: String(localized: "Core ML depth model")
        case .captured: String(localized: "Captured depth")
        }
    }
}

/// One stored frame of depth.
struct RelightDepthPlane: Sendable {
    let width: Int
    let height: Int
    /// Nearness, 0 far … 65535 near, in ENCODED source orientation, so it
    /// lines up with the pixels the renderers grade.
    let depth: [UInt16]
    /// How far the depth here can be trusted, 0…255.
    let confidence: [UInt8]
    /// The first frame after a cut. Nothing interpolates across it.
    let startsShot: Bool
    let estimator: RelightEstimatorKind
    /// How strongly this estimator's depth should be read as surface slope.
    /// A model's relative depth and the built-in geometry are scaled
    /// differently, and this keeps one light looking the same on both.
    let relief: Float

    var isValid: Bool {
        width > 0 && height > 0 && depth.count == width * height && confidence.count == width * height
    }

    private static let magic: UInt32 = 0x4752_4C44 // "GRLD"
    private static let formatVersion: UInt16 = 1

    func encoded() throws -> Data {
        guard isValid, width <= Int(UInt16.max), height <= Int(UInt16.max) else {
            throw RelightError.message(String(localized: "A depth frame could not be stored."))
        }
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        append(Self.magic)
        append(Self.formatVersion)
        append(UInt16(startsShot ? 1 : 0))
        append(UInt16(width))
        append(UInt16(height))
        append(estimator.rawValue)
        append(UInt8(0))
        append(UInt16(min(max(relief * 1000, 0), Float(UInt16.max)).rounded()))

        var raw = Data(capacity: depth.count * 3)
        depth.withUnsafeBytes { raw.append(contentsOf: $0) }
        confidence.withUnsafeBytes { raw.append(contentsOf: $0) }
        let compressed = try (raw as NSData).compressed(using: .lzfse) as Data
        return header + compressed
    }

    init(width: Int, height: Int, depth: [UInt16], confidence: [UInt8],
         startsShot: Bool, estimator: RelightEstimatorKind, relief: Float) {
        self.width = width
        self.height = height
        self.depth = depth
        self.confidence = confidence
        self.startsShot = startsShot
        self.estimator = estimator
        self.relief = relief
    }

    /// magic 4, version 2, flags 2, width 2, height 2, estimator 1, spare 1, relief 2.
    static let headerSize = 16

    init(decoding data: Data) throws {
        let headerSize = Self.headerSize
        guard data.count > headerSize else {
            throw RelightError.message("Depth frame is truncated.")
        }
        func read<T: FixedWidthInteger>(_ offset: Int, as type: T.Type) -> T {
            data.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: T.self)) }
        }
        guard read(0, as: UInt32.self) == Self.magic,
              read(4, as: UInt16.self) == Self.formatVersion else {
            throw RelightError.message("Depth frame has an unknown format.")
        }
        let flags = read(6, as: UInt16.self)
        let width = Int(read(8, as: UInt16.self))
        let height = Int(read(10, as: UInt16.self))
        let estimator = RelightEstimatorKind(rawValue: read(12, as: UInt8.self)) ?? .structural
        let relief = Float(read(14, as: UInt16.self)) / 1000
        let payload = data.subdata(in: (data.startIndex + headerSize)..<data.endIndex)
        let raw = try (payload as NSData).decompressed(using: .lzfse) as Data
        let count = width * height
        guard count > 0, raw.count == count * 3 else {
            throw RelightError.message("Depth frame payload does not match its size.")
        }
        var depth = [UInt16](repeating: 0, count: count)
        var confidence = [UInt8](repeating: 0, count: count)
        raw.withUnsafeBytes { bytes in
            depth.withUnsafeMutableBytes { destination in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[0..<(count * 2)]))
            }
            confidence.withUnsafeMutableBytes { destination in
                destination.copyMemory(from: UnsafeRawBufferPointer(rebasing: bytes[(count * 2)..<(count * 3)]))
            }
        }
        self.init(width: width, height: height, depth: depth, confidence: confidence,
                  startsShot: flags & 1 != 0, estimator: estimator, relief: relief)
    }
}

enum RelightError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let value) = self { return value }
        return nil
    }
}

/// What the renderers draw with for one moment: the stored frame at or before
/// it, the one after, and how far between the two the moment falls.
///
/// Depth is stored at a steady rate below the frame rate and is temporally
/// fused, so a moment between two stored frames is their blend. A cut between
/// them is never blended across.
struct RelightDepthSample: Sendable {
    struct Frame: Sendable {
        let index: Int64
        let plane: RelightDepthPlane
        let cacheKey: String
    }

    let first: Frame
    let second: Frame?
    /// 0 is `first`, 1 is `second`.
    let phase: Float
    let quality: RelightQuality

    var relief: Float {
        guard let second else { return first.plane.relief }
        return first.plane.relief + (second.plane.relief - first.plane.relief) * phase
    }
}

/// A summary of the stored analysis for one source, for the panel.
struct RelightAnalysisManifest: Codable, Equatable, Sendable {
    var version: Int
    var estimator: RelightEstimatorKind
    var quality: RelightQuality
    var analysisWidth: Int
    var analysisHeight: Int
    var stride: Int
    var updatedAt: Date
}

final class RelightDepthStore: @unchecked Sendable {
    static let shared = RelightDepthStore()

    struct Key: Hashable, Sendable {
        let identifier: String
        let quality: RelightQuality
    }

    private struct FrameKey: Hashable {
        let key: Key
        let index: Int64
    }

    private let lock = NSLock()
    /// Stored frame indices per source and quality, sorted. Read from the
    /// directory once and kept current by every write.
    private var indexes: [Key: [Int64]] = [:]
    /// Planes in memory, each with the store revision it was written or
    /// loaded at. The stamp is part of the key a renderer uploads under, so a
    /// frame rewritten by a later analysis is never drawn from a stale upload.
    private var memory: [FrameKey: (plane: RelightDepthPlane, stamp: UInt64)] = [:]
    private var order: [FrameKey] = []
    private let capacity = 72
    private var manifests: [Key: RelightAnalysisManifest] = [:]
    private let fileManager = FileManager.default
    private let prefetchQueue = DispatchQueue(label: "GradeLab.relight.prefetch", qos: .utility)
    /// Incremented on every write, so a renderer waiting on a frame can tell
    /// that something has landed without being told what.
    private var revisionStorage: UInt64 = 0

    private init() {}

    var revision: UInt64 {
        lock.lock(); defer { lock.unlock() }; return revisionStorage
    }

    // MARK: - Writing

    func write(_ plane: RelightDepthPlane, key: Key, frame: Int64) throws {
        let data = try plane.encoded()
        let directory = try self.directory(for: key)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("\(frame).depth"), options: .atomic)
        lock.lock()
        var list = loadedIndex(key)
        insertSorted(frame, into: &list)
        indexes[key] = list
        revisionStorage &+= 1
        insertMemory(plane, for: FrameKey(key: key, index: frame))
        lock.unlock()
    }

    func writeManifest(_ manifest: RelightAnalysisManifest, key: Key) {
        guard let directory = try? directory(for: key),
              (try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
              let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        lock.lock(); manifests[key] = manifest; lock.unlock()
    }

    func manifest(_ key: Key) -> RelightAnalysisManifest? {
        lock.lock()
        if let cached = manifests[key] { lock.unlock(); return cached }
        lock.unlock()
        guard let directory = try? directory(for: key),
              let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(RelightAnalysisManifest.self, from: data) else { return nil }
        lock.lock(); manifests[key] = manifest; lock.unlock()
        return manifest
    }

    /// Deletes every stored frame for a source, at both qualities.
    func remove(identifier: String) {
        for quality in RelightQuality.allCases {
            clear(Key(identifier: identifier, quality: quality))
        }
    }

    /// Deletes every stored frame for one source at one quality, so an
    /// analysis can start again from nothing rather than over what was there.
    func clear(_ key: Key) {
        if let directory = try? directory(for: key) { try? fileManager.removeItem(at: directory) }
        lock.lock()
        indexes[key] = []
        manifests[key] = nil
        memory = memory.filter { $0.key.key != key }
        order.removeAll { $0.key == key }
        revisionStorage &+= 1
        lock.unlock()
    }

    // MARK: - Reading

    func plane(_ key: Key, frame: Int64) -> RelightDepthPlane? {
        stampedPlane(key, frame: frame)?.plane
    }

    /// The plane and the revision it entered memory at.
    private func stampedPlane(_ key: Key, frame: Int64) -> (plane: RelightDepthPlane, stamp: UInt64)? {
        let frameKey = FrameKey(key: key, index: frame)
        lock.lock()
        if let cached = memory[frameKey] {
            order.removeAll { $0 == frameKey }; order.append(frameKey)
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let directory = try? directory(for: key),
              let data = try? Data(contentsOf: directory.appendingPathComponent("\(frame).depth")),
              let plane = try? RelightDepthPlane(decoding: data), plane.isValid else { return nil }
        lock.lock()
        insertMemory(plane, for: frameKey)
        let stamped = memory[frameKey] ?? (plane, revisionStorage)
        lock.unlock()
        return stamped
    }

    /// The stored frames for one source and quality, sorted.
    func storedFrames(_ key: Key) -> [Int64] {
        lock.lock(); defer { lock.unlock() }
        return loadedIndex(key)
    }

    /// The analysis quality to draw with: `preferred` when it has anything
    /// stored, otherwise whichever quality does. Nil when there is none.
    func availableQuality(identifier: String, preferring preferred: RelightQuality) -> RelightQuality? {
        let order: [RelightQuality] = preferred == .high ? [.high, .fast] : [.fast, .high]
        lock.lock(); defer { lock.unlock() }
        return order.first { !loadedIndex(Key(identifier: identifier, quality: $0)).isEmpty }
    }

    /// The depth for a fractional source-frame position.
    ///
    /// - Parameter maximumGap: the widest span between two stored frames that
    ///   is still bridged by blending. Past it the frames are not neighbours —
    ///   the range between them was never analysed — and only a stored frame
    ///   within `maximumReach` of the position is used on its own.
    func sample(identifier: String, preferring preferred: RelightQuality,
                position: Double, maximumGap: Int64 = 9, maximumReach: Double = 2.5) -> RelightDepthSample? {
        guard position.isFinite,
              let quality = availableQuality(identifier: identifier, preferring: preferred) else { return nil }
        let key = Key(identifier: identifier, quality: quality)
        let neighbours = bracket(key, position: position)
        let cacheKey = "\(identifier)|\(quality.rawValue)|"

        func frame(_ index: Int64) -> RelightDepthSample.Frame? {
            stampedPlane(key, frame: index).map {
                .init(index: index, plane: $0.plane, cacheKey: cacheKey + "\(index)@\($0.stamp)")
            }
        }
        func single(_ index: Int64) -> RelightDepthSample? {
            frame(index).map { RelightDepthSample(first: $0, second: nil, phase: 0, quality: quality) }
        }

        switch (neighbours.below, neighbours.above) {
        case let (below?, above?) where below == above:
            return single(below)
        case let (below?, above?) where above - below <= maximumGap:
            guard let first = frame(below) else { return single(above) }
            guard let second = frame(above) else { return single(below) }
            // The later frame opens a new shot: everything before it belongs
            // to the old one and is never blended with the new.
            if second.plane.startsShot {
                return position >= Double(above) - 0.5
                    ? RelightDepthSample(first: second, second: nil, phase: 0, quality: quality)
                    : RelightDepthSample(first: first, second: nil, phase: 0, quality: quality)
            }
            guard first.plane.width == second.plane.width, first.plane.height == second.plane.height else {
                return position - Double(below) <= Double(above) - position ? single(below) : single(above)
            }
            let phase = Float((position - Double(below)) / Double(above - below))
            return RelightDepthSample(first: first, second: second, phase: min(max(phase, 0), 1), quality: quality)
        case let (below?, above?):
            let nearer = position - Double(below) <= Double(above) - position ? below : above
            return abs(Double(nearer) - position) <= maximumReach ? single(nearer) : nil
        case let (below?, nil):
            return position - Double(below) <= maximumReach ? single(below) : nil
        case let (nil, above?):
            return Double(above) - position <= maximumReach ? single(above) : nil
        case (nil, nil):
            return nil
        }
    }

    /// Whether `sample` would find depth at `position`, without loading any.
    func covers(identifier: String, quality: RelightQuality, position: Double,
                maximumGap: Int64 = 9, maximumReach: Double = 2.5) -> Bool {
        let frames = storedFrames(Key(identifier: identifier, quality: quality))
        return Self.covers(frames, position: position, maximumGap: maximumGap, maximumReach: maximumReach)
    }

    private static func covers(_ frames: [Int64], position: Double,
                               maximumGap: Int64 = 9, maximumReach: Double = 2.5) -> Bool {
        let neighbours = Self.bracket(frames, position: position)
        switch (neighbours.below, neighbours.above) {
        case let (below?, above?):
            return above - below <= maximumGap
                || min(position - Double(below), Double(above) - position) <= maximumReach
        case let (below?, nil): return position - Double(below) <= maximumReach
        case let (nil, above?): return Double(above) - position <= maximumReach
        case (nil, nil): return false
        }
    }

    /// The share of a source-frame range Relight can draw, 0…1, measured by
    /// probing it rather than by counting files — so it answers the question
    /// the panel is actually asking.
    func coverage(identifier: String, quality: RelightQuality, frames: ClosedRange<Int64>) -> Double {
        let span = max(frames.upperBound - frames.lowerBound, 0)
        let probes = Int(min(max(span / 3, 1), 160))
        // The index is read once: the panel asks this on every progress
        // report while an analysis runs.
        let stored = storedFrames(Key(identifier: identifier, quality: quality))
        guard !stored.isEmpty else { return 0 }
        var covered = 0
        for probe in 0...probes {
            let position = Double(frames.lowerBound) + Double(span) * Double(probe) / Double(probes)
            if Self.covers(stored, position: position) { covered += 1 }
        }
        return Double(covered) / Double(probes + 1)
    }

    /// Loads the next few stored frames into memory off the render thread,
    /// so steady playback never waits on a file.
    func prefetch(identifier: String, quality: RelightQuality, after position: Double, count: Int = 6) {
        let key = Key(identifier: identifier, quality: quality)
        prefetchQueue.async { [weak self] in
            guard let self else { return }
            let frames = self.storedFrames(key)
            guard let start = frames.firstIndex(where: { Double($0) >= position }) else { return }
            for index in frames[start..<min(frames.count, start + count)] {
                _ = self.plane(key, frame: index)
            }
        }
    }

    // MARK: - Internals

    /// Must be called with the lock held.
    private func loadedIndex(_ key: Key) -> [Int64] {
        if let existing = indexes[key] { return existing }
        var frames: [Int64] = []
        if let directory = try? directory(for: key),
           let names = try? fileManager.contentsOfDirectory(atPath: directory.path) {
            frames = names.compactMap { name -> Int64? in
                guard name.hasSuffix(".depth") else { return nil }
                return Int64(name.dropLast(6))
            }.sorted()
        }
        indexes[key] = frames
        return frames
    }

    private func bracket(_ key: Key, position: Double) -> (below: Int64?, above: Int64?) {
        Self.bracket(storedFrames(key), position: position)
    }

    private static func bracket(_ frames: [Int64], position: Double) -> (below: Int64?, above: Int64?) {
        guard !frames.isEmpty else { return (nil, nil) }
        // First stored frame at or after the position.
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if Double(frames[mid]) < position { low = mid + 1 } else { high = mid }
        }
        let above: Int64? = low < frames.count ? frames[low] : nil
        let below: Int64?
        if let above, Double(above) == position {
            below = above
        } else {
            below = low > 0 ? frames[low - 1] : nil
        }
        return (below, above)
    }

    private func insertSorted(_ value: Int64, into list: inout [Int64]) {
        var low = 0, high = list.count
        while low < high {
            let mid = (low + high) / 2
            if list[mid] < value { low = mid + 1 } else { high = mid }
        }
        if low < list.count, list[low] == value { return }
        list.insert(value, at: low)
    }

    /// Must be called with the lock held.
    private func insertMemory(_ plane: RelightDepthPlane, for key: FrameKey) {
        memory[key] = (plane, revisionStorage)
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity { memory.removeValue(forKey: order.removeFirst()) }
    }

    private func directory(for key: Key) throws -> URL {
        let root = try fileManager.url(for: .cachesDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        return root.appendingPathComponent("GradeLab", isDirectory: true)
            .appendingPathComponent("Relight", isDirectory: true)
            .appendingPathComponent("v\(RelightSettings.analysisVersion)", isDirectory: true)
            .appendingPathComponent(key.identifier, isDirectory: true)
            .appendingPathComponent(key.quality.rawValue, isDirectory: true)
    }
}
