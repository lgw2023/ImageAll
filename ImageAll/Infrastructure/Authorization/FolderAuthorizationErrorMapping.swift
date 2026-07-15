import Foundation
import GRDB

enum FolderAuthorizationErrorMapping {
    static func mapPersistenceError(_ error: Error) -> FolderAuthorizationError {
        if let mapped = error as? FolderAuthorizationError {
            return mapped
        }
        if error is DatabaseError {
            return .persistenceFailure
        }
        return .persistenceFailure
    }
}

enum FolderAccessFailureObservation: Equatable, Sendable {
    case offline
    case authorizationRequired
}

enum FolderAccessFailureClassifier {
    static func classifyBookmarkResolveFailure(_ error: Error) -> FolderAccessFailureObservation {
        if isLikelyOffline(error) {
            return .offline
        }
        return .authorizationRequired
    }

    static func classifyScopeStartFailure(for url: URL) -> FolderAccessFailureObservation {
        if isLikelyOfflineURL(url) {
            return .offline
        }
        return .authorizationRequired
    }

    static func classifyInvalidRoot(at url: URL) -> FolderAccessFailureObservation {
        if isLikelyOfflineURL(url) {
            return .offline
        }
        return .authorizationRequired
    }

    private static func isLikelyOffline(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return true
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == ENOENT {
            return true
        }
        return false
    }

    private static func isLikelyOfflineURL(_ url: URL) -> Bool {
        var isReachable = false
        do {
            isReachable = try url.checkResourceIsReachable()
        } catch {
            return isLikelyOffline(error)
        }
        return !isReachable
    }
}
