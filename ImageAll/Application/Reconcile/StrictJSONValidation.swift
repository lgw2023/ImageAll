import Foundation

enum StrictJSONValidation {
    private static let allowedIntegerObjCTypes: Set<String> = ["i", "s", "l", "q", "I", "S", "L", "Q"]

    static func exactObjectKeys(_ object: [String: Any], allowed: Set<String>) -> Bool {
        Set(object.keys) == allowed
    }

    static func exactContractVersion(_ value: Any?) -> Int? {
        guard let int = nonNegativeInteger(value), int == FolderReconcileJobFactory.contractVersion else {
            return nil
        }
        return int
    }

    static func exactCheckpointContractVersion(_ value: Any?) -> Int? {
        guard let int = nonNegativeInteger(value), int == FolderReconcileCheckpointV1.contractVersionValue else {
            return nil
        }
        return int
    }

    static func positiveInteger(_ value: Any?) -> Int? {
        guard let int = nonNegativeInteger(value), int > 0 else {
            return nil
        }
        return int
    }

    static func nonNegativeInteger(_ value: Any?) -> Int? {
        guard let value else {
            return nil
        }
        if value is NSNull {
            return nil
        }
        if value is String || value is [Any] || value is [String: Any] {
            return nil
        }

        let number: NSNumber
        if let bridged = value as? NSNumber {
            number = bridged
        } else if let int = value as? Int {
            number = NSNumber(value: int)
        } else {
            return nil
        }

        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return nil
        }

        let objCType = String(cString: number.objCType)
        guard allowedIntegerObjCTypes.contains(objCType) else {
            return nil
        }

        let decimal = number.stringValue
        guard !decimal.contains("."), !decimal.contains("e"), !decimal.contains("E") else {
            return nil
        }
        guard let int = Int(decimal), int >= 0 else {
            return nil
        }
        return int
    }

    static func lowercaseCanonicalUUIDString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        guard string == string.lowercased(),
              let uuid = UUID(uuidString: string),
              uuid.uuidString.lowercased() == string
        else {
            return nil
        }
        return string
    }
}
