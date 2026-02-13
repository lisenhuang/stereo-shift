import Combine
import Foundation
import Network
import StoreKit

@MainActor
final class SubscriptionManager: ObservableObject {
    // Replace these with your real App Store Connect product IDs.
    // Recommended setup:
    // - weekly: auto-renewable subscription
    // - lifetime: non-consumable one-time purchase
    nonisolated static let defaultVideoProductIDs = [
        "com.huanglisen.stereoshift.video.weekly",
        "com.huanglisen.stereoshift.video.lifetime"
    ]

    @Published private(set) var products: [Product] = []
    @Published private(set) var isSubscribed = false
    @Published private(set) var canAccessVideo = false
    @Published private(set) var hasResolvedEntitlements = false
    @Published private(set) var isLoadingProducts = false
    @Published private(set) var isPurchasing = false
    @Published var errorMessage: String?

    private let orderedProductIDs: [String]
    private let productIDSet: Set<String>
    private var updatesTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "com.huanglisen.stereoshift.subscription.pathmonitor")
    private let userDefaults: UserDefaults
    private var hasEverSubscribed = false
    private var isNetworkReachable = true

    nonisolated private static let cachedSubscriptionStateKey = "cached_video_subscription_state"
    nonisolated private static let hasCachedSubscriptionStateKey = "has_cached_video_subscription_state"
    nonisolated private static let hasEverSubscribedKey = "has_ever_subscribed_to_video"

    init(productIDs: [String], userDefaults: UserDefaults = .standard) {
        orderedProductIDs = productIDs
        productIDSet = Set(productIDs)
        self.userDefaults = userDefaults

        if userDefaults.bool(forKey: Self.hasCachedSubscriptionStateKey) {
            isSubscribed = userDefaults.bool(forKey: Self.cachedSubscriptionStateKey)
            hasResolvedEntitlements = true
        }
        hasEverSubscribed = userDefaults.bool(forKey: Self.hasEverSubscribedKey) || isSubscribed
        recomputeVideoAccess()

        startPathMonitoring()

        updatesTask = Task { [weak self] in
            await self?.observeTransactionUpdates()
        }

        Task {
            await refreshProducts()
            await refreshEntitlements()
        }
    }

    convenience init() {
        self.init(productIDs: Self.defaultVideoProductIDs)
    }

    deinit {
        updatesTask?.cancel()
        pathMonitor?.cancel()
    }

    func refreshProducts() async {
        guard !orderedProductIDs.isEmpty else {
            products = []
            return
        }

        isLoadingProducts = true
        defer { isLoadingProducts = false }

        do {
            let loadedProducts = try await Product.products(for: orderedProductIDs)
            let orderIndex = Dictionary(
                uniqueKeysWithValues: orderedProductIDs.enumerated().map { ($0.element, $0.offset) }
            )
            products = loadedProducts.sorted {
                (orderIndex[$0.id] ?? .max) < (orderIndex[$1.id] ?? .max)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshEntitlements() async {
        var hasActiveEntitlement = false

        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result else { continue }
            guard productIDSet.contains(transaction.productID) else { continue }
            guard transaction.revocationDate == nil else { continue }
            guard !transaction.isUpgraded else { continue }
            if let expirationDate = transaction.expirationDate, expirationDate <= Date() {
                continue
            }

            hasActiveEntitlement = true
            break
        }

        isSubscribed = hasActiveEntitlement
        hasResolvedEntitlements = true
        if hasActiveEntitlement {
            hasEverSubscribed = true
            userDefaults.set(true, forKey: Self.hasEverSubscribedKey)
        }
        userDefaults.set(hasActiveEntitlement, forKey: Self.cachedSubscriptionStateKey)
        userDefaults.set(true, forKey: Self.hasCachedSubscriptionStateKey)
        recomputeVideoAccess()
    }

    func purchase(_ product: Product) async {
        guard !isPurchasing else { return }
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case let .success(verification):
                let transaction = try verifiedTransaction(from: verification)
                await transaction.finish()
                await refreshEntitlements()
            case .pending:
                errorMessage = NSLocalizedString("Purchase is pending approval.", comment: "")
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restorePurchases() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func startPathMonitoring() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isNetworkReachable = reachable
                self.recomputeVideoAccess()
                if reachable {
                    await self.refreshEntitlements()
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
    }

    private func recomputeVideoAccess() {
        // Offline fallback: if user has ever paid before, allow video while offline.
        canAccessVideo = isSubscribed || (hasEverSubscribed && !isNetworkReachable)
    }

    private func observeTransactionUpdates() async {
        for await result in Transaction.updates {
            guard case let .verified(transaction) = result else { continue }
            guard productIDSet.contains(transaction.productID) else { continue }

            await transaction.finish()
            await refreshEntitlements()
        }
    }

    private func verifiedTransaction(
        from result: VerificationResult<Transaction>
    ) throws -> Transaction {
        switch result {
        case let .verified(transaction):
            return transaction
        case .unverified:
            throw SubscriptionError.verificationFailed
        }
    }
}

enum SubscriptionError: LocalizedError {
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .verificationFailed:
            return NSLocalizedString("Purchase verification failed.", comment: "")
        }
    }
}
