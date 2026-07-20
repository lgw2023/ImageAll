actor AppModelActivationCoordinator {
    nonisolated let initiallyEnabled: Bool

    private var preferenceStore: any ModelEnablementPreferenceStore
    private let serviceFactory: @Sendable () -> AppCoreMLEmbeddingService
    private var service: AppCoreMLEmbeddingService?
    private var state: AppModelActivationState = .disabled

    init(
        preferenceStore: any ModelEnablementPreferenceStore,
        serviceFactory: @escaping @Sendable () -> AppCoreMLEmbeddingService
    ) {
        initiallyEnabled = preferenceStore.isEnabled
        self.preferenceStore = preferenceStore
        self.serviceFactory = serviceFactory
    }

    func start() -> AppModelActivationState {
        guard state == .disabled else {
            return state
        }
        guard preferenceStore.isEnabled else {
            return .disabled
        }
        state = activate()
        return state
    }

    func setEnabled(_ isEnabled: Bool) -> AppModelActivationState {
        if isEnabled, preferenceStore.isEnabled, state != .disabled {
            return state
        }
        preferenceStore.isEnabled = isEnabled
        guard isEnabled else {
            service = nil
            state = .disabled
            return .disabled
        }
        state = activate()
        return state
    }

    func readyService() -> AppCoreMLEmbeddingService? {
        guard case .ready = state else { return nil }
        return service
    }

    private func activate() -> AppModelActivationState {
        let candidate = serviceFactory()
        switch candidate.availability {
        case let .ready(identity):
            service = candidate
            return .ready(identity)
        case let .unavailable(reason):
            service = nil
            return .unavailable(reason)
        case .disabled:
            service = nil
            return .unavailable(.artifactInvalid)
        }
    }
}
