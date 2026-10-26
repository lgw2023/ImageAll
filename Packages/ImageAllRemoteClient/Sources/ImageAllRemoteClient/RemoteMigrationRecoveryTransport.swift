import Foundation

/// Replays only idempotent archive requests. The same offset, body and digest
/// reach the receiver, whose durable chunk journal resolves lost acknowledgments.
/// Certificate validation remains owned by the original transport.
struct RemoteMigrationRecoveryTransport: RemoteHTTPTransporting {
    let base: any RemoteHTTPTransporting
    let beforeAttempt: @Sendable () async throws -> Void
    let accessToken: @Sendable (_ rejected: String?) async throws -> String
    let onRetry: @Sendable (Int) async -> Void
    let sleep: @Sendable (Duration) async throws -> Void

    func data(for original: URLRequest) async throws -> (Data, URLResponse) {
        let path = original.url?.path ?? ""
        let parts = path.split(separator: "/")
        let archive = parts.count >= 3 && parts[0] == "v1" && parts[1] == "migration-transfers"
            && UUID(uuidString: String(parts[2])) != nil
        let replayable = archive && ((parts.count == 3 && ["POST", "GET"].contains(original.httpMethod ?? ""))
            || (parts.count == 4 && parts[3] == "chunks" && original.httpMethod == "PUT")
            || (parts.count == 4 && parts[3] == "resume" && original.httpMethod == "GET")
            || (parts.count == 4 && ["verify-resource", "seal"].contains(String(parts[3])) && original.httpMethod == "POST"))
        var rejected: String?
        var refreshed = false
        var failures = 0
        while true {
            try Task.checkCancellation()
            try await beforeAttempt()
            var request = original
            do {
                let token = try await accessToken(rejected)
                try Task.checkCancellation()
                try await beforeAttempt()
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                let result = try await base.data(for: request)
                try Task.checkCancellation()
                let status = (result.1 as? HTTPURLResponse)?.statusCode
                if replayable, status == 401, !refreshed {
                    refreshed = true; rejected = token
                    await onRetry(failures + 1)
                    continue
                }
                if replayable, let status, [408, 429, 502, 503, 504].contains(status), failures < 4 {
                    failures += 1
                    await onRetry(failures)
                    try await sleep(.milliseconds(250 * (1 << (failures - 1))))
                    continue
                }
                return result
            } catch {
                try Task.checkCancellation()
                guard replayable, failures < 4, Self.isTransient(error) else { throw error }
                failures += 1
                await onRetry(failures)
                try await sleep(.milliseconds(250 * (1 << (failures - 1))))
            }
        }
    }

    private static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
             .dnsLookupFailed, .notConnectedToInternet: return true
        default: return false
        }
    }
}
