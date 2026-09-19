import Foundation

struct ProjectMediaAsset: Codable, Equatable, Identifiable, Sendable {
    struct StillImage: Codable, Equatable, Sendable { var width: Int; var height: Int }
    let id: UUID
    var url: URL
    var sourceRange: TimelineRange
    var videoMetadata: VideoMetadata?
    var frameDuration: TimelineTime?
    var stillImage: StillImage? = nil
    var audioName: String? = nil
}

struct VideoProject: Codable, Identifiable, Equatable, Sendable {
    static let currentVersion = 3
    let projectVersion: Int
    let id: UUID
    let primaryAssetID: UUID
    private(set) var assets: [ProjectMediaAsset]
    var displayName: String
    var thumbnailFileName: String?
    var canvas: ProjectCanvas
    var timeline: Timeline
    let createdAt: Date
    var updatedAt: Date
    /// Optional so projects written before HDR support decode unchanged; a
    /// missing value means the document predates the choice and must keep its
    /// original SDR behaviour. Read through `colorMode`, never directly.
    private var storedColorMode: ProjectColorMode?

    /// The project's working and output colour mode. Defaults to `.sdr`, which
    /// is exactly what every existing project was.
    var colorMode: ProjectColorMode {
        get { storedColorMode ?? .sdr }
        set { storedColorMode = newValue }
    }

    /// True when this project could be switched to HDR at all. Used to decide
    /// whether to offer the choice, not to make it.
    var canPreserveHDR: Bool {
        ProjectColorMode.canPreserveHDR(for: metadata)
    }

    // Validated at decode/store boundaries. Compatibility accessors for source-info UI.
    var primaryAsset: ProjectMediaAsset { assets.first { $0.id == primaryAssetID }! }
    var sourceURL: URL { primaryAsset.url }
    var metadata: VideoMetadata { primaryAsset.videoMetadata! }
    mutating func addAsset(_ asset: ProjectMediaAsset) { assets.append(asset) }

    /// Repairs app-owned absolute paths after iOS moves the app's data
    /// container (which commonly happens when installing a new build from
    /// Xcode). The files move with the container, but an absolute URL stored in
    /// the project document still contains the previous container UUID.
    ///
    /// Only a missing path with a same-named file in GradeLab's current managed
    /// folder is changed, so this never substitutes unrelated external media.
    @discardableResult
    mutating func relocateManagedFiles(to rootURL: URL, fileManager: FileManager = .default) -> Bool {
        var changed = false
        let imports = rootURL.appendingPathComponent("Imports", isDirectory: true)
        for index in assets.indices where !fileManager.fileExists(atPath: assets[index].url.path) {
            let candidate = imports.appendingPathComponent(assets[index].url.lastPathComponent)
            if fileManager.fileExists(atPath: candidate.path) {
                assets[index].url = candidate
                changed = true
            }
        }

        if let thumbnailFileName,
           !fileManager.fileExists(atPath: thumbnailFileName) {
            let candidate = rootURL
                .appendingPathComponent("Thumbnails", isDirectory: true)
                .appendingPathComponent(URL(fileURLWithPath: thumbnailFileName).lastPathComponent)
            if fileManager.fileExists(atPath: candidate.path) {
                self.thumbnailFileName = candidate.path
                changed = true
            }
        }
        return changed
    }

    /// Whether the timeline draws on anything but the primary source.
    ///
    /// Asked of the CLIPS, not of `assets`, because deleting a clip never
    /// removes the media it referenced. A project that once held a second clip
    /// kept an orphaned asset for good, and with it the compositor — which on an
    /// Apple Log project meant deleting the extra clip did not restore the
    /// preview, leaving the document permanently unplayable.
    ///
    /// The "is the primary asset" half is not redundant. The single-source path
    /// renders `sourceURL` and `metadata`, which are the primary asset's; one
    /// remaining clip that references some other asset must still composite, or
    /// it would play the wrong footage.
    private var drawsOnMoreThanThePrimaryAsset: Bool {
        let referenced = Set(timeline.tracks.flatMap(\.items).map(\.assetID))
        guard referenced.count <= 1 else { return true }
        guard let only = referenced.first else { return false }
        return only != primaryAssetID
    }

    var needsLayerCompositor: Bool {
        if !timeline.transitions.isEmpty { return true }
        return canvas.width != metadata.displayWidth || canvas.height != metadata.displayHeight ||
        drawsOnMoreThanThePrimaryAsset || timeline.tracks.count > 1 || timeline.tracks.contains { !$0.isEnabled } ||
        timeline.hasAnimation ||
        timeline.tracks.flatMap(\.items).contains { item in
            guard case .video(let clip) = item else { return true }
            let sourceHasAudio = assets.first(where: { $0.id == clip.assetID })?.videoMetadata?.hasAudio == true
            let editedAudio = clip.embeddedAudio.map { $0 != EmbeddedAudio() } ?? sourceHasAudio
            // Frame blending needs two source frames at once, which only the
            // custom compositor can supply.
            return !clip.placement.isEnabled || clip.transform != VisualTransform() || clip.opacity != 1 ||
                clip.blendMode != .normal || clip.resolvedLayerMask.isEnabled || editedAudio || clip.smoothsMotion
        }
    }

    init(
        id: UUID = UUID(), sourceURL: URL, displayName: String,
        thumbnailFileName: String? = nil, metadata: VideoMetadata,
        gradeSettings: GradeSettings = .neutral,
        sourceRange: TimelineRange? = nil, frameDuration: TimelineTime? = nil,
        colorMode: ProjectColorMode? = nil,
        createdAt: Date = .now, updatedAt: Date = .now
    ) {
        projectVersion = Self.currentVersion
        self.id = id
        primaryAssetID = Self.derivedID(id, salt: 1)
        let trackID = Self.derivedID(id, salt: 2)
        let clipID = Self.derivedID(id, salt: 3)
        // Old JSON only had seconds. New imports supply the exact AVAssetTrack range.
        let range = sourceRange ?? TimelineRange(start: .zero,
            duration: (try? TimelineTime.seconds(metadata.durationSeconds)) ?? .zero)
        let resolvedFrameDuration = frameDuration ?? ProjectCanvas.inferredFrameDuration(from: metadata)
        assets = [.init(id: primaryAssetID, url: sourceURL, sourceRange: range,
                       videoMetadata: metadata, frameDuration: resolvedFrameDuration)]
        self.displayName = displayName
        self.thumbnailFileName = thumbnailFileName
        canvas = .init(width: metadata.displayWidth, height: metadata.displayHeight,
                       frameDuration: resolvedFrameDuration)
        let clip = VideoClip(
            placement: .init(id: clipID, trackID: trackID, timelineStart: .zero, duration: range.duration),
            assetID: primaryAssetID, sourceRange: range, gradeSettings: gradeSettings,
            embeddedAudio: metadata.hasAudio ? EmbeddedAudio() : nil)
        timeline = .init(tracks: [.init(id: trackID, name: "Main Video", kind: .mainVideo, items: [.video(clip)])])
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        // A new import defaults by source, but the caller decides: the import
        // flow asks, and passing an explicit mode records that answer.
        storedColorMode = colorMode ?? .default(for: metadata)
    }

    /// Stable across repeated migration reads, without touching the media itself.
    private static func derivedID(_ id: UUID, salt: UInt8) -> UUID {
        var bytes = id.uuid
        bytes.15 ^= salt
        return UUID(uuid: bytes)
    }

    /// Temporary adapter boundary: never flatten an unsupported timeline silently.
    var singleSourceClip: VideoClip? {
        guard timeline.tracks.count == 1, let track = timeline.tracks.first,
              timeline.transitions.isEmpty,
              track.kind == .mainVideo, track.isEnabled, track.items.count == 1,
              case .video(let clip) = track.items[0], clip.placement.isEnabled,
              clip.assetID == primaryAssetID, clip.placement.timelineStart == .zero,
              clip.sourceRange == primaryAsset.sourceRange,
              clip.placement.duration == primaryAsset.sourceRange.duration,
              clip.transform == VisualTransform(), clip.opacity == 1, !clip.isAnimated,
              !clip.isRetimed,
              clip.embeddedAudio == (metadata.hasAudio ? EmbeddedAudio() : nil),
              canvas.width == metadata.displayWidth, canvas.height == metadata.displayHeight,
              canvas.frameDuration == primaryAsset.frameDuration,
              canvas.background == .black else { return nil }
        return clip
    }

    func validate() throws {
        guard projectVersion == Self.currentVersion else { throw TimelineError.invalid("Unsupported document version.") }
        guard Set(assets.map(\.id)).count == assets.count,
              let primary = assets.first(where: { $0.id == primaryAssetID }), primary.videoMetadata != nil else {
            throw TimelineError.invalid("Missing or duplicate source asset.")
        }
        guard canvas.width > 0, canvas.height > 0,
              canvas.frameDuration.map({ $0 > .zero }) ?? true else {
            throw TimelineError.invalid("Invalid canvas dimensions or frame duration.")
        }
        guard Set(timeline.tracks.map(\.id)).count == timeline.tracks.count else {
            throw TimelineError.invalid("Duplicate track identifiers.")
        }
        for asset in assets {
            guard asset.url.isFileURL, asset.sourceRange.start >= .zero,
                  asset.sourceRange.duration > .zero else { throw TimelineError.invalid("Invalid asset range or URL.") }
            _ = try asset.sourceRange.end
        }
        var itemIDs = Set<UUID>()
        for track in timeline.tracks {
            if track.kind == .audio { try AudioEditing.validate(track) }
            for item in track.items {
                guard itemIDs.insert(item.id).inserted, track.accepts(item),
                      item.placement.trackID == track.id,
                      item.placement.timelineStart >= .zero, item.placement.duration > .zero else {
                    throw TimelineError.invalid("Invalid clip placement or track membership.")
                }
                _ = try item.placement.range.end
                if case .video(let clip) = item, let linked = clip.embeddedAudio,
                   !linked.volume.isFinite || !(0...1).contains(linked.volume) {
                    throw TimelineError.invalid("Audio volume must be between 0 and 100 percent.")
                }
                if case .audio = item, assets.first(where: { $0.id == item.assetID })?.stillImage != nil {
                    throw TimelineError.invalid("An audio clip cannot reference an image.")
                }
                if case .text(let clip) = item {
                    guard clip.text.count <= 20_000, clip.opacity.isFinite, (0...1).contains(clip.opacity),
                          clip.style.fontSize.isFinite, (6...2048).contains(clip.style.fontSize),
                          clip.strokeWidth.isFinite, (0...64).contains(clip.strokeWidth), clip.curve.isFinite, (-1...1).contains(clip.curve) else {
                        throw TimelineError.invalid("Invalid text style.")
                    }
                    let values = [clip.transform.positionX, clip.transform.positionY, clip.transform.scale, clip.transform.widthScale, clip.transform.heightScale, clip.transform.rotationDegrees, clip.transform.anchorX, clip.transform.anchorY, clip.style.characterSpacing, clip.style.lineSpacing, clip.style.layoutWidth, clip.shadowRadius, clip.shadowOffsetX, clip.shadowOffsetY, clip.cornerRadius]
                    let decoration = clip.decoration ?? .init()
                    let colors = [clip.color, clip.strokeColor, clip.backgroundColor, decoration.shadowColor, decoration.glowColor]
                    guard colors.allSatisfy({ color in [color.red, color.green, color.blue, color.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }),
                          [decoration.padding, decoration.glowRadius, clip.shadowRadius, clip.cornerRadius].allSatisfy({ $0.isFinite && (0...2048).contains($0) }) else { throw TimelineError.invalid("Invalid text color or decoration.") }
                    guard values.allSatisfy(\.isFinite), clip.transform.scale > 0, clip.transform.widthScale > 0, clip.transform.heightScale > 0,
                          (0.05...1.5).contains(clip.style.layoutWidth), (-20...100).contains(clip.style.characterSpacing), (0...300).contains(clip.style.lineSpacing),
                          [clip.backgroundOpacity, clip.shadowOpacity, clip.glowOpacity].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw TimelineError.invalid("Invalid text geometry or appearance.") }
                }
                if case .shape(let clip) = item {
                    let sizes = [clip.width, clip.height, clip.strokeWidth, clip.cornerRadius,
                                 clip.shadowRadius, clip.glowRadius]
                    let offsets = [clip.shadowOffsetX, clip.shadowOffsetY]
                    let geometry = [clip.transform.positionX, clip.transform.positionY, clip.transform.scale,
                                    clip.transform.widthScale, clip.transform.heightScale,
                                    clip.transform.rotationDegrees, clip.transform.anchorX, clip.transform.anchorY]
                    var colors = [clip.fillColor, clip.strokeColor, clip.shadowColor, clip.glowColor]
                    if let gradient = clip.gradient { colors.append(contentsOf: [gradient.start, gradient.end]) }
                    guard sizes.allSatisfy({ $0.isFinite && (0...8192).contains($0) }),
                          clip.width > 0, clip.height > 0,
                          offsets.allSatisfy({ $0.isFinite && (-8192...8192).contains($0) }),
                          geometry.allSatisfy(\.isFinite),
                          clip.transform.scale > 0, clip.transform.widthScale > 0, clip.transform.heightScale > 0,
                          ShapeKind.pointCountRange.contains(clip.pointCount),
                          clip.innerRadius.isFinite, (0.01...1).contains(clip.innerRadius),
                          [clip.opacity, clip.shadowOpacity, clip.glowOpacity]
                              .allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                          clip.gradient.map({ $0.angleDegrees.isFinite && (-360...360).contains($0.angleDegrees) }) ?? true,
                          colors.allSatisfy({ color in
                              [color.red, color.green, color.blue, color.alpha]
                                  .allSatisfy { $0.isFinite && (0...1).contains($0) }
                          }) else {
                        throw TimelineError.invalid("Invalid shape geometry or appearance.")
                    }
                }
                switch item {
                case .text(let clip): try Self.validateAnimation(clip)
                case .shape(let clip): try Self.validateAnimation(clip)
                case .video(let clip):
                    try Self.validateAnimation(clip)
                    try Self.validateMaskedGrades(clip)
                case .audio: break
                }
                let sourceRange: TimelineRange?
                switch item {
                case .video(let clip): sourceRange = clip.sourceRange
                case .audio(let clip): sourceRange = clip.sourceRange
                case .text, .shape: sourceRange = nil
                }
                if let sourceRange {
                    // A clip occupies `sourceRange.duration / speed` of timeline.
                    // At the default speed of 1 this is the equality it has
                    // always been; a retimed clip covers the same frames over a
                    // different span, and the two must never disagree.
                    let expectedDuration: TimelineTime
                    if case .video(let clip) = item, clip.isRetimed {
                        expectedDuration = (try? ClipSpeed.timelineDuration(
                            sourceDuration: sourceRange.duration, speed: clip.speed)) ?? sourceRange.duration
                    } else {
                        expectedDuration = sourceRange.duration
                    }
                    guard let asset = assets.first(where: { $0.id == item.assetID }),
                          sourceRange.start >= .zero,
                          expectedDuration == item.placement.duration,
                          try asset.stillImage != nil || (sourceRange.start >= asset.sourceRange.start && sourceRange.end <= asset.sourceRange.end) else {
                        throw TimelineError.invalid("Clip exceeds its source range or references missing media.")
                    }
                }
                if case .video = item,
                   assets.first(where: { $0.id == item.assetID })?.videoMetadata == nil,
                   assets.first(where: { $0.id == item.assetID })?.stillImage == nil {
                    throw TimelineError.invalid("A video clip references non-video media.")
                }
            }
        }
        guard Set(timeline.markers.map(\.id)).count == timeline.markers.count,
              timeline.markers.allSatisfy({ $0.time >= .zero }) else {
            throw TimelineError.invalid("Invalid timeline markers.")
        }
        try TimelineTransitionEditing.validate(project: self)
    }

    /// Malformed animation is rejected here with a readable reason rather than reaching
    /// the renderer. Ordering and duplicate frames are already repaired while decoding
    /// `AnimationTrack`; this checks what cannot be repaired without guessing intent.
    /// Masked local grades. Geometry is repaired on the way to the GPU by
    /// `MaskGeometry.clamped`, so what is checked here is what cannot be
    /// repaired without guessing intent: identity, count and keyframe sanity.
    private static func validateMaskedGrades(_ clip: VideoClip) throws {
        guard let masks = clip.maskedGrades, !masks.isEmpty else { return }
        var seen = Set<UUID>()
        for mask in masks {
            guard seen.insert(mask.id).inserted else {
                throw TimelineError.invalid("Duplicate mask identifier on a clip.")
            }
            guard mask.strength.isFinite, (0...1).contains(mask.strength) else {
                throw TimelineError.invalid("Mask strength must be between 0 and 100 percent.")
            }
            guard mask.geometry.points.count <= MaskGeometry.maximumPoints else {
                throw TimelineError.invalid("A freehand mask has too many points.")
            }
            guard mask.geometry.points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
                throw TimelineError.invalid("A freehand mask has an invalid point.")
            }
            guard let animation = mask.animation else { continue }
            var properties = Set<AnimatableProperty>()
            for track in animation.tracks {
                guard properties.insert(track.property).inserted else {
                    throw TimelineError.invalid("Duplicate mask animation track for \(track.property.title).")
                }
                guard MaskedGradeLayer.animatableProperties.contains(track.property) else {
                    throw TimelineError.invalid("\(track.property.title) cannot be animated on a mask.")
                }
                guard track.keyframes.count <= AnimationTrack.keyframeLimit else {
                    throw TimelineError.invalid("Too many keyframes on \(track.property.title).")
                }
                for frame in track.keyframes {
                    guard frame.time >= .zero, frame.value.isFinite,
                          frame.value.kind == track.property.kind else {
                        throw TimelineError.invalid("Invalid mask keyframe on \(track.property.title).")
                    }
                    if case .number(let number) = frame.value, !track.property.range.contains(number) {
                        throw TimelineError.invalid("\(track.property.title) keyframe is out of range.")
                    }
                    try validateCurveKeyframe(frame, property: track.property)
                }
            }
        }
    }

    private static func validateAnimation<Clip: AnimatableClip>(_ clip: Clip) throws {
        guard let animation = clip.animation else { return }
        var seen = Set<AnimatableProperty>()
        for track in animation.tracks {
            guard seen.insert(track.property).inserted else {
                throw TimelineError.invalid("Duplicate animation track for \(track.property.title).")
            }
            guard Clip.supports(track.property) else {
                throw TimelineError.invalid("\(track.property.title) cannot be animated on this clip.")
            }
            guard track.keyframes.count <= AnimationTrack.keyframeLimit else {
                throw TimelineError.invalid("Too many keyframes on \(track.property.title).")
            }
            var previous: TimelineTime?
            for frame in track.keyframes {
                guard frame.time >= .zero else { throw TimelineError.invalid("Keyframe time cannot be negative.") }
                if let previous, frame.time <= previous {
                    throw TimelineError.invalid("Keyframes on \(track.property.title) are out of order.")
                }
                previous = frame.time
                guard frame.value.isFinite, frame.value.kind == track.property.kind else {
                    throw TimelineError.invalid("Invalid keyframe value on \(track.property.title).")
                }
                if case .number(let number) = frame.value, !track.property.range.contains(number) {
                    throw TimelineError.invalid("\(track.property.title) keyframe is out of range.")
                }
                if case .color(let color) = frame.value,
                   ![color.red, color.green, color.blue, color.alpha].allSatisfy({ (0...1).contains($0) }) {
                    throw TimelineError.invalid("\(track.property.title) keyframe color is out of range.")
                }
                try validateCurveKeyframe(frame, property: track.property)
            }
        }
    }

    /// A curve keyframe carries a whole curve rather than a number, so what it
    /// has to satisfy is different: the right curve type, points inside the
    /// space the evaluator is defined on, and a bounded count, since the
    /// evaluator runs over them once per frame.
    private static func validateCurveKeyframe(_ frame: Keyframe, property: AnimatableProperty) throws {
        guard case .curve(let curve) = frame.value else { return }
        guard case .curve(let expected) = property.gradeSlot, curve.type == expected else {
            throw TimelineError.invalid("\(property.title) keyframe holds the wrong curve.")
        }
        guard curve.points.count <= AdvancedCurve.maximumSnapshotPoints else {
            throw TimelineError.invalid("\(property.title) keyframe has too many control points.")
        }
        let lowerY: Float = curve.type.isMapping ? 0 : -1
        guard curve.points.allSatisfy({ (0...1).contains($0.x) && (lowerY...1).contains($0.y) }) else {
            throw TimelineError.invalid("\(property.title) keyframe is out of range.")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case projectVersion, id, primaryAssetID, assets, displayName, thumbnailFileName
        case canvas, timeline, createdAt, updatedAt
        case colorMode
        case sourceURL, metadata, gradeSettings // Read-only V1 keys.
    }

    private init(version: Int, id: UUID, primaryAssetID: UUID, assets: [ProjectMediaAsset],
                 displayName: String, thumbnailFileName: String?, canvas: ProjectCanvas,
                 timeline: Timeline, createdAt: Date, updatedAt: Date,
                 colorMode: ProjectColorMode?) {
        projectVersion = version
        self.id = id
        self.primaryAssetID = primaryAssetID
        self.assets = assets
        self.displayName = displayName
        self.thumbnailFileName = thumbnailFileName
        self.canvas = canvas
        self.timeline = timeline
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        storedColorMode = colorMode
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .projectVersion) ?? 1
        guard (1...Self.currentVersion).contains(version) else {
            throw TimelineError.unsupportedVersion("This project was made by a newer version of GradeLab. Update the app to open it.")
        }
        if version == 1 {
            self.init(id: try c.decode(UUID.self, forKey: .id), sourceURL: try c.decode(URL.self, forKey: .sourceURL),
                      displayName: try c.decode(String.self, forKey: .displayName),
                      thumbnailFileName: try c.decodeIfPresent(String.self, forKey: .thumbnailFileName),
                      metadata: try c.decode(VideoMetadata.self, forKey: .metadata),
                      gradeSettings: try c.decode(GradeSettings.self, forKey: .gradeSettings),
                      colorMode: .sdr,
                      createdAt: try c.decode(Date.self, forKey: .createdAt), updatedAt: try c.decode(Date.self, forKey: .updatedAt))
        } else {
            // V2 is migrated in memory. Its Timeline decoder supplies an empty
            // transition list, and the next autosave writes the V3 schema.
            self.init(version: Self.currentVersion, id: try c.decode(UUID.self, forKey: .id),
                      primaryAssetID: try c.decode(UUID.self, forKey: .primaryAssetID),
                      assets: try c.decode([ProjectMediaAsset].self, forKey: .assets),
                      displayName: try c.decode(String.self, forKey: .displayName),
                      thumbnailFileName: try c.decodeIfPresent(String.self, forKey: .thumbnailFileName),
                      canvas: try c.decode(ProjectCanvas.self, forKey: .canvas),
                      timeline: try c.decode(Timeline.self, forKey: .timeline),
                      createdAt: try c.decode(Date.self, forKey: .createdAt),
                      updatedAt: try c.decode(Date.self, forKey: .updatedAt),
                      colorMode: try c.decodeIfPresent(ProjectColorMode.self, forKey: .colorMode))
        }
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(projectVersion, forKey: .projectVersion)
        try c.encode(id, forKey: .id)
        try c.encode(primaryAssetID, forKey: .primaryAssetID)
        try c.encode(assets, forKey: .assets)
        try c.encode(displayName, forKey: .displayName)
        try c.encodeIfPresent(thumbnailFileName, forKey: .thumbnailFileName)
        try c.encode(canvas, forKey: .canvas)
        try c.encode(timeline, forKey: .timeline)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(storedColorMode, forKey: .colorMode)
    }
}
