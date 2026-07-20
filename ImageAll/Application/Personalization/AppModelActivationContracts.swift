enum AppModelActivationState: Equatable, Sendable {
    case disabled
    case validating
    case ready(AppCoreMLModelIdentity)
    case unavailable(AppCoreMLModelFailure)
}

protocol ModelEnablementPreferenceStore: Sendable {
    var isEnabled: Bool { get set }
}
