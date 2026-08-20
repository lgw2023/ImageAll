import Darwin
import Foundation

private struct Request: Decodable {
    let paths: [String]
}

private struct FileFingerprintFact: Encodable {
    let sizeBytes: Int64?
    let modifiedAtNs: Int64?
    let resourceIDHex: String?

    enum CodingKeys: String, CodingKey {
        case sizeBytes = "size_bytes"
        case modifiedAtNs = "modified_at_ns"
        case resourceIDHex = "resource_id_hex"
    }
}

private struct Response: Encodable {
    let facts: [FileFingerprintFact]
}

private func resourceIdentifierData(_ object: Any?) -> Data? {
    guard let object else { return nil }
    if let data = object as? Data {
        return data
    }
    if let number = object as? NSNumber {
        return number.stringValue.data(using: .utf8)
    }
    return nil
}

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    let request = try JSONDecoder().decode(Request.self, from: input)
    let facts = request.paths.map { path -> FileFingerprintFact in
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(
            forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        )
        let modifiedAtNs = values?.contentModificationDate.map {
            Int64($0.timeIntervalSince1970 * 1_000_000_000)
        }
        let resourceID = resourceIdentifierData(values?.fileResourceIdentifier)
        return FileFingerprintFact(
            sizeBytes: values?.fileSize.map(Int64.init),
            modifiedAtNs: modifiedAtNs,
            resourceIDHex: resourceID.map(hex)
        )
    }
    let output = try JSONEncoder().encode(Response(facts: facts))
    FileHandle.standardOutput.write(output)
} catch {
    FileHandle.standardError.write(Data("foundation fingerprint helper failed\n".utf8))
    exit(2)
}
