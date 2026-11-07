import SwiftUI
import XCTest
@testable import GradeLab

final class DurationFormattingTests: XCTestCase {
    func testMillisecondsAreExplicitAndCarryIntoSeconds() {
        XCTAssertEqual(DurationText.string(from: 0.60), "600 ms")
        XCTAssertEqual(DurationText.string(from: 0.96), "960 ms")
        XCTAssertEqual(DurationText.string(from: 0.9996), "1 s")
        XCTAssertEqual(DurationText.string(from: 1), "1 s")
        XCTAssertEqual(DurationText.string(from: 1.25), "1 s 250 ms")
        XCTAssertEqual(DurationText.string(from: 1.9996), "2 s")
        XCTAssertEqual(DurationText.string(from: 5), "5 s")
        XCTAssertEqual(DurationText.string(from: 0), "0 s")
        XCTAssertEqual(DurationText.string(from: .nan), "—")
    }

    func testDecimalSecondsExplainTheOriginalFractionWithoutChangingIt() {
        XCTAssertEqual(DurationText.string(from: 0.60, format: .decimalSeconds), "0.60 s")
        XCTAssertEqual(DurationText.string(from: 0.96, format: .decimalSeconds), "0.96 s")
        XCTAssertEqual(DurationText.string(from: 0.9996, format: .decimalSeconds), "1.00 s")
        XCTAssertEqual(DurationText.string(from: 1.25, format: .decimalSeconds), "1.25 s")
        XCTAssertEqual(DurationText.string(from: 1.001, format: .decimalSeconds), "1.001 s")
    }

    func testFrameDurationsUseTheProjectRateAndCarryIntoWholeSeconds() {
        XCTAssertEqual(DurationText.string(from: 0.96, format: .secondsAndFrames, frameRate: 60), "0 s 58 f")
        XCTAssertEqual(DurationText.string(from: 59.0 / 60, format: .secondsAndFrames, frameRate: 60), "0 s 59 f")
        XCTAssertEqual(DurationText.string(from: 0.9996, format: .secondsAndFrames, frameRate: 60), "1 s 00 f")
        XCTAssertEqual(DurationText.string(from: 1.25, format: .secondsAndFrames, frameRate: 24), "1 s 06 f")
        XCTAssertEqual(DurationText.string(from: 1.25, format: .secondsAndFrames, frameRate: 60), "1 s 15 f")
        for rate in [24.0, 25, 29.97, 30, 59.94, 60, 120] {
            XCTAssertEqual(DurationText.string(from: 1, format: .secondsAndFrames, frameRate: rate), "1 s 00 f")
            XCTAssertEqual(DurationText.string(from: 3_600, format: .secondsAndFrames, frameRate: rate), "3600 s 00 f",
                           "A fractional project cadence must not accumulate display drift.")
        }
    }

    func testFramePreferenceDoesNotInventAnUnknownRate() {
        for rate: Double? in [nil, .nan, .infinity, 0, -30, 1_001] {
            XCTAssertEqual(DurationText.string(from: 0.96, format: .secondsAndFrames, frameRate: rate), "960 ms")
        }
    }

    func testDisplayChoicePersistsAcrossProjectsAndReopening() throws {
        let domain = "GradeLab.DurationDisplayTests.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { store.removePersistentDomain(forName: domain) }
        let choice = AppStorage(wrappedValue: DurationDisplayFormat.defaultValue,
                                DurationDisplayFormat.preferenceKey, store: store)
        XCTAssertEqual(choice.wrappedValue, .secondsAndMilliseconds)
        for format in DurationDisplayFormat.allCases {
            choice.wrappedValue = format
            let reopened = AppStorage(wrappedValue: DurationDisplayFormat.defaultValue,
                                      DurationDisplayFormat.preferenceKey, store: store)
            XCTAssertEqual(reopened.wrappedValue, format)
        }
        store.set("future-format", forKey: DurationDisplayFormat.preferenceKey)
        let unknown = AppStorage(wrappedValue: DurationDisplayFormat.defaultValue,
                                 DurationDisplayFormat.preferenceKey, store: store)
        XCTAssertEqual(unknown.wrappedValue, .secondsAndMilliseconds)
    }

    func testDraggingSnapsNearWholeSecondsAndKeepsFineControlBetweenThem() {
        let stops = [1.0, 2, 3, 4, 5]
        for second in stops {
            XCTAssertEqual(SliderSnap.value(second - 0.04, in: 0.1...5, points: stops), second)
            XCTAssertEqual(SliderSnap.value(second + 0.04, in: 0.1...5, points: stops), second)
        }
        XCTAssertEqual(SliderSnap.value(2.2, in: 0.1...5, points: stops), 2.2)
        XCTAssertEqual(SliderSnap.value(2.59, in: 0.1...2.6, points: stops), 2.59)
        XCTAssertEqual(SliderSnap.value(2.04, in: 0.1...5, points: []), 2.04)
    }

    func testFiveSecondAnimationStillRunsAfterTwoSecondsAndFitsShortClips() throws {
        var settings = TextAnimationSettings()
        settings.incoming = .fadeIn
        settings.incomingDuration = try .seconds(5)
        let contribution = TextAnimator.contribution(settings, elapsed: 2.5, duration: 12, fontSize: 100, clusters: 5)
        XCTAssertGreaterThan(contribution.opacity, 0)
        XCTAssertLessThan(contribution.opacity, 1, "A 5-second entrance must not finish at the old 2-second limit.")
        settings.outgoing = .fadeOut
        settings.outgoingDuration = try .seconds(5)
        let windows = TextAnimator.windows(settings, duration: 6)
        XCTAssertEqual(windows.incoming, 3, accuracy: 0.00001)
        XCTAssertEqual(windows.outgoing, 3, accuracy: 0.00001)
        XCTAssertEqual(try JSONDecoder().decode(TextAnimationSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testTransitionsAllowFiveSecondsAndStillRespectSourceHandles() throws {
        var project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/duration-transition.mov"),
                                   displayName: "Duration", metadata: makeVideoMetadata(durationSeconds: 30))
        _ = try TimelineEditing.split(project.timeline.firstVideoClip!.id, at: .seconds(15), in: &project)
        let id = try TimelineTransitionEditing.apply(.crossDissolve, at: .seconds(15), preferredTrackID: nil, in: &project)
        try TimelineTransitionEditing.setDuration(id, seconds: 5, in: &project)
        XCTAssertEqual(project.timeline.transitions.first?.duration.seconds ?? -1, 5, accuracy: 0.00001)
        try project.validate()
        let reopened = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(project))
        XCTAssertEqual(reopened.timeline.transitions.first?.duration, try .seconds(5))

        var short = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/short-transition.mov"),
                                 displayName: "Short", metadata: makeVideoMetadata(durationSeconds: 2))
        _ = try TimelineEditing.split(short.timeline.firstVideoClip!.id, at: .seconds(1), in: &short)
        let shortID = try TimelineTransitionEditing.apply(.crossDissolve, at: .seconds(1), preferredTrackID: nil, in: &short)
        try TimelineTransitionEditing.setDuration(shortID, seconds: 5, in: &short)
        XCTAssertLessThanOrEqual(short.timeline.transitions.first!.duration.seconds, 2)
        try short.validate()
    }
}

@MainActor
final class TextAnimationDurationTests: XCTestCase {
    private func model(duration: Double = 10) throws -> EditorViewModel {
        let project = VideoProject(sourceURL: URL(fileURLWithPath: "/tmp/duration-text.mov"),
                                   displayName: "Duration", metadata: makeVideoMetadata(durationSeconds: 30))
        let model = try EditorViewModel(project: project)
        model.suspendPreviewForExport()
        model.addText()
        model.suspendPreviewForExport()
        model.editText(immediate: true) {
            $0.placement.duration = try! .seconds(duration)
            var settings = TextAnimationSettings()
            settings.incoming = .fadeIn
            settings.outgoing = .fadeOut
            $0.textAnimation = settings
        }
        return model
    }

    func testFiveSecondsPersistsAndExactEntryDoesNotSnap() throws {
        let model = try model()
        XCTAssertEqual(model.textAnimationDurationLimit, 5)
        model.setTextAnimationDuration(5, for: .incoming, immediate: true)
        model.setTextAnimationDuration(4, for: .outgoing, immediate: true)
        let reopened = try JSONDecoder().decode(VideoProject.self, from: JSONEncoder().encode(model.project))
        guard case .text(let text) = reopened.timeline.item(id: model.selectedClipID!) else { return XCTFail("Missing title") }
        XCTAssertEqual(text.textAnimation?.incomingDuration, try .seconds(5))
        XCTAssertEqual(text.textAnimation?.outgoingDuration, try .seconds(4))
        model.setTextAnimationDuration(2.04, for: .incoming, immediate: true)
        XCTAssertEqual(model.textAnimationSettings.incomingDuration.seconds, 2.04, accuracy: 0.00001)
        model.setTextAnimationDuration(8, for: .incoming, immediate: true)
        XCTAssertEqual(model.textAnimationSettings.incomingDuration.seconds, 5, accuracy: 0.00001)
    }

    func testShortClipKeepsItsDurationLimit() throws {
        let model = try model(duration: 1.5)
        model.setTextAnimationDuration(5, for: .incoming, immediate: true)
        XCTAssertEqual(model.textAnimationDurationLimit, 1.5)
        XCTAssertEqual(model.textAnimationSettings.incomingDuration.seconds, 1.5, accuracy: 0.00001)
    }

    func testOneDragWithAPauseCreatesOneUndoEntry() async throws {
        let model = try model()
        model.setTextAnimationEditing(true)
        model.setTextAnimationDuration(2, for: .incoming)
        try await Task.sleep(for: .milliseconds(750))
        model.setTextAnimationDuration(5, for: .incoming)
        model.setTextAnimationEditing(false)
        model.undo()
        XCTAssertEqual(model.textAnimationSettings.incomingDuration, TextAnimationSettings.defaultDuration)
        model.redo()
        XCTAssertEqual(model.textAnimationSettings.incomingDuration, try .seconds(5))
    }
}

@MainActor
final class DurationControlLayoutTests: XCTestCase {
    func testOpenControlUpdatesItsLabelWithoutEditingTheDuration() throws {
        let domain = "GradeLab.DurationControlLivePreference.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { store.removePersistentDomain(forName: domain) }
        var edits = 0
        let row = DurationSliderRow(value: 0.96, range: 0.1...5, reset: 0.5, frameRate: 60,
                                    change: { _ in edits += 1 }, commit: { _ in edits += 1 },
                                    onEditingChanged: { _ in })
            .padding(20).background(AppColors.editorBackground).preferredColorScheme(.dark)
            .numericEntryHost().defaultAppStorage(store)
        let controller = UIHostingController(rootView: row)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        let size = CGSize(width: 320, height: 260)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds

        func snapshot() throws -> Data {
            window.layoutIfNeeded()
            let end = Date().addingTimeInterval(0.3)
            while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(size: size).image { controller.view.layer.render(in: $0.cgContext) }
            return try XCTUnwrap(image.pngData())
        }

        let milliseconds = try snapshot()
        store.set(DurationDisplayFormat.decimalSeconds.rawValue, forKey: DurationDisplayFormat.preferenceKey)
        let decimal = try snapshot()
        store.set(DurationDisplayFormat.secondsAndFrames.rawValue, forKey: DurationDisplayFormat.preferenceKey)
        let frames = try snapshot()
        XCTAssertNotEqual(milliseconds, decimal, "An open duration control must refresh when Settings changes.")
        XCTAssertNotEqual(decimal, frames)
        XCTAssertEqual(edits, 0, "A display preference must not create an edit or undo entry.")
    }

    func testNarrowAndWideDurationControlsFit() throws {
        let domain = "GradeLab.DurationControlLayout.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { store.removePersistentDomain(forName: domain) }
        for format in DurationDisplayFormat.allCases {
            store.set(format.rawValue, forKey: DurationDisplayFormat.preferenceKey)
            for width: CGFloat in [280, 540] {
                let row = DurationSliderRow(value: 1.96, range: 0.1...5, reset: 0.5,
                                            frameRate: 60,
                                            snapPoints: DurationSliderRow.wholeSecondSnapPoints,
                                            change: { _ in }, commit: { _ in }, onEditingChanged: { _ in })
                    .padding(20).background(AppColors.editorBackground).preferredColorScheme(.dark)
                    .numericEntryHost().defaultAppStorage(store)
                let controller = UIHostingController(rootView: row)
                let fitting = controller.sizeThatFits(in: CGSize(width: width, height: 1_000))
                XCTAssertLessThanOrEqual(fitting.width, width + 1)
                let size = CGSize(width: width, height: max(160, fitting.height))
                let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
                let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
                window.frame = CGRect(origin: .zero, size: size)
                window.rootViewController = controller
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                controller.view.frame = CGRect(origin: .zero, size: size)
                window.layoutIfNeeded()
                let end = Date().addingTimeInterval(0.3)
                while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
                controller.view.layoutIfNeeded()
                let image = UIGraphicsImageRenderer(size: size).image { controller.view.layer.render(in: $0.cgContext) }
                let attachment = XCTAttachment(image: image)
                attachment.name = "duration-control-\(Int(width))-\(format.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
                if let png = image.pngData() {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("duration-control-\(Int(width))-\(format.rawValue).png")
                    try png.write(to: url)
                    print("DURATION_CONTROL_SHOT \(url.path)")
                }
            }
        }
    }
}

@MainActor
final class DurationDisplaySettingsLayoutTests: XCTestCase {
    func testOptionsFitNarrowAndWideSettings() throws {
        try render(width: 320, textSize: .large, frameRate: 60, name: "duration-settings-phone")
        try render(width: 540, textSize: .large, frameRate: 24, name: "duration-settings-wide")
    }

    func testOptionsScrollAtLargeTextSizesWithAnUnknownRate() throws {
        try render(width: 320, height: 600, textSize: .accessibility2, frameRate: nil, name: "duration-settings-large-text")
    }

    private func render(width: CGFloat, height: CGFloat = 900, textSize: DynamicTypeSize, frameRate: Double?, name: String) throws {
        let domain = "GradeLab.DurationSettingsLayout.\(UUID())"
        let store = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { store.removePersistentDomain(forName: domain) }
        let root = NavigationStack { DurationDisplaySettings(frameRate: frameRate) }
            .defaultAppStorage(store).dynamicTypeSize(textSize).preferredColorScheme(.dark)
        let controller = UIHostingController(rootView: root)
        let size = CGSize(width: width, height: height)
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: .zero)
        window.frame = CGRect(origin: .zero, size: size)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        window.layoutIfNeeded()
        let end = Date().addingTimeInterval(0.4)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        controller.view.layoutIfNeeded()
        let scroll = try XCTUnwrap(scrollViews(in: controller.view).first)
        XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
        if textSize.isAccessibilitySize {
            let viewport = scroll.bounds.height - scroll.adjustedContentInset.top - scroll.adjustedContentInset.bottom
            XCTAssertGreaterThan(scroll.contentSize.height, viewport, "All options remain reachable by scrolling.")
        }
        let image = UIGraphicsImageRenderer(size: size).image { controller.view.layer.render(in: $0.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("\(name).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        print("DURATION_SETTINGS_SHOT \(url.path)")
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
