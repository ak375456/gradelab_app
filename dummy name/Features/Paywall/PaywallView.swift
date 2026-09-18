import SwiftUI
import StoreKit

struct PaywallView: View {
    var feature: ProFeature = .membership
    @ObservedObject private var store = ProStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ProPlan = .lifetime
    private let accent = Color(red: 0.45, green: 0.90, blue: 0.98)
    private var selectedProduct: Product? { store.product(for: selection) }
    private var busy: Bool { store.isPurchasing || store.isRestoring }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("GRADELAB PRO").font(.caption.weight(.bold)).tracking(2).foregroundStyle(accent)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.body.weight(.medium)).frame(width: 44, height: 44)
                            .background(.white.opacity(0.07), in: Circle())
                    }.accessibilityLabel("Close paywall").disabled(busy)
                }
                VStack(alignment: .leading, spacing: 12) {
                    BeforeAfterSlider()
                    Text("Drag to compare. Every look in GradeLab is this one gesture away.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .center)
                    Text(store.hasPro ? "You’re ready to create." : feature.title)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                    Text(store.hasPro ? (store.hasLifetime ? "Lifetime Pro is yours. Thank you for supporting GradeLab." : "Your subscription unlocks every Pro feature.") : feature.detail)
                        .font(.body).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 16) {
                    benefit(String(localized: "Color with character"), String(localized: "Premium cinematic looks and your own LUTs"), "camera.filters")
                    benefit(String(localized: "A professional finish"), String(localized: "4K and original-resolution export, your own frame rate and bitrate, and ProRes where supported"), "film.stack")
                    benefit(String(localized: "Make it personal"), String(localized: "Import custom fonts for your titles"), "textformat")
                }
                if store.hasPro {
                    Button("Back to creating") { dismiss() }.buttonStyle(ProPrimaryButtonStyle())
                    if store.hasSubscription {
                        Link("Manage Subscription", destination: URL(string: "https://apps.apple.com/account/subscriptions")!)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                } else {
                    VStack(spacing: 10) {
                        ForEach(ProPlan.allCases) { plan in planRow(plan) }
                    }
                    if let message = store.message {
                        Text(message).font(.callout).foregroundStyle(accent).accessibilityLabel(message)
                    }
                    if store.products.isEmpty && !store.isLoading {
                        Button("Retry loading prices") { Task { await store.loadProducts() } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    VStack(spacing: 10) {
                        Button {
                            guard let selectedProduct else { return }
                            Task { await store.purchase(selectedProduct) }
                        } label: {
                            HStack {
                                if store.isPurchasing { ProgressView().tint(.black) }
                                Text(purchaseTitle).fontWeight(.semibold)
                            }.frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ProPrimaryButtonStyle())
                        .disabled(selectedProduct == nil || busy || store.isCheckingAccess || !ProConfiguration.legalLinksReady)
                        Text(selection == .lifetime ? "One purchase. No subscription." : "Payment is charged to your Apple Account. Renews automatically until cancelled in account settings at least 24 hours before renewal.")
                            .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                        if !ProConfiguration.legalLinksReady {
                            Text("Purchases will open when our Terms and Privacy Policy are published.")
                                .font(.caption).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                        }
                    }
                    indieNote
                }
                footer
            }
            .padding(24).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
        .background(Color(red: 0.035, green: 0.045, blue: 0.06).ignoresSafeArea())
        .foregroundStyle(.white).tint(accent).preferredColorScheme(.dark)
        .interactiveDismissDisabled(busy)
        .task { await store.refreshAccess(); await store.loadProducts() }
    }

    /// Who the money actually goes to.
    ///
    /// Placed after the buy button rather than before it: it is for the person
    /// still deciding, and it should not interrupt someone who has already
    /// chosen. Every claim in it is verifiable — there are no ads, no trackers
    /// and no third-party SDKs in this app, which is the same thing the privacy
    /// policy says. It asks for support by being true, not by pleading.
    private var indieNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hammer.fill")
                .font(.system(size: 14))
                .foregroundStyle(accent)
                .frame(width: 20)
                .padding(.top, 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Made by one person")
                    .font(.subheadline.weight(.semibold))
                Text("GradeLab is an independent app — no ads, no trackers, no investors. Pro is what funds the work, and every purchase goes straight into the next update.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.08), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var purchaseTitle: String {
        guard let product = selectedProduct else {
            return store.isLoading ? String(localized: "Loading prices…") : String(localized: "Plan unavailable")
        }
        if selection == .lifetime {
            return String(localized: "Unlock Lifetime · \(product.displayPrice)")
        }
        let period = switch selection {
        case .weekly: String(localized: "week")
        case .monthly: String(localized: "month")
        default: String(localized: "year")
        }
        return String(localized: "Subscribe · \(product.displayPrice) / \(period)")
    }
    /// The founding offer's small print.
    ///
    /// It anchors to the standard $34.99 lifetime price and stops there. It
    /// deliberately does not say the price becomes $34.99 when launch week
    /// ends, because it does not — it becomes $4.99 and climbs from there over
    /// the following weeks. Claiming the larger jump would be the kind of
    /// invented reference price that App Review rejects, and the launch plan
    /// warns against it in the same breath as fake countdowns.
    private func foundingDetail(statingDiscount: Bool) -> String {
        let promise = String(localized: "Buy now and it stays yours forever, whatever the price becomes.")
        let standard = ProConfiguration.standardLifetimeUSD
            .formatted(.currency(code: "USD").precision(.fractionLength(2)))
        guard statingDiscount else {
            // No percentage and no struck-through figure outside the US
            // storefront: a saving quoted against a local price this app cannot
            // see would be a number made up for effect. The standard price is
            // still named — it is the whole point of the offer — but named as
            // what it is, the US one.
            return String(localized: "The standard lifetime price is US\(standard). This price is for launch week only, as a thank-you to our founding users. \(promise)")
        }
        return String(localized: "This price is for launch week only — \(ProConfiguration.foundingDiscountPercent)% off the \(standard) standard lifetime price, as a thank-you to our founding users. \(promise)")
    }

    private func benefit(_ title: String, _ detail: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).foregroundStyle(accent).frame(width: 26).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.65))
            }
        }
    }
    private func planRow(_ plan: ProPlan) -> some View {
        let product = store.product(for: plan)
        let founding = product.map(store.isFounding) ?? false
        let statesDiscount = product.map(store.showsFoundingDiscount) ?? false
        let selected = selection == plan
        let savings = product.flatMap(store.savingsVersusWeekly)
        let weekly = product.flatMap(store.weeklyPriceLabel)
        let standard = product.flatMap(store.standardPriceLabel)
        // Naming the saving on the pill, where it can be named: "FOUNDING
        // PRICE" says an offer exists, "94% OFF" says how big it is, and the
        // second is the one that makes someone stop scrolling.
        let badge = founding
            ? (statesDiscount
                ? String(localized: "FOUNDING — \(ProConfiguration.foundingDiscountPercent)% OFF")
                : String(localized: "FOUNDING PRICE"))
            : savings.map { String(localized: "SAVE \($0)%") }
        return Button { selection = plan } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.title3).foregroundStyle(selected ? accent : .white.opacity(0.4))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(founding ? String(localized: "Lifetime Pro") : plan.title).font(.headline)
                        Text(plan.billingLabel).font(.caption).foregroundStyle(.white.opacity(0.65))
                    }
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 2) {
                        // The price this replaces, struck through directly above
                        // it. Without it the founding price is simply the price,
                        // and the offer is a sentence of small print nobody
                        // reads; with it the discount is the first thing the eye
                        // lands on. Only ever shown in the currency the standard
                        // price is genuinely known in — see `standardPriceLabel`.
                        if let standard {
                            Text(standard)
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.45))
                                .strikethrough(true, color: ProStyle.gold)
                        }
                        Text(product?.displayPrice ?? (store.isLoading ? "…" : "Unavailable"))
                            .font(standard == nil ? .headline : .title3.weight(.bold))
                        // Every subscription also priced by the week, so the
                        // plans can be compared without doing arithmetic.
                        if let weekly {
                            Text("\(weekly) / week")
                                .font(.caption2).foregroundStyle(.white.opacity(0.55))
                        }
                    }
                    .multilineTextAlignment(.trailing)
                }
                if founding {
                    Text(foundingDetail(statingDiscount: statesDiscount))
                        .font(.caption).foregroundStyle(.white.opacity(0.65)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .padding(.top, badge == nil ? 0 : 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? accent.opacity(0.09) : .white.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(selected ? accent : .white.opacity(0.1), lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .topTrailing) {
                if let badge { planBadge(badge, isFounding: founding) }
            }
        }
        .buttonStyle(.plain).disabled(busy || product == nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(planAccessibilityLabel(plan, product: product, founding: founding,
                                                   savings: savings, weekly: weekly))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The pill that straddles a plan's top edge.
    private func planBadge(_ text: String, isFounding: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold)).tracking(0.6)
            .foregroundStyle(.black)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(isFounding ? ProStyle.gold : accent, in: Capsule())
            .padding(.trailing, 14)
            .offset(y: -8)
            .accessibilityHidden(true)
    }

    private func planAccessibilityLabel(
        _ plan: ProPlan, product: Product?, founding: Bool, savings: Int?, weekly: String?
    ) -> String {
        var parts = [founding ? String(localized: "Lifetime Pro") : plan.title]
        if let standard = product.flatMap(store.standardPriceLabel) {
            parts.append(String(localized: "Was \(standard)"))
        }
        if let price = product?.displayPrice { parts.append(price) }
        parts.append(plan.billingLabel)
        if let weekly { parts.append(String(localized: "\(weekly) per week")) }
        if founding { parts.append(String(localized: "Founding price, launch week only")) }
        if let savings { parts.append(String(localized: "Saves \(savings) percent against the weekly plan")) }
        return parts.joined(separator: ". ")
    }
    private var footer: some View {
        VStack(spacing: 4) {
            Button(store.isRestoring ? "Restoring…" : "Restore Purchases") { Task { await store.restore() } }
                .frame(minHeight: 44).disabled(busy)
            if store.hasPro, let message = store.message { Text(message).font(.caption) }
            HStack(spacing: 24) {
                if let url = ProConfiguration.termsURL { Link("Terms of Use", destination: url) }
                if let url = ProConfiguration.privacyPolicyURL { Link("Privacy Policy", destination: url) }
            }.font(.caption).frame(minHeight: 44)
        }.frame(maxWidth: .infinity)
    }
}

private struct ProPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(16).frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.black)
            .background(Color(red: 0.45, green: 0.90, blue: 0.98), in: RoundedRectangle(cornerRadius: 16))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

struct ProFeatureNotice: View {
    let feature: ProFeature
    @State private var showsPaywall = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("GradeLab Pro", systemImage: "sparkles").font(.subheadline.weight(.semibold))
            Text(feature.detail).font(.caption)
            Button("Explore Pro") { showsPaywall = true }.frame(minHeight: 44)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            .background(AppColors.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .sheet(isPresented: $showsPaywall) { PaywallView(feature: feature) }
    }
}


// ---------------------------------------------------------------------------
// Shared gating components
//
// A free account can open every Pro control and watch it work on its own
// footage; what it cannot do is write the file. So the marks below say "this is
// Pro" without ever taking the control away — the paywall arrives at the export
// button, where the value has already been seen.
// ---------------------------------------------------------------------------

/// Pro's own colour.
///
/// Deliberately not the app's accent: the accent already means "this control is
/// active", and a paywall mark drawn in it reads as ordinary interface rather
/// than as a price. Gold is the one hue nothing else in the editor uses, so a
/// Pro mark is recognisable at a glance and in peripheral vision.
enum ProStyle {
    static let gold = Color(red: 1.0, green: 0.78, blue: 0.36)
    static let goldMuted = Color(red: 0.85, green: 0.66, blue: 0.32)
    static var wash: Color { gold.opacity(0.16) }
}

/// The small PRO pill that marks a control a free account may use but not
/// export.
struct ProBadge: View {
    var compact = false
    var body: some View {
        Text("PRO")
            .font(.system(size: compact ? 8 : 10, weight: .bold)).tracking(0.6)
            .padding(.horizontal, compact ? 4 : 6).padding(.vertical, compact ? 1 : 2)
            .foregroundStyle(ProStyle.gold)
            .background(ProStyle.wash, in: Capsule())
            .overlay(Capsule().stroke(ProStyle.gold.opacity(0.35), lineWidth: 0.5))
            .accessibilityLabel("Pro feature")
    }
}

/// The inline "Pro" word used on a control's own label, in Pro's colour so it
/// is never mistaken for part of the control's name.
struct ProInlineTag: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill").font(.system(size: 8, weight: .semibold))
            Text("PRO").font(.system(size: 9, weight: .bold)).tracking(0.5)
        }
        .foregroundStyle(ProStyle.gold)
        .accessibilityLabel("Pro feature")
    }
}

extension View {
    /// Presents the paywall for whichever feature the caller last asked about.
    func paywallSheet(_ feature: Binding<ProFeature?>) -> some View {
        sheet(item: feature) { PaywallView(feature: $0) }
    }

    /// Marks a row as Pro without disabling it.
    @ViewBuilder
    func proMarked(_ isMarked: Bool) -> some View {
        if isMarked {
            HStack(spacing: 8) { self; ProBadge() }
        } else {
            self
        }
    }
}

/// Marks a whole panel as Pro without disabling anything inside it.
///
/// The wording is the promise the gating model makes: everything in the panel
/// works right now, on the user's own footage, and the payment is asked for at
/// export. Nothing here is greyed out.
struct ProPanelNotice: View {
    let feature: ProFeature
    @ObservedObject private var store = ProStore.shared
    @State private var showsPaywall = false

    @ViewBuilder
    var body: some View {
        if !store.hasPro {
            Button { showsPaywall = true } label: {
                HStack(spacing: 8) {
                    ProBadge()
                    Text("Free to explore · Pro to export")
                        .font(.caption2)
                        .foregroundStyle(AppColors.textSecondary)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundStyle(ProStyle.goldMuted)
                }
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens GradeLab Pro")
            .sheet(isPresented: $showsPaywall) { PaywallView(feature: feature) }
        }
    }
}


/// One row of the "what is locked" list.
///
/// Shown as a list rather than as a single reason because an export can be
/// behind the paywall for several independent things at once, and someone
/// deciding whether to buy should be able to see all of them — or, just as
/// usefully, see which one to undo in order to keep exporting for free.
struct ProRequirementRow: View {
    let feature: ProFeature

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.compact) {
            Image(systemName: "lock.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ProStyle.gold)
                .frame(width: 14)
                .padding(.top, 3)
            VStack(alignment: .leading, spacing: 2) {
                Text(feature.title)
                    .font(AppTypography.secondary)
                    .foregroundStyle(AppColors.textPrimary)
                Text(feature.detail)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The card above an export button: every Pro feature this file would use.
struct ProRequirementList: View {
    let features: [ProFeature]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppSpacing.small) {
                HStack(spacing: AppSpacing.compact) {
                    Text(features.count == 1
                         ? "This export uses 1 Pro feature"
                         : "This export uses \(features.count) Pro features")
                        .font(AppTypography.bodyEmphasized)
                        .foregroundStyle(AppColors.textPrimary)
                    Spacer(minLength: 0)
                    ProBadge()
                }
                ForEach(features) { ProRequirementRow(feature: $0) }
                Text(escapeHint)
                    .font(AppTypography.caption)
                    .foregroundStyle(AppColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppSpacing.standard)
            .background(ProStyle.gold.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(ProStyle.gold.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens GradeLab Pro")
    }

    /// How to keep exporting for free, phrased for what is actually in the way.
    ///
    /// Worth stating plainly rather than hiding: someone who does not want to
    /// pay today should be able to get their file out, and telling them how is
    /// what makes the 1080p tier a real offer instead of a tease.
    private var escapeHint: String {
        guard features.contains(.exportResolution) else {
            // Two whole sentences rather than one with a pronoun slotted in:
            // German inflects the pronoun with its referent, so an interpolated
            // "it"/"them" cannot be translated correctly.
            return features.count == 1
                ? String(localized: "Remove it to keep exporting free.")
                : String(localized: "Remove them to keep exporting free.")
        }
        return features.count == 1
            ? String(localized: "Export at 1080p or below to keep exporting free.")
            : String(localized: "Export at 1080p or below, and remove the rest, to keep exporting free.")
    }
}

/// Covers a Pro-only readout so it can be seen to exist without being usable.
///
/// The scopes need this rather than a locked tab: a measurement tool is only
/// worth paying for if you can tell it is really there and really running, and
/// a greyed-out tab shows neither. The trace renders underneath, blurred past
/// the point of being readable.
struct ProObscuredOverlay: View {
    let feature: ProFeature
    let action: () -> Void

    var body: some View {
        // The scope panel is resizable by a workspace divider, so this can be
        // handed anything from a sliver to half the screen. Each part of the
        // message drops out at the height where it would start to be clipped,
        // rather than every part shrinking into an unreadable version of
        // itself: the lock and the button are what must survive.
        GeometryReader { geometry in
            let height = geometry.size.height
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(Color.black.opacity(0.55))
                VStack(spacing: height < 150 ? 6 : AppSpacing.compact) {
                    if height >= 170 {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(ProStyle.gold)
                    }
                    if height >= 92 {
                        Text(feature.title)
                            .font(AppTypography.bodyEmphasized)
                            .foregroundStyle(AppColors.textPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    if height >= 210 {
                        Text(feature.detail)
                            .font(AppTypography.caption)
                            .foregroundStyle(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 6) {
                        if height < 170 {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        Text("Unlock Pro").font(AppTypography.secondary.weight(.semibold))
                    }
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(ProStyle.gold, in: Capsule())
                }
                .padding(.horizontal, AppSpacing.standard)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(feature.title) Locked. \(feature.detail)")
        .accessibilityHint("Opens GradeLab Pro")
        .accessibilityAddTraits(.isButton)
    }
}
