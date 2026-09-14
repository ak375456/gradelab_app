import Combine
import StoreKit
import Foundation

@MainActor
final class ProStore: ObservableObject {
    static let shared = ProStore()
    @Published private(set) var products: [Product] = []
    @Published private(set) var ownedIDs: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isCheckingAccess = true
    @Published private(set) var isPurchasing = false
    @Published private(set) var isRestoring = false
    @Published var message: String?
    private var updatesTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    var hasPro: Bool { true }
    var hasLifetime: Bool { ownedIDs.contains(ProPlan.lifetime.id) }
    var hasSubscription: Bool { ProPlan.allCases.contains { $0 != .lifetime && ownedIDs.contains($0.id) } }

    private init() {
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                guard case .verified(let transaction) = result else { continue }
                guard ProPlan.allCases.contains(where: { $0.id == transaction.productID }) else { continue }
                await self.refreshAccess()
                await transaction.finish()
            }
        }
        Task { await refreshAccess() }
    }
    deinit { updatesTask?.cancel(); expiryTask?.cancel() }

    func product(for plan: ProPlan) -> Product? { products.first { $0.id == plan.id } }
    /// The lifetime plan while the founding campaign is on, in any currency.
    func isFounding(_ product: Product) -> Bool {
        product.id == ProPlan.lifetime.id && ProConfiguration.isFoundingCampaignRunning
    }

    /// The same plan, but only where the percentage saving can honestly be named.
    func showsFoundingDiscount(_ product: Product) -> Bool {
        isFounding(product) && ProConfiguration.canStateFoundingDiscount(
            price: product.price, currency: product.priceFormatStyle.currencyCode)
    }

    /// The standard lifetime price, struck through beside the founding one.
    ///
    /// Nil unless the customer is being charged in the currency the standard
    /// price is actually known in — which is dollars. A struck-through price is
    /// read as "this is what you would otherwise pay", so putting one next to a
    /// rupee or euro figure would be claiming a local price this app has never
    /// charged and cannot look up. Outside the US storefront the standard price
    /// is named in words instead, as the US price it is.
    func standardPriceLabel(_ product: Product) -> String? {
        guard showsFoundingDiscount(product) else { return nil }
        return ProConfiguration.standardLifetimeUSD.formatted(product.priceFormatStyle)
    }
    // MARK: - Comparing plans

    /// What one week of this plan costs.
    ///
    /// Plans of different lengths cannot be compared by their sticker prices —
    /// $4.99 a month looks dearer than $1.99 a week until you work out that a
    /// month is four and a bit weeks. Reducing everything to a weekly figure is
    /// the comparison a buyer is actually trying to make, so the app does the
    /// arithmetic instead of leaving it to them.
    func weeklyPrice(_ product: Product) -> Decimal? {
        guard let period = product.subscription?.subscriptionPeriod else { return nil }
        let weeks: Decimal
        switch period.unit {
        case .day: weeks = Decimal(period.value) / 7
        case .week: weeks = Decimal(period.value)
        case .month: weeks = Decimal(period.value) * ProPricing.weeksPerMonth
        case .year: weeks = Decimal(period.value) * ProPricing.weeksPerYear
        @unknown default: return nil
        }
        return ProPricing.weeklyPrice(product.price, weeksInPeriod: weeks)
    }

    /// The weekly price, formatted in the product's own currency.
    func weeklyPriceLabel(_ product: Product) -> String? {
        weeklyPrice(product).map { $0.formatted(product.priceFormatStyle) }
    }

    /// Whole-percent saving against the weekly plan.
    ///
    /// Nil when there is nothing worth claiming — the weekly plan compared with
    /// itself, a missing weekly product to compare against, or a difference too
    /// small to be worth a badge.
    func savingsVersusWeekly(_ product: Product) -> Int? {
        guard product.id != ProPlan.weekly.id,
              let baseline = self.product(for: .weekly).flatMap(weeklyPrice),
              let mine = weeklyPrice(product) else { return nil }
        return ProPricing.savingsPercent(candidate: mine, baseline: baseline)
    }

    func loadProducts() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            products = try await Product.products(for: ProPlan.allCases.map(\.id))
            if products.count != ProPlan.allCases.count {
                message = "Some plans are unavailable from the App Store. Please try again later."
            }
        } catch { message = "Couldn’t load prices. Check your connection and try again." }
    }
    func refreshAccess() async {
        var current: Set<String> = []
        var nextExpiry: Date?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ProPlan.allCases.contains(where: { $0.id == transaction.productID }),
                  transaction.revocationDate == nil, !transaction.isUpgraded else { continue }
            current.insert(transaction.productID)
            if let date = transaction.expirationDate, date > .now {
                nextExpiry = min(nextExpiry ?? date, date)
            }
        }
        ownedIDs = current
        isCheckingAccess = false
        expiryTask?.cancel()
        if let nextExpiry {
            expiryTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(1, nextExpiry.timeIntervalSinceNow + 1))) }
                catch { return }
                await self?.refreshAccess()
            }
        }
    }
    func purchase(_ product: Product) async {
        guard !isPurchasing, !isRestoring, !hasLifetime else { return }
        guard ProConfiguration.legalLinksReady else {
            message = "Purchases aren’t available in this build yet."
            return
        }
        // Subscription members manage their existing subscription instead of
        // accidentally buying a second way of accessing the same Pro tier.
        guard !hasSubscription else {
            message = "You already have Pro. Use Manage Subscription to review your plan."
            return
        }
        isPurchasing = true
        message = nil
        defer { isPurchasing = false }
        do {
            switch try await product.purchase() {
            case .success(let result):
                guard case .verified(let transaction) = result else {
                    message = "The purchase couldn’t be verified. Try Restore Purchases."
                    return
                }
                await refreshAccess()
                await transaction.finish()
            case .pending: message = "Your purchase is awaiting approval. Pro will unlock when Apple confirms it."
            case .userCancelled: break
            @unknown default: message = "The purchase hasn’t completed. Please try again."
            }
        } catch { message = "The purchase couldn’t be completed. \(error.localizedDescription)" }
    }
    func restore() async {
        guard !isPurchasing, !isRestoring else { return }
        isRestoring = true
        defer { isRestoring = false }
        do {
            try await AppStore.sync()
            await refreshAccess()
            message = hasPro ? "Your Pro access has been restored." : "No Pro purchase was found for this Apple Account."
        } catch { message = "Purchases couldn’t be restored. Please try again." }
    }
}
