import UIKit

/// A rounded square control in a track header.
///
/// Subtle filled background rather than a floating glyph, so four of them in a
/// row read as one control group instead of as scattered icons.
final class TimelineHeaderButton: UIButton {
    var isActive = false { didSet { refreshBackground() } }

    init() {
        super.init(frame: .zero)
        layer.cornerRadius = 7
        layer.cornerCurve = .continuous
        adjustsImageWhenHighlighted = false
        setPreferredSymbolConfiguration(.init(pointSize: 11, weight: .semibold), forImageIn: .normal)
        imageView?.contentMode = .scaleAspectFit
        accessibilityTraits.insert(.button)
        refreshBackground()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isHighlighted: Bool { didSet { refreshBackground() } }
    override var isEnabled: Bool { didSet { refreshBackground() } }

    private func refreshBackground() {
        let base = isActive ? TimelineTheme.controlSurfaceActive : TimelineTheme.controlSurface
        backgroundColor = isHighlighted ? TimelineTheme.controlSurfaceActive : base
        alpha = isEnabled ? 1 : 0.4
    }
}

/// The left-hand controls for one track: its name, what it holds, and the four
/// commands that apply to the whole row.
///
/// A view rather than pixels in `draw(_:)` so it keeps UIKit's own button
/// behaviour — highlight, menu presentation, VoiceOver — and so the header
/// column stays still while clips scroll underneath it.
///
/// **Touch targets.** The column is only about 116pt wide on a phone, so four
/// genuinely 44pt-wide buttons cannot sit side by side in it. Instead the
/// control row answers a 44pt-tall band spanning the whole header, and
/// `hitTest` routes a touch to the nearest button rather than requiring a hit
/// inside its 26pt frame. Every touch in that band therefore lands on a
/// control, and no two controls fight over the same point.
final class TimelineTrackHeaderView: UIView {
    struct Model: Equatable {
        var title: String
        var subtitle: String
        var kind: TimelineTrack.Kind
        var isLocked = false
        var isEnabled = true
        var isAudioMuted = false
        var hasAudioContent = false
        var isSelected = false
    }

    let trackID: UUID
    private(set) var model: Model

    var onToggleLock: (() -> Void)?
    var onToggleVisibility: (() -> Void)?
    var onToggleMute: (() -> Void)?

    private let card = UIView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let lockButton = TimelineHeaderButton()
    private let visibilityButton = TimelineHeaderButton()
    private let muteButton = TimelineHeaderButton()
    private let moreButton = TimelineHeaderButton()
    private var buttons: [TimelineHeaderButton] { [lockButton, visibilityButton, muteButton, moreButton] }

    init(trackID: UUID, model: Model) {
        self.trackID = trackID
        self.model = model
        super.init(frame: .zero)
        // Opaque: clips scroll underneath the header column and must not show
        // through the gaps between rows.
        backgroundColor = TimelineTheme.background
        isOpaque = true

        card.layer.cornerRadius = 10
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.isUserInteractionEnabled = false
        addSubview(card)

        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = TimelineTheme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = .systemFont(ofSize: 10, weight: .regular)
        subtitleLabel.textColor = TimelineTheme.textSecondary
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)
        addSubview(subtitleLabel)

        lockButton.addAction(UIAction { [weak self] _ in self?.onToggleLock?() }, for: .touchUpInside)
        visibilityButton.addAction(UIAction { [weak self] _ in self?.onToggleVisibility?() }, for: .touchUpInside)
        muteButton.addAction(UIAction { [weak self] _ in self?.onToggleMute?() }, for: .touchUpInside)
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        buttons.forEach(addSubview)

        apply(model)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var menu: UIMenu? {
        get { moreButton.menu }
        set { moreButton.menu = newValue }
    }

    func apply(_ model: Model) {
        self.model = model
        titleLabel.text = model.title
        subtitleLabel.text = model.subtitle
        card.backgroundColor = model.isSelected ? TimelineTheme.headerSurfaceSelected : TimelineTheme.headerSurface
        card.layer.borderColor = (model.isSelected
            ? TimelineTheme.accent.withAlphaComponent(0.55)
            : TimelineTheme.separator).cgColor

        lockButton.setImage(UIImage(systemName: model.isLocked ? "lock.fill" : "lock.open"), for: .normal)
        lockButton.tintColor = model.isLocked ? TimelineTheme.lockedTint : TimelineTheme.textSecondary
        lockButton.isActive = model.isLocked
        lockButton.accessibilityLabel = model.isLocked
            ? String(localized: "Unlock \(model.title)") : String(localized: "Lock \(model.title)")

        // An audio row's enable toggle and its mute button mean different
        // things, so they must not both be a speaker.
        let visibleSymbol = model.kind == .audio
            ? (model.isEnabled ? "waveform" : "waveform.slash")
            : (model.isEnabled ? "eye.fill" : "eye.slash.fill")
        visibilityButton.setImage(UIImage(systemName: visibleSymbol), for: .normal)
        visibilityButton.tintColor = model.isEnabled ? TimelineTheme.textSecondary : TimelineTheme.lockedTint
        visibilityButton.isActive = !model.isEnabled
        visibilityButton.isEnabled = !model.isLocked
        visibilityButton.accessibilityLabel = model.kind == .audio
            ? (model.isEnabled ? String(localized: "Mute \(model.title)") : String(localized: "Unmute \(model.title)"))
            : (model.isEnabled ? String(localized: "Hide \(model.title)") : String(localized: "Show \(model.title)"))

        muteButton.setImage(UIImage(systemName: model.isAudioMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"), for: .normal)
        muteButton.tintColor = model.isAudioMuted ? TimelineTheme.lockedTint : TimelineTheme.textSecondary
        muteButton.isActive = model.isAudioMuted
        muteButton.isEnabled = model.hasAudioContent && !model.isLocked
        muteButton.accessibilityLabel = model.isAudioMuted
            ? String(localized: "Unmute \(model.title) audio") : String(localized: "Mute \(model.title) audio")

        moreButton.tintColor = TimelineTheme.textSecondary
        moreButton.accessibilityLabel = String(localized: "\(model.title) display options")
        setNeedsLayout()
    }

    // MARK: - Layout

    /// Three densities. A full row gets a name, a summary and the controls; a
    /// medium row drops the summary; a short overlay row drops the name too and
    /// gives the controls the whole width, because a title row is 32pt tall and
    /// still has to be lockable.
    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 3
        card.frame = bounds.insetBy(dx: inset, dy: inset)
        let content = card.frame.insetBy(dx: 7, dy: 4)
        let size = TimelineMetrics.headerControlSize

        // Title 14 + summary 12 + controls 24 is 50, which is what a regular
        // 66pt media row leaves once the card and its insets are taken. The
        // controls give up a couple of points before the summary does: what
        // the row holds is worth more than two points of button.
        if content.height >= 50 {
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            titleLabel.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: 14)
            subtitleLabel.frame = CGRect(x: content.minX, y: titleLabel.frame.maxY, width: content.width, height: 12)
            let side = min(size, content.height - 28)
            layoutButtons(in: CGRect(x: content.minX, y: content.maxY - side, width: content.width, height: side))
        } else if content.height >= 40 {
            titleLabel.isHidden = false
            subtitleLabel.isHidden = true
            titleLabel.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: 14)
            let compact = min(size, content.height - 16)
            layoutButtons(in: CGRect(x: content.minX, y: content.maxY - compact, width: content.width, height: compact))
        } else {
            // A short overlay row has no room for a name beside four controls,
            // and the clip sitting in that row already carries its title. The
            // controls get the whole width rather than a truncated "O…".
            titleLabel.isHidden = true
            subtitleLabel.isHidden = true
            let compact = min(size, max(16, content.height))
            layoutButtons(in: CGRect(x: content.minX, y: content.midY - compact / 2,
                                     width: content.width, height: compact))
        }
    }

    private func layoutButtons(in strip: CGRect) {
        let count = CGFloat(buttons.count)
        let side = min(strip.height, (strip.width - (count - 1) * 3) / count)
        let pitch = count > 1 ? (strip.width - side) / (count - 1) : 0
        for (index, button) in buttons.enumerated() {
            button.frame = CGRect(x: strip.minX + CGFloat(index) * pitch,
                                  y: strip.midY - side / 2, width: side, height: side)
            button.layer.cornerRadius = min(7, side / 3)
        }
    }

    // MARK: - Hit testing

    /// Touches inside the control band go to the nearest button; everything
    /// else falls through to the canvas, so the header never blocks scrolling
    /// or a drag that starts over it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let band = controlBand
        guard band.contains(point) else { return nil }
        let candidates = buttons.filter { !$0.isHidden && $0.isEnabled && $0.frame.width > 1 }
        guard !candidates.isEmpty else { return nil }
        let nearest = candidates.min { abs($0.frame.midX - point.x) < abs($1.frame.midX - point.x) }
        return nearest.map { $0.hitTest(convert(point, to: $0), with: event) ?? $0 }
    }

    /// The row of buttons, grown to a 44pt-tall band across the whole header.
    private var controlBand: CGRect {
        guard let first = buttons.first, first.frame.height > 1 else { return .zero }
        let centre = first.frame.midY
        let height = min(TimelineMetrics.minimumTouchTarget, bounds.height)
        return CGRect(x: 0, y: min(max(0, centre - height / 2), max(0, bounds.height - height)),
                      width: bounds.width, height: height)
    }
}
