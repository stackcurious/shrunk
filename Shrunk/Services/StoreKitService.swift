import Foundation
import StoreKit

@MainActor
final class StoreKitService: ObservableObject {
    static let shared = StoreKitService()

    /// Single non-consumable IAP. Pay once, unlocks everything forever.
    static let proProductID = "com.shrunk.pro.lifetime"

    @Published var isProUser: Bool = false
    @Published private(set) var product: Product?
    @Published private(set) var purchaseInProgress: Bool = false
    @Published private(set) var loadError: String?

    private var transactionListener: Task<Void, Never>?

    deinit {
        transactionListener?.cancel()
    }

    func bootstrap() async {
        if transactionListener == nil {
            transactionListener = listenForTransactions()
        }
        await loadProducts()
        await refreshEntitlements()
    }

    // MARK: - Loading

    func loadProducts() async {
        do {
            let fetched = try await Product.products(for: [Self.proProductID])
            self.product = fetched.first
            self.loadError = nil
        } catch {
            self.loadError = error.localizedDescription
        }
    }

    // MARK: - Purchase

    func purchase() async throws {
        guard let product else {
            throw StoreKitError.productNotLoaded
        }
        try await purchase(product)
    }

    func purchase(_ product: Product) async throws {
        purchaseInProgress = true
        defer { purchaseInProgress = false }

        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            await refreshEntitlements()
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
            self.loadError = error.localizedDescription
        }
        await refreshEntitlements()
    }

    // MARK: - Entitlement

    func refreshEntitlements() async {
        var entitled = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result,
               txn.productID == Self.proProductID,
               txn.revocationDate == nil {
                entitled = true
                break
            }
        }
        self.isProUser = entitled
    }

    // MARK: - Display helpers

    /// "$9.99" — preformatted via StoreKit locale, with a hard-coded fallback for the
    /// brief window where products are still loading.
    var displayPrice: String {
        product?.displayPrice ?? "$9.99"
    }

    // MARK: - Internals

    private func listenForTransactions() -> Task<Void, Never> {
        Task.detached { [weak self] in
            for await result in Transaction.updates {
                guard let self else { continue }
                if case .verified(let txn) = result {
                    await txn.finish()
                    await self.refreshEntitlements()
                }
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified:           throw StoreKitError.unverifiedTransaction
        case .verified(let safe):   return safe
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
