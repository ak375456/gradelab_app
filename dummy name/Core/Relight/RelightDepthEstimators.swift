@preconcurrency import CoreML
@preconcurrency import CoreVideo
import CoreGraphics
import Foundation
import ImageIO
import simd
@preconcurrency import Vision

// ---------------------------------------------------------------------------
// Where depth comes from
//
// Two estimators, one contract: a nearness map and a confidence map on the
// analysis grid, in ENCODED source orientation so they line up with the pixels
// the renderers grade. Neither claims to be a reconstruction. Both are
// estimates, and both say how far to trust themselves pixel by pixel, which is
// what lets the lighting stand down where the geometry is a guess.
//
//   Core ML depth   A monocular depth network — Depth Anything V2 Small is the
//                   one this was built against: Apache-2.0 licensed, offered
//                   by Apple as a Core ML package, runs on the Neural Engine.
//                   Used whenever a depth model is installed (see
//                   Docs/RELIGHT.md). Best on everything: rooms, buildings,
//                   landscapes, objects, people.
//
//   Built-in        Always available, nothing to install. Geometry built from
//                   what Vision can say about the frame — where the people
//                   are, where a foreground object is, where faces and noses
//                   are — on a ground-plane prior. Subjects become rounded
//                   forms whose surfaces turn away from the camera at their
//                   silhouettes, faces become ellipsoids with a nose, and the
//                   background recedes toward the top of the frame. Strongest
//                   on people, honest about everything else: away from a
//                   subject its confidence is low and the light kernel falls
//                   back to a gentle, mostly flat response there.
//
// Both run only on analysis keyframes, off the main thread, and never during
// playback or export.
// ---------------------------------------------------------------------------

/// The analysis grid: a few hundred pixels on the long edge, encoded
/// orientation, with each pixel's position in the UPRIGHT picture computed
/// once so the estimators can reason about "up" and about faces.
struct RelightAnalysisGrid: Sendable {
    let width: Int
    let height: Int
    let coordinates: MaskTrackingCoordinates
    /// Upright position of each grid pixel's centre, 0…1 from the top left.
    let display: [SIMD2<Float>]
    /// Width over height of the upright picture.
    let displayAspect: Float

    var count: Int { width * height }

    init(width: Int, height: Int, coordinates: MaskTrackingCoordinates) {
        self.width = width
        self.height = height
        self.coordinates = coordinates
        var display = [SIMD2<Float>](repeating: .zero, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let source = CGPoint(x: (CGFloat(x) + 0.5) / CGFloat(width),
                                     y: (CGFloat(y) + 0.5) / CGFloat(height))
                let upright = coordinates.sourceToDisplay(source)
                display[y * width + x] = SIMD2(Float(upright.x), Float(upright.y))
            }
        }
        self.display = display
        let bounds = coordinates.displayBounds
        displayAspect = bounds.height > 0 ? Float(bounds.width / bounds.height) : 1
    }
}

/// A detected face, as an ellipse in the upright picture.
struct RelightFaceCue: Sendable {
    /// Centre, upright 0…1.
    let center: SIMD2<Float>
    /// Semi-axes, upright 0…1 of width and height respectively.
    let radii: SIMD2<Float>
    /// In-plane rotation, radians.
    let roll: Float
    /// The tip of the nose, when Vision found one.
    let nose: SIMD2<Float>?
}

/// What Vision could say about one keyframe.
struct RelightSceneCues: Sendable {
    /// Soft subject coverage on the analysis grid, 0…1: people when there are
    /// any, otherwise the foreground object Vision picked out.
    var subject: [Float]
    var faces: [RelightFaceCue]
    var hasPeople: Bool

    static func empty(count: Int) -> RelightSceneCues {
        RelightSceneCues(subject: [Float](repeating: 0, count: count), faces: [], hasPeople: false)
    }

    var subjectCoverage: Float {
        guard !subject.isEmpty else { return 0 }
        return subject.reduce(0, +) / Float(subject.count)
    }
}

/// One estimator's answer for one keyframe.
struct RelightEstimate: Sendable {
    /// Nearness, 0 far … 1 near.
    var depth: [Float]
    var confidence: [Float]
    var estimator: RelightEstimatorKind
    var relief: Float
}

// MARK: - Vision cues

/// People, a foreground object and faces, from Vision, mapped onto the grid.
///
/// The legacy request classes, deliberately: they are the stable surface for
/// a long-lived analysis loop that performs the same requests hundreds of
/// times, and they report into one handler per frame.
final class RelightSceneCueDetector {
    private let personRequest: VNGeneratePersonSegmentationRequest
    private let faceRequest: VNDetectFaceLandmarksRequest
    /// Switched off for the rest of a pass the first time it fails, so a
    /// device that cannot run it does not pay for trying on every keyframe.
    private var objectsAvailable = true

    init() {
        personRequest = VNGeneratePersonSegmentationRequest()
        personRequest.qualityLevel = .balanced
        personRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
        faceRequest = VNDetectFaceLandmarksRequest()
    }

    func detect(image: CVPixelBuffer, grid: RelightAnalysisGrid, includeObjects: Bool) -> RelightSceneCues {
        var cues = RelightSceneCues.empty(count: grid.count)
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: grid.coordinates.orientation,
                                            options: [:])
        do {
            try handler.perform([personRequest, faceRequest])
        } catch {
            return cues
        }
        if let mask = personRequest.results?.first?.pixelBuffer {
            cues.subject = RelightPlaneSampler.uprightPlane(mask, onto: grid)
        }
        cues.hasPeople = cues.subjectCoverage > 0.004
        if !cues.hasPeople, includeObjects, objectsAvailable {
            let request = VNGenerateForegroundInstanceMaskRequest()
            do {
                try handler.perform([request])
                if let observation = request.results?.first {
                    let mask = try observation.generateMask(forInstances: observation.allInstances)
                    let plane = RelightPlaneSampler.uprightPlane(mask, onto: grid)
                    // A "foreground" that is the whole frame is the frame, not
                    // a subject: inflating it would bulge a wall toward the lens.
                    let coverage = plane.reduce(0, +) / Float(max(plane.count, 1))
                    if coverage > 0.004, coverage < 0.85 { cues.subject = plane }
                }
            } catch {
                objectsAvailable = false
            }
        }
        cues.faces = (faceRequest.results ?? []).compactMap { Self.face(from: $0) }
        return cues
    }

    /// Vision reports faces lower-left-origin in the upright image; the cue
    /// is top-left like everything else here.
    private static func face(from observation: VNFaceObservation) -> RelightFaceCue? {
        let box = observation.boundingBox
        guard box.width > 0.01, box.height > 0.01, observation.confidence > 0.3 else { return nil }
        // The box runs brow to chin; the head's form runs higher, so the
        // ellipse is lifted and lengthened a little to take the forehead in.
        let center = SIMD2<Float>(Float(box.midX), Float(1 - box.midY - box.height * 0.08))
        let radii = SIMD2<Float>(Float(box.width * 0.56), Float(box.height * 0.7))
        var nose: SIMD2<Float>?
        if let points = observation.landmarks?.nose?.normalizedPoints, !points.isEmpty {
            let mean = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let px = mean.x / CGFloat(points.count), py = mean.y / CGFloat(points.count)
            nose = SIMD2(Float(box.minX + px * box.width), Float(1 - (box.minY + py * box.height)))
        }
        return RelightFaceCue(center: center, radii: radii,
                              roll: observation.roll.map { Float(truncating: $0) } ?? 0,
                              nose: nose)
    }
}

// MARK: - Built-in geometry

/// Depth built from scene cues on a ground-plane prior.
final class RelightStructuralEstimator {
    /// How strongly this geometry is read as slope by the light kernel.
    static let relief: Float = 1.0

    func estimate(cues: RelightSceneCues, grid: RelightAnalysisGrid) -> RelightEstimate {
        let count = grid.count, width = grid.width, height = grid.height
        var depth = [Float](repeating: 0, count: count)
        var confidence = [Float](repeating: 0.35, count: count)

        // The ground plane: what is low in the frame is usually nearer.
        for index in 0..<count {
            depth[index] = 0.16 + 0.34 * min(max(grid.display[index].y, 0), 1)
        }

        let subject = cues.subject.count == count ? cues.subject : [Float](repeating: 0, count: count)
        let inside = subject.map { $0 > 0.5 }
        let area = inside.reduce(0) { $0 + ($1 ? 1 : 0) }
        if area > 12 {
            // Rounded subjects: depth rises from the silhouette inward along a
            // circular profile, so the surface faces sideways at the edge and
            // toward the camera in the middle — which is exactly what makes a
            // side light wrap round a body instead of washing over it.
            let distance = RelightPlaneSampler.chamferDistance(inside, width: width, height: height)
            let equivalentRadius = (Float(area) / .pi).squareRoot()
            // Most of the way across: a body is round over its whole width,
            // not flat with a rolled edge.
            let profile = min(max(equivalentRadius * 0.85, 3), Float(min(width, height)) * 0.35)
            // The subject stands on the ground where its lowest part is.
            var contacts: [Float] = []
            for index in 0..<count where inside[index] { contacts.append(grid.display[index].y) }
            contacts.sort()
            let contact = contacts[min(contacts.count - 1, Int(Float(contacts.count - 1) * 0.95))]
            let base = min(0.16 + 0.34 * min(max(contact, 0), 1) + 0.2, 0.78)
            for index in 0..<count {
                let s = subject[index]
                guard s > 0.02 else { continue }
                let d = distance[index]
                let t = min(d / profile, 1)
                let dome = (max(0, 1 - (1 - t) * (1 - t))).squareRoot()
                let subjectDepth = base + 0.22 * dome
                let weight = Self.smoothstep(0.25, 0.75, s)
                depth[index] += (subjectDepth - depth[index]) * weight
                // Trusted inside the form, doubted along its soft edge, where
                // hair and motion blur make the matte itself a guess.
                let edge = s > 0.15 && s < 0.85
                confidence[index] = edge ? 0.35 : 0.45 + 0.4 * weight
            }
        }

        RelightFaceGeometry.add(cues.faces, to: &depth, confidence: &confidence,
                                grid: grid, height: 0.12, nose: 0.045, trust: 0.92)

        depth = RelightPlaneSampler.smoothWithinRegions(depth, regions: inside, width: width, height: height, passes: 2)
        RelightPlaneSampler.attenuateBorder(&confidence, width: width, height: height, band: 3, factor: 0.6)
        return RelightEstimate(depth: depth, confidence: confidence,
                               estimator: .structural, relief: Self.relief)
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

/// Face ellipsoids, shared by both estimators: the built-in one draws its
/// faces with them, and the Core ML one adds a little of the same shape back,
/// because a small network at a few hundred pixels tends to flatten a face.
enum RelightFaceGeometry {
    static func add(_ faces: [RelightFaceCue], to depth: inout [Float], confidence: inout [Float],
                    grid: RelightAnalysisGrid, height: Float, nose: Float, trust: Float?) {
        guard !faces.isEmpty else { return }
        let aspect = grid.displayAspect
        for face in faces {
            let rx = max(face.radii.x * aspect, 1e-4), ry = max(face.radii.y, 1e-4)
            let cosine = cos(face.roll), sine = sin(face.roll)
            let noseSigma = max(0.2 * rx, 1e-4)
            for index in 0..<grid.count {
                let p = grid.display[index]
                let dx = (p.x - face.center.x) * aspect, dy = p.y - face.center.y
                let u = (cosine * dx + sine * dy) / rx
                let v = (-sine * dx + cosine * dy) / ry
                let r2 = u * u + v * v
                guard r2 < 1.45 else { continue }
                let weight = RelightStructuralEstimator.smoothstep(1.4, 0.85, r2)
                var bump = height * (max(0, 1 - r2)).squareRoot()
                if let tip = face.nose {
                    let nx = (p.x - tip.x) * aspect, ny = p.y - tip.y
                    bump += nose * exp(-(nx * nx + ny * ny) / (2 * noseSigma * noseSigma))
                }
                depth[index] += bump * weight
                if let trust, r2 < 0.8 { confidence[index] = max(confidence[index], trust) }
            }
        }
    }
}

// MARK: - Core ML depth

/// A monocular depth network, run through Vision.
///
/// Found rather than linked: the app builds and runs without one, and any
/// compiled model whose name mentions depth that takes an image is picked up
/// — from the app bundle, or from Application Support/GradeLab/Models. The
/// output is read as RELATIVE INVERSE depth (larger is nearer), which is what
/// Depth Anything produces; a polarity check against the people in the frame
/// catches a model that disagrees, once, and remembers.
final class RelightCoreMLEstimator {
    /// Higher than the built-in geometry's: a network's relative depth spends
    /// most of its range on the scene's overall recession, which leaves the
    /// relief of a face or a body a small part of it.
    static let relief: Float = 1.8

    let name: String
    private let request: VNCoreMLRequest
    private var polarity: Float?

    private init(name: String, request: VNCoreMLRequest) {
        self.name = name
        self.request = request
    }

    /// The installed depth model, or nil when there is none — in which case
    /// the built-in estimator is used and the panel says how to add one.
    static func loadInstalled() -> RelightCoreMLEstimator? {
        for url in candidateURLs() {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            guard let model = try? MLModel(contentsOf: url, configuration: configuration),
                  model.modelDescription.inputDescriptionsByName.values.contains(where: { $0.type == .image }),
                  let visionModel = try? VNCoreMLModel(for: model) else { continue }
            let request = VNCoreMLRequest(model: visionModel)
            request.imageCropAndScaleOption = .scaleFill
            return RelightCoreMLEstimator(name: url.deletingPathExtension().lastPathComponent, request: request)
        }
        return nil
    }

    /// Whether a depth model is present, without loading it.
    static var isInstalled: Bool { !candidateURLs().isEmpty }

    /// Where an imported, compiled model is kept.
    static var userModelsDirectory: URL? {
        try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            .appendingPathComponent("GradeLab", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private static func candidateURLs() -> [URL] {
        var urls = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
        if let directory = userModelsDirectory,
           let contents = try? FileManager.default.contentsOfDirectory(
               at: directory, includingPropertiesForKeys: nil) {
            urls += contents.filter { $0.pathExtension == "mlmodelc" }
        }
        func rank(_ url: URL) -> Int {
            let name = url.deletingPathExtension().lastPathComponent.lowercased()
            if name.contains("depthanything") { return 0 }
            if name.contains("depthpro") { return 1 }
            return 2
        }
        return urls
            .filter { $0.deletingPathExtension().lastPathComponent.lowercased().contains("depth") }
            .sorted { rank($0) < rank($1) }
    }

    func estimate(image: CVPixelBuffer, cues: RelightSceneCues, luma: [Float],
                  grid: RelightAnalysisGrid) throws -> RelightEstimate {
        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: grid.coordinates.orientation,
                                            options: [:])
        try handler.perform([request])
        let output: RelightPlaneSampler.Plane
        if let observation = request.results?.first as? VNPixelBufferObservation,
           let plane = RelightPlaneSampler.plane(from: observation.pixelBuffer) {
            output = plane
        } else if let observation = request.results?.first as? VNCoreMLFeatureValueObservation,
                  let array = observation.featureValue.multiArrayValue,
                  let plane = RelightPlaneSampler.plane(from: array) {
            output = plane
        } else {
            throw RelightError.message(String(localized: "The depth model returned nothing usable."))
        }

        var depth = RelightPlaneSampler.resample(output, onto: grid)
        let range = RelightTemporalFusion.percentileRange(depth)
        let span = max(range.high - range.low, 1e-4)
        for index in depth.indices { depth[index] = min(max((depth[index] - range.low) / span, 0), 1) }

        // Polarity, decided once: in a frame with people in it, the people
        // are nearer than the frame's edge. A model reporting the opposite is
        // reporting distance rather than nearness, and is read inverted.
        if polarity == nil, cues.hasPeople, cues.subjectCoverage > 0.02 {
            var subject: Float = 0, subjectCount: Float = 0, border: Float = 0, borderCount: Float = 0
            for index in depth.indices {
                let x = index % grid.width, y = index / grid.width
                let atEdge = x < grid.width / 20 || x >= grid.width - grid.width / 20
                    || y < grid.height / 20 || y >= grid.height - grid.height / 20
                if cues.subject[index] > 0.7 { subject += depth[index]; subjectCount += 1 }
                else if atEdge, cues.subject[index] < 0.2 { border += depth[index]; borderCount += 1 }
            }
            if subjectCount > 20, borderCount > 20 {
                polarity = subject / subjectCount + 0.08 < border / borderCount ? -1 : 1
            }
        }
        if polarity == -1 {
            for index in depth.indices { depth[index] = 1 - depth[index] }
        }

        // Confidence from the depth itself: where it changes abruptly the
        // geometry is a boundary or a mistake, and either way not a surface
        // to shade by its slope.
        var confidence = [Float](repeating: 0.88, count: grid.count)
        for y in 0..<grid.height {
            for x in 0..<grid.width {
                let index = y * grid.width + x
                let left = depth[y * grid.width + max(x - 1, 0)]
                let right = depth[y * grid.width + min(x + 1, grid.width - 1)]
                let up = depth[max(y - 1, 0) * grid.width + x]
                let down = depth[min(y + 1, grid.height - 1) * grid.width + x]
                let gradient = max(abs(right - left), abs(down - up)) * 0.5
                confidence[index] *= 1 - 0.6 * RelightStructuralEstimator.smoothstep(0.02, 0.08, gradient)
                if index < luma.count, luma[index] < 0.03 || luma[index] > 0.97 {
                    // Crushed shadows and clipped highlights carry no shape.
                    confidence[index] *= 0.6
                }
            }
        }
        RelightFaceGeometry.add(cues.faces, to: &depth, confidence: &confidence,
                                grid: grid, height: 0.05, nose: 0.02, trust: nil)
        RelightPlaneSampler.attenuateBorder(&confidence, width: grid.width, height: grid.height,
                                            band: 3, factor: 0.7)
        return RelightEstimate(depth: depth, confidence: confidence,
                               estimator: .coreML, relief: Self.relief)
    }
}

// MARK: - Plane helpers

/// Reading single-channel planes out of whatever Vision and Core ML hand back,
/// and moving them between the upright picture and the encoded grid.
enum RelightPlaneSampler {
    struct Plane {
        let width: Int
        let height: Int
        let values: [Float]

        func sample(x: Float, y: Float) -> Float {
            RelightTemporalFusion.bilinear(values, width, height, x, y)
        }
    }

    /// A one-channel pixel buffer as floats: 8-bit, half-float, float and
    /// BGRA (its green channel) are understood.
    static func plane(from buffer: CVPixelBuffer) -> Plane? {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base.advanced(by: y * stride)
            for x in 0..<width {
                let value: Float
                switch format {
                case kCVPixelFormatType_OneComponent8:
                    value = Float(row.load(fromByteOffset: x, as: UInt8.self)) / 255
                case kCVPixelFormatType_OneComponent16Half, kCVPixelFormatType_DepthFloat16,
                     kCVPixelFormatType_DisparityFloat16:
                    value = halfToFloat(row.loadUnaligned(fromByteOffset: x * 2, as: UInt16.self))
                case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32,
                     kCVPixelFormatType_DisparityFloat32:
                    value = row.loadUnaligned(fromByteOffset: x * 4, as: Float.self)
                case kCVPixelFormatType_32BGRA:
                    value = Float(row.load(fromByteOffset: x * 4 + 1, as: UInt8.self)) / 255
                default:
                    return nil
                }
                values[y * width + x] = value.isFinite ? value : 0
            }
        }
        return Plane(width: width, height: height, values: values)
    }

    /// A Core ML output array as a plane: the last two dimensions are taken
    /// as height and width, whatever leading batch or channel dimensions the
    /// model declares.
    static func plane(from array: MLMultiArray) -> Plane? {
        let shape = array.shape.map(\.intValue)
        let strides = array.strides.map(\.intValue)
        guard shape.count >= 2 else { return nil }
        let height = shape[shape.count - 2], width = shape[shape.count - 1]
        let rowStride = strides[strides.count - 2], columnStride = strides[strides.count - 1]
        guard width > 0, height > 0 else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        let pointer = array.dataPointer
        // The slow, general path for an element type read directly below is
        // not known: subscripting by index, leading dimensions at zero.
        var key = [NSNumber](repeating: 0, count: shape.count)
        for y in 0..<height {
            for x in 0..<width {
                let element = y * rowStride + x * columnStride
                let value: Float
                switch array.dataType {
                case .float32:
                    value = pointer.load(fromByteOffset: element * 4, as: Float.self)
                case .double:
                    value = Float(pointer.load(fromByteOffset: element * 8, as: Double.self))
                case .float16:
                    value = halfToFloat(pointer.load(fromByteOffset: element * 2, as: UInt16.self))
                case .int32:
                    value = Float(pointer.load(fromByteOffset: element * 4, as: Int32.self))
                default:
                    key[shape.count - 2] = NSNumber(value: y)
                    key[shape.count - 1] = NSNumber(value: x)
                    value = array[key].floatValue
                }
                values[y * width + x] = value.isFinite ? value : 0
            }
        }
        return Plane(width: width, height: height, values: values)
    }

    /// An upright plane (Vision's orientation-applied output) sampled onto
    /// the encoded analysis grid.
    static func resample(_ plane: Plane, onto grid: RelightAnalysisGrid) -> [Float] {
        var result = [Float](repeating: 0, count: grid.count)
        for index in 0..<grid.count {
            let p = grid.display[index]
            result[index] = plane.sample(x: p.x * Float(plane.width) - 0.5,
                                         y: p.y * Float(plane.height) - 0.5)
        }
        return result
    }

    static func uprightPlane(_ buffer: CVPixelBuffer, onto grid: RelightAnalysisGrid) -> [Float] {
        guard let plane = plane(from: buffer) else { return [Float](repeating: 0, count: grid.count) }
        return resample(plane, onto: grid).map { min(max($0, 0), 1) }
    }

    /// IEEE 754 binary16 to Float, without depending on `Float16`, which is
    /// not available on every architecture this target compiles for.
    static func halfToFloat(_ bits: UInt16) -> Float {
        let sign: UInt32 = UInt32(bits & 0x8000) << 16
        let exponent = Int((bits >> 10) & 0x1F)
        let mantissa = UInt32(bits & 0x03FF)
        if exponent == 0 {
            // Zero or subnormal: mantissa / 1024 * 2^-14, which is 2^-24 per step.
            let magnitude = Float(mantissa) * 5.9604645e-8
            return sign != 0 ? -magnitude : magnitude
        }
        if exponent == 31 {
            return mantissa == 0 ? (sign != 0 ? -.infinity : .infinity) : .nan
        }
        let pattern = sign | UInt32(exponent - 15 + 127) << 23 | mantissa << 13
        return Float(bitPattern: pattern)
    }

    /// Two-pass 3-4 chamfer distance, in pixels, from every inside pixel to
    /// the nearest outside one. Zero outside.
    static func chamferDistance(_ inside: [Bool], width: Int, height: Int) -> [Float] {
        let large: Float = 1e6
        var distance = inside.map { $0 ? large : 0 }
        func at(_ x: Int, _ y: Int) -> Float {
            guard x >= 0, y >= 0, x < width, y < height else { return 0 }
            return distance[y * width + x]
        }
        for y in 0..<height {
            for x in 0..<width where distance[y * width + x] > 0 {
                let best = min(at(x - 1, y) + 3, at(x, y - 1) + 3,
                               at(x - 1, y - 1) + 4, at(x + 1, y - 1) + 4)
                distance[y * width + x] = min(distance[y * width + x], best)
            }
        }
        for y in stride(from: height - 1, through: 0, by: -1) {
            for x in stride(from: width - 1, through: 0, by: -1) where distance[y * width + x] > 0 {
                let best = min(at(x + 1, y) + 3, at(x, y + 1) + 3,
                               at(x + 1, y + 1) + 4, at(x - 1, y + 1) + 4)
                distance[y * width + x] = min(distance[y * width + x], best)
            }
        }
        return distance.map { $0 / 3 }
    }

    /// A 3x3 mean that never crosses between a subject and its background, so
    /// smoothing a form cannot drag the wall behind it forward.
    static func smoothWithinRegions(_ values: [Float], regions: [Bool], width: Int, height: Int,
                                    passes: Int) -> [Float] {
        guard regions.count == values.count, width > 2, height > 2 else { return values }
        var current = values
        for _ in 0..<passes {
            var next = current
            for y in 0..<height {
                for x in 0..<width {
                    let index = y * width + x
                    let region = regions[index]
                    var total: Float = 0, count: Float = 0
                    for dy in -1...1 {
                        let yy = y + dy
                        guard yy >= 0, yy < height else { continue }
                        for dx in -1...1 {
                            let xx = x + dx
                            guard xx >= 0, xx < width, regions[yy * width + xx] == region else { continue }
                            total += current[yy * width + xx]
                            count += 1
                        }
                    }
                    next[index] = count > 0 ? total / count : current[index]
                }
            }
            current = next
        }
        return current
    }

    /// Lowers confidence in a band along the frame edge, where every estimator
    /// is working from half a neighbourhood.
    static func attenuateBorder(_ confidence: inout [Float], width: Int, height: Int, band: Int, factor: Float) {
        guard band > 0 else { return }
        for y in 0..<height {
            for x in 0..<width where x < band || y < band || x >= width - band || y >= height - band {
                confidence[y * width + x] *= factor
            }
        }
    }
}
