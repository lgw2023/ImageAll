import Foundation

enum SourceRules {
    static func disable(_ source: Source) -> Source {
        Source(id: source.id, kind: source.kind, state: .disabled)
    }

    static func releasesCurrentLocator(whenSourceBecomes state: SourceState) -> Bool {
        switch state {
        case .active, .disabled, .unavailable, .authorizationRequired:
            false
        }
    }
}
