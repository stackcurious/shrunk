import Foundation
import StoreKit

/// The two products in the "Shrunk Pro" subscription group (spec §2).
/// Yearly first: it is the preselected plan on the paywall.
enum ShrunkProProduct {
    static let monthly = "com.shrunk.pro.monthly"
    static let yearly  = "com.shrunk.pro.yearly"
    static let all: [String] = [yearly, monthly]
}

/// Entitlement derivation, split out of `StoreKitService` so it can be unit
/// tested without StoreKit. Pro means: any non-revoked, unexpired subscription
/// in the Shrunk Pro group.
enum ProEntitlement {
    struct Snapshot: Equatable {
        let productID: String
        let expirationDate: Date?
        let revocationDate: Date?
    }

    static func isActive(_ snapshots: [Snapshot], now: Date) -> Bool {
        snapshots.contains { snapshot in
            guard ShrunkProProduct.all.contains(snapshot.productID) else { return false }
            guard snapshot.revocationDate == nil else { return false }
            guard let expiration = snapshot.expirationDate else { return true }
            return expiration > now
        }
    }
}

@MainActor
final class StoreKitService: ObservableObject {
    static let shared = StoreKitService()

    @Published var isProUser: Bool = false
    @Published private(set) var monthlyProduct: Product?
    @Published private(set) var yearlyProduct: Product?
    @Published private(set) var isTrialEligible: Bool = true
    @Published private(set) var purchaseInProgress: Bool = false
    @Published private(set) var loadError: String?

    private let syncer: DeviceSyncing
    private var transactionListener: Task<Void, Never>?

    init(syncer: DeviceSyncing = ShrunkAPIClient.shared) {
        self.syncer = syncer
    }

    deinit {
        transactionListener?.cancel()
    }

    func bootstrap() async {
        if transactionListener == nil {
            transactionListener = listenForTransactions()
        }
        await loadProducts()
        await refreshEntitlements()
        await refreshTrialEligibility()
        await syncEntitlement()
    }

    // MARK: - Loading

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: ShrunkProProduct.all)
            monthlyProduct = fetched.first { $0.id == ShrunkProProduct.monthly }
            yearlyProduct  = fetched.first { $0.id == ShrunkProProduct.yearly }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// The 7-day free trial is an introductory offer on the yearly product and
    /// is offered once per subscription group, so eligibility is a group-level
    /// question. Defaults to `true` while products are still loading — the
    /// paywall reads better optimistic than pessimistic, and StoreKit is the
    /// authority at purchase time either way.
    func refreshTrialEligibility() async {
        guard let groupID = yearlyProduct?.subscription?.subscriptionGroupID else { return }
        isTrialEligible = await Product.SubscriptionInfo.isEligibleForIntroOffer(for: groupID)
    }

    // MARK: - Purchase

    func purchase(_ product: Product) async throws {
        purchaseInProgress = true
        defer { purchaseInProgress = false }

        // The appAccountToken is how the Worker links an App Store Server
        // Notification back to this install's `devices` row (spec §5).
        let result = try await product.purchase(options: [.appAccountToken(DeviceIdentity.currentUUID)])
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await refreshEntitlements()
            await refreshTrialEligibility()
            await syncEntitlement()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restore() async {
        do {
            try await AppStore.sync()
        } catch {
            loadError = error.localizedDescription
        }
        await refreshEntitlements()
        await refreshTrialEligibility()
        await syncEntitlement()
    }

    // MARK: - Entitlement

    func refreshEntitlements() async {
        var snapshots: [ProEntitlement.Snapshot] = []
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            snapshots.append(
                ProEntitlement.Snapshot(
                    productID: transaction.productID,
                    expirationDate: transaction.expirationDate,
                    revocationDate: transaction.revocationDate
                )
            )
        }
        isProUser = ProEntitlement.isActive(snapshots, now: Date())
    }

    /// Hands the current entitlement's signed JWS to the Worker so it can
    /// refresh `pro_until`. No entitlement means nothing to sync — the Worker
    /// keeps whatever it has until an App Store notification says otherwise.
    func syncEntitlement() async {
        var jws: String?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                  ShrunkProProduct.all.contains(transaction.productID) else { continue }
            jws = result.jwsRepresentation
            break
        }
        guard let jws else { return }
        await syncer.syncDevice(deviceId: DeviceIdentity.currentUUID.uuidString, transactionJWS: jws)
    }

    // MARK: - Internals

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                if case .verified(let transaction) = result {
                    await transaction.finish()
                    await self.refreshEntitlements()
                    await self.refreshTrialEligibility()
                    await self.syncEntitlement()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:         throw StoreKitError.unverifiedTransaction
        case .verified(let safe): return safe
        }
    }
}

enum StoreKitError: LocalizedError {
    case unverifiedTransaction
    case productNotLoaded

    var errorDescription: String? {
        switch self {
        case .unverifiedTransaction: return "We couldn't verify your purchase with the App Store."
        case .productNotLoaded:      return "We're still loading the store. Try again in a moment."
        }
    }
}
