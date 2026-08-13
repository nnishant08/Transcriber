import Foundation

/// Paid-feature identifiers the entitlement seam can gate. Adding a case here is how a future
/// pricing model declares something purchasable — it does NOT make it gated today.
public enum PaidFeature: Hashable, Sendable {
    case verticalPack(String)   // a pack id (Feature B)
    case premiumTemplate(String)
    case cloudBYOK              // future optional bring-your-own-key cloud lane (NOT built)
}

/// The single seam any future commerce/licensing system plugs into. EVERYTHING routes pack and
/// premium-feature availability through `isEntitled(_:)`.
///
/// INTENDED USE (deliberately NOT built in this stage): replace `LocalEntitlementProvider` with one
/// that checks a one-time Developer-ID license, a per-vertical-pack purchase, or a BYOK flag. No
/// StoreKit / Gumroad / Paddle / key-issuance / payment verification exists here by design — the
/// pricing model is undecided, distribution is Developer-ID notarization, and wiring commerce now
/// would couple features to an unchosen vendor. This ships fully functional (all features granted).
protocol EntitlementProvider: Sendable {
    func isEntitled(_ feature: PaidFeature) -> Bool
}

/// The shipped provider: grants EVERYTHING, so this build is fully functional. The only gate on packs.
struct LocalEntitlementProvider: EntitlementProvider {
    public func isEntitled(_ feature: PaidFeature) -> Bool { true }
}

/// Process-wide entitlement access point. A future build swaps `current` for a licensing-backed
/// provider; features never reference a concrete provider directly.
public enum Entitlements {
    static let current: EntitlementProvider = LocalEntitlementProvider()
    public static func isEntitled(_ feature: PaidFeature) -> Bool { current.isEntitled(feature) }
}
