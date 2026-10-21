@preconcurrency import Metal

extension MTLComputeCommandEncoder {
    /// Preview kernels guard their output bounds, so padded groups are safe.
    /// Device Hub's simulator GPU cannot dispatch nonuniform threadgroups.
    /// Keep the shipping device/Catalyst dispatch unchanged.
    func dispatchPreviewThreads(_ threads: MTLSize, threadsPerThreadgroup group: MTLSize) {
        #if targetEnvironment(simulator)
        dispatchThreadgroups(
            MTLSize(width: (threads.width + group.width - 1) / group.width,
                    height: (threads.height + group.height - 1) / group.height,
                    depth: (threads.depth + group.depth - 1) / group.depth),
            threadsPerThreadgroup: group)
        #else
        dispatchThreads(threads, threadsPerThreadgroup: group)
        #endif
    }
}
