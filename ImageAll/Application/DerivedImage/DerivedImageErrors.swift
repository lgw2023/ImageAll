import Foundation

enum DerivedImageError: Error, Equatable, Sendable {
    case derivedAssetNotFound
    case derivedAssetIneligible
    case derivedAuthorizationRequired
    case derivedSourceUnavailable
    case derivedSourceChanged
    case derivedDecodeFailed
    case derivedEncodeFailed
    case derivedCapacityUnavailable
    case derivedInsufficientSpace
    case derivedCacheUnsafePath
    case derivedCachePersistenceFailed

    var rawValue: String {
        switch self {
        case .derivedAssetNotFound: "derivedAssetNotFound"
        case .derivedAssetIneligible: "derivedAssetIneligible"
        case .derivedAuthorizationRequired: "derivedAuthorizationRequired"
        case .derivedSourceUnavailable: "derivedSourceUnavailable"
        case .derivedSourceChanged: "derivedSourceChanged"
        case .derivedDecodeFailed: "derivedDecodeFailed"
        case .derivedEncodeFailed: "derivedEncodeFailed"
        case .derivedCapacityUnavailable: "derivedCapacityUnavailable"
        case .derivedInsufficientSpace: "derivedInsufficientSpace"
        case .derivedCacheUnsafePath: "derivedCacheUnsafePath"
        case .derivedCachePersistenceFailed: "derivedCachePersistenceFailed"
        }
    }
}
