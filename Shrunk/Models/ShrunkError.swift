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
        case .network(let e):     return e.localizedDescription
        case .decoding(let e):    return "Couldn't read product data. (\(e.localizedDescription))"
        }
    }
}
