import CoreVideo
import Foundation

/// A compact, soft single-channel matte in encoded source orientation.
struct BackgroundMaskPlane: Sendable {
    let width: Int
    let height: Int
    var values: Data

    init(width: Int, height: Int, values: Data) {
        self.width = width
        self.height = height
        self.values = values
    }

    func value(x: Int, y: Int) -> UInt8 {
        guard width > 0, height > 0, !values.isEmpty else { return 0 }
        let px = min(max(x, 0), width - 1), py = min(max(y, 0), height - 1)
        return values[values.index(values.startIndex, offsetBy: py * width + px)]
    }

    func temporallyStabilized(with previous: BackgroundMaskPlane?) -> BackgroundMaskPlane {
        guard let previous, previous.width == width, previous.height == height,
              previous.values.count == values.count else { return self }
        var result = values
        result.withUnsafeMutableBytes { destination in
            values.withUnsafeBytes { current in
                previous.values.withUnsafeBytes { old in
                    let d = destination.bindMemory(to: UInt8.self)
                    let c = current.bindMemory(to: UInt8.self)
                    let p = old.bindMemory(to: UInt8.self)
                    for i in 0..<d.count {
                        let delta = abs(Int(c[i]) - Int(p[i]))
                        // Smooth confidence noise but do not leave a moving
                        // subject's old silhouette hanging behind it.
                        d[i] = delta < 72 ? UInt8((Int(c[i]) * 3 + Int(p[i])) / 4) : c[i]
                    }
                }
            }
        }
        return .init(width: width, height: height, values: result)
    }

    func inverted() -> BackgroundMaskPlane {
        var result = values
        result.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in bytes.indices { bytes[index] = 255 - bytes[index] }
        }
        return .init(width: width, height: height, values: result)
    }

    /// Fractional foreground coverage, retaining the soft values Vision emits.
    var coverage: Double {
        guard !values.isEmpty else { return 0 }
        let total = values.withUnsafeBytes { raw -> UInt64 in
            raw.bindMemory(to: UInt8.self).reduce(into: UInt64(0)) { $0 += UInt64($1) }
        }
        return Double(total) / (Double(values.count) * 255)
    }

    func scaled(by factor: Double) -> BackgroundMaskPlane {
        let amount = min(max(factor, 0), 1)
        var result = values
        result.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for index in bytes.indices { bytes[index] = UInt8((Double(bytes[index]) * amount).rounded()) }
        }
        return .init(width: width, height: height, values: result)
    }
}

struct BackgroundMaskCacheKey: Hashable, Sendable {
    let projectID: UUID
    let clipID: UUID
    let analysisID: UUID
    let frame: Int64
}

/// Generated masks are immutable, rebuildable cache data. Disk identity follows
/// `analysisID`, not clip identity: split and duplicated clips can safely reuse
/// the same source-frame analysis while keeping their authored settings as
/// independent value types. A small memory LRU keeps playback off disk without
/// retaining a long video's mattes in RAM.
final class BackgroundRemovalMaskStore: @unchecked Sendable {
    static let shared = BackgroundRemovalMaskStore()

    private let lock = NSLock()
    private var memory: [BackgroundMaskCacheKey: BackgroundMaskPlane] = [:]
    private var order: [BackgroundMaskCacheKey] = []
    private let capacity = 36
    private let fileManager = FileManager.default

    private init() {}

    func write(_ plane: BackgroundMaskPlane, key: BackgroundMaskCacheKey) throws {
        guard plane.width > 0, plane.height > 0,
              plane.values.count == plane.width * plane.height else { return }
        let directory = try directory(for: key)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var width = UInt32(plane.width).littleEndian
        var height = UInt32(plane.height).littleEndian
        var data = Data(bytes: &width, count: MemoryLayout<UInt32>.size)
        data.append(Data(bytes: &height, count: MemoryLayout<UInt32>.size))
        data.append(plane.values)
        try data.write(to: file(for: key), options: .atomic)
        insert(plane, for: key)
    }

    func read(_ key: BackgroundMaskCacheKey) -> BackgroundMaskPlane? {
        lock.lock()
        if let cached = memory[key] {
            order.removeAll { $0 == key }; order.append(key)
            lock.unlock()
            return cached
        }
        lock.unlock()
        guard let data = try? Data(contentsOf: file(for: key)), data.count >= 8 else { return nil }
        let width = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self)) }
        let height = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        let count = Int(width) * Int(height)
        guard width > 0, height > 0, count == data.count - 8 else { return nil }
        let plane = BackgroundMaskPlane(width: Int(width), height: Int(height), values: data.dropFirst(8))
        insert(plane, for: key)
        return plane
    }

    func nearest(projectID: UUID, clipID: UUID, analysisID: UUID, frame: Int64) -> BackgroundMaskPlane? {
        let exact = BackgroundMaskCacheKey(projectID: projectID, clipID: clipID,
                                           analysisID: analysisID, frame: frame)
        if let value = read(exact) { return value }
        guard let files = try? fileManager.contentsOfDirectory(
            at: try directory(for: exact), includingPropertiesForKeys: nil), !files.isEmpty else { return nil }
        let nearest = files.compactMap { Int64($0.deletingPathExtension().lastPathComponent) }
            .min { abs($0 - frame) < abs($1 - frame) }
        guard let nearest, abs(nearest - frame) <= 2 else { return nil }
        return read(.init(projectID: projectID, clipID: clipID, analysisID: analysisID, frame: nearest))
    }

    func remove(projectID: UUID, clipID: UUID, analysisID: UUID) {
        let key = BackgroundMaskCacheKey(projectID: projectID, clipID: clipID,
                                         analysisID: analysisID, frame: 0)
        try? fileManager.removeItem(at: try directory(for: key))
        lock.lock()
        memory = memory.filter { !($0.key.projectID == projectID && $0.key.clipID == clipID && $0.key.analysisID == analysisID) }
        order.removeAll { $0.projectID == projectID && $0.clipID == clipID && $0.analysisID == analysisID }
        lock.unlock()
    }

    private func insert(_ plane: BackgroundMaskPlane, for key: BackgroundMaskCacheKey) {
        lock.lock(); defer { lock.unlock() }
        memory[key] = plane
        order.removeAll { $0 == key }; order.append(key)
        while order.count > capacity { memory.removeValue(forKey: order.removeFirst()) }
    }

    private func directory(for key: BackgroundMaskCacheKey) throws -> URL {
        let root = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        return root.appendingPathComponent("GradeLab", isDirectory: true)
            .appendingPathComponent("BackgroundMasks", isDirectory: true)
            .appendingPathComponent("v2", isDirectory: true)
            .appendingPathComponent(key.projectID.uuidString, isDirectory: true)
            .appendingPathComponent(key.analysisID.uuidString, isDirectory: true)
    }

    private func file(for key: BackgroundMaskCacheKey) -> URL {
        (try? directory(for: key))?.appendingPathComponent("\(key.frame).mask")
            ?? fileManager.temporaryDirectory.appendingPathComponent("GradeLab-\(key.analysisID)-\(key.frame).mask")
    }
}

enum BackgroundMaskFrameIndex {
    static func make(sourceTime: TimelineTime, assetStart: TimelineTime, frameDuration: TimelineTime?) -> Int64 {
        let duration = max(frameDuration?.seconds ?? (1.0 / 30.0), 1.0 / 240.0)
        return Int64(((sourceTime.seconds - assetStart.seconds) / duration).rounded())
    }
}
