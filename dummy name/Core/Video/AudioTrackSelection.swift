@preconcurrency import AVFoundation

/// Chooses the audio presentations that custom readers should process.
///
/// Recent iPhone movies can carry the same recording twice in an alternate
/// group: an enabled stereo fallback and a disabled Spatial Audio track. Those
/// tracks are mutually exclusive presentations, not layers to preserve or mix
/// together. Reading both can duplicate the sound and can make AVAssetReader
/// fail when the disabled multichannel presentation is converted to AAC.
enum AudioTrackSelection {
    static func enabledTracks(from tracks: [AVAssetTrack]) async throws -> [AVAssetTrack] {
        var selected: [AVAssetTrack] = []
        selected.reserveCapacity(tracks.count)
        for track in tracks where try await track.load(.isEnabled) {
            selected.append(track)
        }
        return selected
    }
}
