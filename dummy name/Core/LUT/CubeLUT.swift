import Foundation
import simd

struct CubeLUT: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case oneDimensional(size: Int)
        case threeDimensional(size: Int)
    }

    let title: String?
    let kind: Kind
    let domainMinimum: SIMD3<Float>
    let domainMaximum: SIMD3<Float>
    let values: [SIMD3<Float>]
}
