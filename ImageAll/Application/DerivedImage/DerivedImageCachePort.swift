import Foundation

protocol DerivedImageCachePort: Sendable {
    func loadOrGenerate(_ request: DerivedImageRequest) async throws -> DerivedImagePayload
    func performMaintenance() async throws -> DerivedImageMaintenanceResult
}
