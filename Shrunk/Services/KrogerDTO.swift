import Foundation

// Wire formats for the Worker's /v1/kroger/* routes. Field names match the
// Worker exactly (snake_case for our fields, camelCase where we pass Kroger's
// location shape straight through), so the plain JSONDecoder needs no strategy.

struct LocationsResponseDTO: Decodable {
    let locations: [StoreLocationDTO]
    let attribution: String
}

struct StoreLocationDTO: Decodable {
    struct AddressDTO: Decodable {
        let addressLine1: String
        let city: String
        let state: String
        let zipCode: String
    }

    let locationId: String
    let chain: String
    let name: String
    let address: AddressDTO

    func toModel() -> StoreLocation {
        StoreLocation(
            id: locationId,
            chain: chain,
            name: name,
            addressLine1: address.addressLine1,
            city: address.city,
            state: address.state,
            zipCode: address.zipCode
        )
    }
}

struct LiveProductDTO: Decodable {
    let gtin: String
    let location_id: String
    let product_id: String
    let brand: String
    let description: String
    let category: String
    let image_url: String?
    let size: String?
    let quantity: Double?
    let unit_kind: String?
    let regular: Double?
    let promo: Double?
    let per_unit_estimate: Double?
    let price_per_base_unit: Double?
    let stock_level: String?
    let attribution: String

    func toModel() -> LivePrice {
        LivePrice(
            gtin: gtin,
            locationId: location_id,
            brand: brand,
            description: description,
            size: size,
            quantity: quantity,
            unitKind: unit_kind,
            regular: regular,
            promo: promo,
            perUnitEstimate: per_unit_estimate,
            stockLevel: stock_level
        )
    }
}

struct SearchResponseDTO: Decodable {
    let results: [SearchResultDTO]
    let attribution: String
}

struct SearchResultDTO: Decodable {
    let gtin: String?
    let product_id: String
    let brand: String
    let description: String
    let category: String
    let image_url: String?
    let size: String?
    let quantity: Double?
    let unit_kind: String?
    let regular: Double?
    let promo: Double?
    let price_per_base_unit: Double?
    let stock_level: String?

    func toModel() -> StoreSearchResult {
        StoreSearchResult(
            gtin: gtin,
            productId: product_id,
            brand: brand,
            description: description,
            category: category,
            imageURL: image_url.flatMap(URL.init),
            size: size,
            quantity: quantity,
            unitKind: unit_kind,
            regular: regular,
            promo: promo,
            stockLevel: stock_level
        )
    }
}
