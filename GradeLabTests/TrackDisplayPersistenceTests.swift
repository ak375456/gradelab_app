import XCTest
@testable import GradeLab

/// Row height and waveform size used to live in two `@State` dictionaries in
/// `EditorView`, keyed by track id. They were never written anywhere, so
/// closing the app discarded them and every row came back Regular. They are
/// document properties now, on the track itself.
final class TrackDisplayPersistenceTests: XCTestCase {
    private func project() -> VideoProject {
        .init(sourceURL: URL(fileURLWithPath: "/tmp/track-display.mov"),
              displayName: "Rows", metadata: makeVideoMetadata(durationSeconds: 10))
    }

    func testAChosenHeightSurvivesTheDocumentRoundTrip() throws {
        var p = project()
        p.timeline.tracks[0].heightChoice = .compact
        p.timeline.tracks[0].waveformSize = .large

        let reopened = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(reopened.timeline.tracks[0].heightChoice, .compact)
        XCTAssertEqual(reopened.timeline.tracks[0].waveformSize, .large)
        XCTAssertEqual(reopened, p)
    }

    /// The default is absence, not a stored "Regular": a project nobody has
    /// touched writes no key at all, so the whole class of older document keeps
    /// decoding.
    func testATrackWrittenBeforeRowHeightsStillDecodes() throws {
        let p = project()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        var timeline = json["timeline"] as! [String: Any]
        var tracks = timeline["tracks"] as! [[String: Any]]
        for index in tracks.indices {
            tracks[index].removeValue(forKey: "heightChoice")
            tracks[index].removeValue(forKey: "waveformSize")
        }
        timeline["tracks"] = tracks
        json["timeline"] = timeline

        let data = try JSONSerialization.data(withJSONObject: json)
        let decoded = try JSONDecoder().decode(VideoProject.self, from: data)
        XCTAssertNil(decoded.timeline.tracks[0].heightChoice)
        XCTAssertEqual(decoded.timeline.tracks[0].resolvedHeight, .regular)
        XCTAssertEqual(decoded.timeline.tracks[0].resolvedWaveformSize, .medium)
        try decoded.validate()
    }

    /// A project nobody has resized must not start writing the key, or the
    /// check above stops testing anything.
    func testAnUntouchedProjectWritesNoRowHeightKey() throws {
        let encoded = String(data: try JSONEncoder().encode(project()), encoding: .utf8)!
        XCTAssertFalse(encoded.contains("heightChoice"))
        XCTAssertFalse(encoded.contains("waveformSize"))
    }

    /// The stored value is English in every language, like `defaultName`: it is
    /// the document representation, and a project made in one language has to
    /// open in another.
    func testTheStoredValueIsTheEnglishRawValue() {
        XCTAssertEqual(TimelineTrackHeightChoice.compact.rawValue, "Compact")
        XCTAssertEqual(TimelineTrackHeightChoice.regular.rawValue, "Regular")
        XCTAssertEqual(TimelineTrackHeightChoice.tall.rawValue, "Tall")
        XCTAssertEqual(TimelineWaveformSize.small.rawValue, "Small")
        XCTAssertEqual(TimelineWaveformSize.medium.rawValue, "Medium")
        XCTAssertEqual(TimelineWaveformSize.large.rawValue, "Large")
        // Every case has to be reachable from what was written.
        for choice in TimelineTrackHeightChoice.allCases {
            XCTAssertEqual(TimelineTrackHeightChoice(rawValue: choice.rawValue), choice)
        }
        for size in TimelineWaveformSize.allCases {
            XCTAssertEqual(TimelineWaveformSize(rawValue: size.rawValue), size)
        }
    }

    /// Compact really is shorter than regular, and drawn-overlay rows stay
    /// shorter than media rows at every setting — the reason the choice exists.
    func testEachHeightMeasuresWhatItSays() {
        for kind in [TimelineTrack.Kind.mainVideo, .audio, .text] {
            let compact = TimelineTrackHeightChoice.compact.points(for: kind)
            let regular = TimelineTrackHeightChoice.regular.points(for: kind)
            let tall = TimelineTrackHeightChoice.tall.points(for: kind)
            XCTAssertLessThan(compact, regular, "\(kind)")
            XCTAssertLessThan(regular, tall, "\(kind)")
        }
    }
}
