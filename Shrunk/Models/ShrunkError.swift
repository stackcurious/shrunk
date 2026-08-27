import Foundation

/// Every failure the app surfaces from the Shrunk API. The copy is user-facing.
enum ShrunkError: LocalizedError {
    case productNotFound
    case invalidResponse
    case network(Error)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .productNotFound:    return "Not in our database yet."
        case .invalidResponse:    return "We couldn't read the response from the data source."
        // Spec §8, verbatim — every URLSession-level failure (no connectivity,
        // timeout, DNS, TLS…) surfaces the same offline copy regardless of the
        // underlying URLError, matching the string ContributeViewModel already
        // shows on the submit path (I1).
        case .network:             return "Couldn't reach Shrunk — check connection."
        case .decoding(let e):    return "Couldn't read product data. (\(e.localizedDescription))"
        }
    }
}
