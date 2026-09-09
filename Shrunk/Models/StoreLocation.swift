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
    let latitude: Double?
    let longitude: Double?
    var distanceMiles: Double?

    init(
        id: String,
        chain: String,
        name: String,
        addressLine1: String,
        city: String,
        state: String,
        zipCode: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        distanceMiles: Double? = nil
    ) {
        self.id = id
        self.chain = chain
        self.name = name
        self.addressLine1 = addressLine1
        self.city = city
        self.state = state
        self.zipCode = zipCode
        self.latitude = latitude
        self.longitude = longitude
        self.distanceMiles = distanceMiles
    }

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

    var distanceText: String? {
        guard let distanceMiles else { return nil }
        return distanceMiles < 0.1 ? "Less than 0.1 mi" : String(format: "%.1f mi", distanceMiles)
    }

    func ranked(from origin: StoreSearchCoordinate?) -> StoreLocation {
        guard let origin, let latitude, let longitude else { return self }
        var copy = self
        copy.distanceMiles = Self.distanceMiles(
            from: origin,
            to: StoreSearchCoordinate(latitude: latitude, longitude: longitude)
        )
        return copy
    }

    private static func distanceMiles(from lhs: StoreSearchCoordinate, to rhs: StoreSearchCoordinate) -> Double {
        let earthRadiusMiles = 3_958.8
        let latitudeDelta = (rhs.latitude - lhs.latitude) * .pi / 180
        let longitudeDelta = (rhs.longitude - lhs.longitude) * .pi / 180
        let leftLatitude = lhs.latitude * .pi / 180
        let rightLatitude = rhs.latitude * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(leftLatitude) * cos(rightLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return earthRadiusMiles * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}
