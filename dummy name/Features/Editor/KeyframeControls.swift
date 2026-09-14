import SwiftUI
import UIKit

// MARK: - Diamond

/// The keyframe toggle that sits beside every animatable property.
///
/// Three states are distinguished by SHAPE, not colour alone:
///   off          hollow diamond, thin stroke
///   animated     hollow diamond with a centre dot (animated, but not on this frame)
///   onKeyframe   solid diamond
/// The visible icon stays compact while the touch target is a full 44 x 44.
struct KeyframeDiamond: View {
    let state: EditorViewModel.KeyframeState
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            KeyframeDiamondIcon(state: state)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel("\(title) keyframe")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(state == .onKeyframe ? "Removes the keyframe here" : "Adds a keyframe here")
        .accessibilityAddTraits(state == .onKeyframe ? .isSelected : [])
    }

    private var accessibilityValue: String {
        switch state {
        case .off: "Not animated"
        case .animated: "Animated, no keyframe at the playhead"
        case .onKeyframe: "Keyframe at the playhead"
        }
    }
}

/// The diamond artwork on its own, so the guide can show the real thing rather than a mock-up.
struct KeyframeDiamondIcon: View {
    let state: EditorViewModel.KeyframeState
    var size: CGFloat = 13
    private var tint: Color { state == .off ? AppColors.textSecondary : AppColors.accent }
    var body: some View {
        ZStack {
            Diamond().stroke(tint, lineWidth: state == .onKeyframe ? 0 : size/9)
                .frame(width: size, height: size)
            if state == .onKeyframe { Diamond().fill(tint).frame(width: size, height: size) }
            if state == .animated { Circle().fill(tint).frame(width: size/3.2, height: size/3.2) }
        }
    }
}

struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.closeSubpath()
        }
    }
}

// MARK: - First-time guidance

/// Shown once, dismissible, never repeated. The help action below repeats on demand.
struct KeyframeHint: View {
    @AppStorage("keyframes.hintDismissed") private var dismissed = false
    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "diamond").font(.caption2).foregroundStyle(AppColors.accent).padding(.top, 2)
                Text("Add a keyframe, move the playhead, then change the value.")
                    .font(.caption2).foregroundStyle(AppColors.textSecondary)
                Spacer(minLength: 0)
                Button { dismissed = true } label: {
                    Image(systemName: "xmark").font(.caption2).frame(width: 32, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Dismiss keyframe tip")
            }
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(AppColors.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The one explanation of keyframes, shown from the editor's help button and from Settings.
struct KeyframeGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 8) {
                Text("A keyframe pins a value to one moment")
                    .font(.title3.weight(.semibold))
                Text("Set a value at two different moments and the property moves smoothly between them. That is all animation is here.")
                    .font(.subheadline).foregroundStyle(AppColors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Animate anything in three steps").font(.subheadline.weight(.semibold))
                step(1, "Park the playhead", "Move to where the motion should begin.")
                step(2, "Tap the diamond", "That saves the value you can see right now.")
                step(3, "Move and change", "Go to a later moment and change the value. The next keyframe appears by itself.")
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("What the diamond is telling you").font(.subheadline.weight(.semibold))
                legend(.off, "Not animated", "This value stays the same for the whole clip. Changing it just changes the value.")
                legend(.animated, "Animating, but not here", "There are keyframes elsewhere. Tap to add one at the playhead.")
                legend(.onKeyframe, "A keyframe is here", "Tap to delete this one keyframe. Other properties are untouched.")
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Shaping and undoing it").font(.subheadline.weight(.semibold))
                row("list.bullet.below.rectangle", "Tap a property's name",
                    "Opens its lane. Tap a keyframe to jump to it, drag it sideways to retime it, and pick Linear, Hold or an ease.")
                row("arrow.uturn.backward", "Remove animation",
                    "Stops the property animating and keeps the value you can currently see.")
                row("arrow.counterclockwise", "Reset",
                    "Puts the property back to its default and clears its keyframes. Double-tapping the slider resets the value only.")
                row("scissors", "It travels with the clip",
                    "Move, copy or split a clip and its animation comes along. What you see in the preview is what you export.")
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.black)
                .frame(width: 22, height: 22).background(Circle().fill(AppColors.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func legend(_ state: EditorViewModel.KeyframeState, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            KeyframeDiamondIcon(state: state, size: 16).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.caption).foregroundStyle(AppColors.accent)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(AppColors.textSecondary)
            }
        }
    }
}

struct KeyframeHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView { KeyframeGuide().padding(20) }
                .navigationTitle("Keyframes").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
        }.preferredColorScheme(.dark)
    }
}

// MARK: - Property lane

/// Compact strip showing one property's keyframes across the selected clip.
/// Deliberately small so the video preview stays visible while animating.
struct KeyframeLane: View {
    @ObservedObject var model: EditorViewModel
    let property: AnimatableProperty
    @Binding var selectedLocal: TimelineTime?

    @State private var dragOrigin: TimelineTime?
    @State private var dragTime: Double?
    @State private var horizontal: Bool?
    @State private var lastFeedbackFrame: Int64?

    private var clip: AnimationSnapshot? { model.animationSelection }
    private var start: Double { clip?.placement.timelineStart.seconds ?? 0 }
    private var end: Double { (try? clip?.placement.range.end.seconds) ?? 1 }
    private var span: Double { max(0.0001, end - start) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                let width = max(1, geometry.size.width)
                let keyframes = model.visibleKeyframes(property)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.09)).frame(height: 3)
                    // Playhead
                    Rectangle().fill(.white.opacity(0.85)).frame(width: 1.5, height: 22)
                        .offset(x: x(for: model.timelineTime, width: width) - 0.75)
                    ForEach(keyframes.indices, id: \.self) { index in
                        let frame = keyframes[index]
                        let dragging = dragOrigin == frame.local
                        let seconds = dragging ? (dragTime ?? frame.timeline.seconds) : frame.timeline.seconds
                        let chosen = selectedLocal == frame.local
                        Diamond()
                            .fill(chosen || dragging ? AppColors.accent : Color.white.opacity(0.85))
                            .overlay(Diamond().stroke(.black.opacity(0.6), lineWidth: 0.5))
                            .frame(width: chosen || dragging ? 13 : 10, height: chosen || dragging ? 13 : 10)
                            .offset(x: x(for: seconds, width: width) - (chosen || dragging ? 6.5 : 5))
                    }
                }
                .frame(height: 30)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                // A tap selects the nearest keyframe and seeks precisely to it.
                .onTapGesture { location in
                    guard let nearest = nearestKeyframe(to: location.x, width: width) else { return }
                    selectedLocal = nearest.local
                    UISelectionFeedbackGenerator().selectionChanged()
                    model.playback.pause()
                    model.playback.seekPrecisely(to: nearest.timeline.cmTime)
                }
                // A horizontal drag STARTING ON a keyframe retimes it; anywhere else it
                // scrubs the playhead, which is how time is scrubbed in Transform mode where
                // the main timeline is hidden. A vertical drag is left to the inspector's
                // scroll view, so scrolling can never nudge a keyframe.
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            if horizontal == nil {
                                horizontal = abs(value.translation.width) >= abs(value.translation.height)
                                if horizontal == true {
                                    let nearest = nearestKeyframe(to: value.startLocation.x, width: width)
                                    dragOrigin = nearest?.local
                                    if nearest != nil { selectedLocal = nearest?.local }
                                    model.playback.pause()
                                    if nearest == nil { model.playback.beginSeeking() }
                                }
                            }
                            guard horizontal == true else { return }
                            let seconds = min(end, max(start, start + Double(value.location.x / width) * span))
                            feedback(seconds)
                            guard let origin = dragOrigin else {
                                model.seekTimeline(to: seconds, finishing: false); return
                            }
                            dragTime = seconds
                            apply(origin: origin, seconds: seconds, committing: false)
                        }
                        .onEnded { value in
                            if horizontal == true {
                                let seconds = min(end, max(start, start + Double(value.location.x / width) * span))
                                if let origin = dragOrigin, let dragged = dragTime {
                                    apply(origin: origin, seconds: dragged, committing: true)
                                    // The keyframe may have been clamped short of the request.
                                    selectedLocal = clip?.localTime(for: (try? .seconds(dragged)) ?? .zero)
                                        .flatMap { requested in
                                            model.visibleKeyframes(property)
                                                .min { abs($0.local.seconds - requested.seconds) < abs($1.local.seconds - requested.seconds) }?.local
                                        }
                                } else {
                                    model.seekTimeline(to: seconds, finishing: true)
                                }
                            }
                            horizontal = nil; dragOrigin = nil; dragTime = nil; lastFeedbackFrame = nil
                        }
                )
            }.frame(height: 30)

            HStack(spacing: 10) {
                if let dragTime {
                    Text(TimecodeFormatter.string(from: dragTime)).font(.caption2.monospacedDigit()).foregroundStyle(AppColors.accent)
                } else {
                    Text("\(model.visibleKeyframes(property).count) keyframes").font(.caption2).foregroundStyle(AppColors.textSecondary)
                }
                Spacer(minLength: 0)
                // Asked of the model rather than read off the clip: a grading
                // keyframe may live on the selected mask instead, and the lane
                // must not know or care which.
                if let selectedLocal, let keyframe = model.keyframe(property, atLocal: selectedLocal) {
                    Menu {
                        ForEach(KeyframeInterpolation.allCases, id: \.self) { mode in
                            Button {
                                model.setKeyframeInterpolation(mode, property: property, atLocal: selectedLocal)
                            } label: {
                                Label(mode.title, systemImage: keyframe.interpolation == mode ? "checkmark" : mode.symbol)
                            }
                        }
                    } label: {
                        Label(keyframe.interpolation.title, systemImage: "slider.horizontal.below.square.filled.and.square")
                            .font(.caption2).frame(minHeight: 32)
                    }.accessibilityLabel("Curve after this keyframe")
                    Button(role: .destructive) {
                        model.removeKeyframe(property, atLocal: selectedLocal)
                        self.selectedLocal = nil
                    } label: { Image(systemName: "trash").font(.caption2).frame(width: 32, height: 32).contentShape(Rectangle()) }
                        .buttonStyle(.plain).accessibilityLabel("Delete selected keyframe")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(property.title) keyframes")
    }

    private func x(for seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat((min(end, max(start, seconds)) - start) / span) * width
    }
    private func nearestKeyframe(to x: CGFloat, width: CGFloat) -> (local: TimelineTime, timeline: TimelineTime)? {
        let keyframes = model.visibleKeyframes(property)
        guard let nearest = keyframes.min(by: {
            abs(self.x(for: $0.timeline.seconds, width: width) - x) < abs(self.x(for: $1.timeline.seconds, width: width) - x)
        }) else { return nil }
        return abs(self.x(for: nearest.timeline.seconds, width: width) - x) <= 22 ? nearest : nil
    }
    private func apply(origin: TimelineTime, seconds: Double, committing: Bool) {
        guard let clip, let requested = try? TimelineTime.seconds(seconds),
              let local = clip.localTime(for: requested) else { return }
        model.moveKeyframe(property, from: origin, to: local, committing: committing)
        if committing { return }
        // Track the keyframe as it moves so the next change starts from where it landed.
        if let landed = model.visibleKeyframes(property).min(by: {
            abs($0.local.seconds - local.seconds) < abs($1.local.seconds - local.seconds)
        })?.local { dragOrigin = landed; selectedLocal = landed }
    }
    /// One tick per frame boundary crossed, not a continuous buzz.
    private func feedback(_ seconds: Double) {
        let frame = model.project.canvas.frameDuration?.seconds ?? 1.0/30
        let index = Int64((seconds / max(0.0001, frame)).rounded())
        if index != lastFeedbackFrame {
            if lastFeedbackFrame != nil { UISelectionFeedbackGenerator().selectionChanged() }
            lastFeedbackFrame = index
        }
    }
}

// MARK: - Property row

/// Label + diamond + value + slider, with the lane and keyframe actions revealed when the
/// property is the active one. Only one property is expanded at a time so the preview stays
/// visible on a phone.
struct KeyframePropertyRow: View {
    @ObservedObject var model: EditorViewModel
    let property: AnimatableProperty
    let range: ClosedRange<Double>
    @Binding var activeProperty: AnimatableProperty?
    @Binding var selectedKeyframe: TimelineTime?
    var displayScale: Double = 1
    var suffix = ""

    private var isActive: Bool { activeProperty == property }
    private var state: EditorViewModel.KeyframeState { model.keyframeState(property) }
    private var inRange: Bool { model.isPlayheadInsideSelection }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    activeProperty = isActive ? nil : property
                    selectedKeyframe = nil
                } label: {
                    HStack(spacing: 4) {
                        Text(property.title).font(.caption)
                            .foregroundStyle(isActive ? AppColors.accent : AppColors.textPrimary)
                        if state != .off {
                            Image(systemName: isActive ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8)).foregroundStyle(AppColors.textSecondary)
                        }
                    }.frame(minHeight: 36).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(property.title) options")
                .accessibilityValue(state == .off ? "Not animated" : "Animated")
                Spacer(minLength: 4)
                NumericEntryLabel(title: property.title,
                                  text: (model.animatableNumber(property).wrappedValue * displayScale)
                                    .formatted(.number.precision(.fractionLength(0...2))) + suffix,
                                  value: model.animatableNumber(property).wrappedValue * displayScale,
                                  range: (range.lowerBound * displayScale)...(range.upperBound * displayScale),
                                  tint: .primary) { typed in
                    model.setAnimatableValue(property, .number(typed / displayScale), immediate: true)
                }
                .font(.caption.monospacedDigit())
                // An animated value can only be changed at a frame the clip occupies.
                .disabled(state != .off && !inRange)
                .opacity(state != .off && !inRange ? 0.35 : 1)
                KeyframeDiamond(state: state, title: property.title, enabled: inRange && model.canEditSelection) {
                    model.toggleKeyframe(property)
                }
            }
            // Double-tap sends the property back to its default. On an animated property
            // that writes a keyframe, exactly like any other value change; the Animation menu
            // is what clears the animation as well.
            ResettableSlider(value: model.animatableNumber(property), range: range,
                             resetValue: property.defaultValue.number ?? 0, label: property.title,
                             onEditingChanged: { editing in if !editing { model.flushGradeHistory() } },
                             onReset: { model.setAnimatableValue(property, property.defaultValue, immediate: true) })
                .disabled(state != .off && !inRange)

            if isActive {
                if state == .off {
                    Text("Tap the diamond to start animating \(property.title.lowercased()).")
                        .font(.caption2).foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                } else {
                    KeyframeLane(model: model, property: property, selectedLocal: $selectedKeyframe)
                    KeyframeNavigator(model: model, property: property, selectedKeyframe: $selectedKeyframe)
                }
            }
        }
    }
}

/// Colour variant of the property row. Same rules, same lane, same diamond.
struct KeyframeColorRow: View {
    @ObservedObject var model: EditorViewModel
    let property: AnimatableProperty
    @Binding var activeProperty: AnimatableProperty?
    @Binding var selectedKeyframe: TimelineTime?

    private var isActive: Bool { activeProperty == property }
    private var state: EditorViewModel.KeyframeState { model.keyframeState(property) }
    private var inRange: Bool { model.isPlayheadInsideSelection }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button {
                    activeProperty = isActive ? nil : property
                    selectedKeyframe = nil
                } label: {
                    HStack(spacing: 4) {
                        Text(property.title).font(.caption)
                            .foregroundStyle(isActive ? AppColors.accent : AppColors.textPrimary)
                        if state != .off {
                            Image(systemName: isActive ? "chevron.down" : "chevron.right")
                                .font(.system(size: 8)).foregroundStyle(AppColors.textSecondary)
                        }
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(property.title) options")
                Spacer(minLength: 4)
                ColorPicker("", selection: colorBinding, supportsOpacity: true)
                    .labelsHidden()
                    .disabled(state != .off && !inRange)
                    .opacity(state != .off && !inRange ? 0.35 : 1)
                    .accessibilityLabel(property.title)
                KeyframeDiamond(state: state, title: property.title, enabled: inRange && model.canEditSelection) {
                    model.toggleKeyframe(property)
                }
            }
            if isActive {
                if state == .off {
                    Text("Tap the diamond to start animating \(property.title.lowercased()).")
                        .font(.caption2).foregroundStyle(AppColors.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                } else {
                    KeyframeLane(model: model, property: property, selectedLocal: $selectedKeyframe)
                    KeyframeNavigator(model: model, property: property, selectedKeyframe: $selectedKeyframe)
                }
            }
        }
    }

    private var colorBinding: Binding<Color> {
        let source = model.animatableColor(property)
        return Binding(get: {
            let c = source.wrappedValue
            return Color(.sRGB, red: c.red, green: c.green, blue: c.blue, opacity: c.alpha)
        }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            model.setAnimatableValue(property, .color(.init(red: r, green: g, blue: b, alpha: a)), immediate: true)
        })
    }
}

/// Previous/next keyframe plus the per-property animation actions.
struct KeyframeNavigator: View {
    @ObservedObject var model: EditorViewModel
    let property: AnimatableProperty
    @Binding var selectedKeyframe: TimelineTime?

    var body: some View {
        HStack(spacing: 4) {
            Button { model.seekToKeyframe(property, forward: false) } label: {
                Image(systemName: "chevron.left.to.line").font(.caption).frame(width: 40, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.keyframeNeighbour(property, forward: false) == nil)
            .opacity(model.keyframeNeighbour(property, forward: false) == nil ? 0.3 : 1)
            .accessibilityLabel("Previous \(property.title) keyframe")

            Button { model.seekToKeyframe(property, forward: true) } label: {
                Image(systemName: "chevron.right.to.line").font(.caption).frame(width: 40, height: 36).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.keyframeNeighbour(property, forward: true) == nil)
            .opacity(model.keyframeNeighbour(property, forward: true) == nil ? 0.3 : 1)
            .accessibilityLabel("Next \(property.title) keyframe")

            Spacer(minLength: 0)
            Menu {
                Button("Remove animation") { model.removeAnimation(of: property); selectedKeyframe = nil }
                Button("Reset \(property.title)", role: .destructive) { model.resetProperty(property); selectedKeyframe = nil }
            } label: {
                Text("Animation").font(.caption2).frame(minHeight: 36)
            }.accessibilityLabel("\(property.title) animation actions")
        }
    }
}

/// The header shared by every panel that offers keyframes.
struct KeyframeSectionHeader: View {
    @ObservedObject var model: EditorViewModel
    @Binding var help: Bool
    @Binding var confirmsRemoveAll: Bool
    var body: some View {
        VStack(spacing: 2) {
            KeyframeHint()
            if !model.isPlayheadInsideSelection { KeyframeOutOfRangeNotice(model: model) }
            HStack(spacing: 4) {
                Text("Animation").font(.caption2.weight(.semibold)).foregroundStyle(AppColors.textSecondary)
                Button { help = true } label: {
                    Image(systemName: "questionmark.circle").font(.caption2).frame(width: 32, height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("How keyframes work")
                Spacer(minLength: 0)
                if model.selectionIsAnimated {
                    Button("Remove all", role: .destructive) { confirmsRemoveAll = true }
                        .font(.caption2).frame(minHeight: 32)
                }
            }
        }
    }
}

/// Shown instead of the controls when the playhead sits outside the selected clip, so a
/// keyframe can never be created at a time the clip does not occupy.
struct KeyframeOutOfRangeNotice: View {
    @ObservedObject var model: EditorViewModel
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.caption2).foregroundStyle(AppColors.warning)
            Text("The playhead is outside the selected clip, so keyframes cannot be added here.")
                .font(.caption2).foregroundStyle(AppColors.textSecondary)
            Spacer(minLength: 0)
            Button("Go to clip") { model.goToSelectedClip() }
                .font(.caption2.weight(.semibold)).frame(minHeight: 36)
        }
        .padding(.horizontal, 10)
        .background(AppColors.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }
}
