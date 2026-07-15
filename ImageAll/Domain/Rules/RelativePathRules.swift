import Foundation

enum RelativePathValidationFailure: Equatable, Sendable, Error {
    case empty
    case absolute
    case invalidComponent
    case containsNUL
    case escapesRoot
}

enum RelativePathRules {
    static func validate(_ path: String) -> Result<String, RelativePathValidationFailure> {
        guard !path.isEmpty else {
            return .failure(.empty)
        }
        if path.hasPrefix("/") || path.hasPrefix("\\") {
            return .failure(.absolute)
        }
        if path.contains("\0") {
            return .failure(.containsNUL)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            if component.isEmpty || component == "." || component == ".." {
                return .failure(.invalidComponent)
            }
        }

        let normalized = components.map(String.init).joined(separator: "/")
        if normalized != path {
            return .failure(.escapesRoot)
        }

        return .success(path)
    }

    static func fileName(from relativePath: String) -> String? {
        guard case let .success(validated) = validate(relativePath) else {
            return nil
        }
        guard let last = validated.split(separator: "/").last else {
            return nil
        }
        let name = String(last)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            return nil
        }
        return name
    }
}
