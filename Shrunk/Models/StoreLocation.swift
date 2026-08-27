import Foundation

/// A Kroger store the user pins prices to. `id` is Kroger's 8-character locationId.
struct StoreLocation: Identifiable, Hashable, Codable {
    let id: String
    let chain: String
    let name: String
    let addressLine1: String
    let city: String
    let state: String
    let zipCode: String

    /// "Kroger Hyde Park" — what Settings shows and what we persist.
    var displayName: String {
        let chainName = chain.isEmpty ? "" : chain.capitalized
        if name.isEmpty { return chainName.isEmpty ? id : chainName }
        return chainName.isEmpty ? name : "\(chainName) \(name)"
    }

    /// "3760 Paxton Ave · Cincinnati, OH"
    var addressLine: String {
        let cityState = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
        return [addressLine1, cityState].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
