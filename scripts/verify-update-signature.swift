import CryptoKit
import Foundation

// Independent public-key verification of the exact published bytes. No private
// key or Keychain access is needed for release verification or rollback.
func verify() throws {
    let args = CommandLine.arguments
    guard args.count == 4 || args.count == 5,
          let publicData = Data(base64Encoded: args[3]), publicData.count == 32 else {
        throw NSError(domain: "UpdateSignature", code: 1)
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicData)
    let data = try Data(contentsOf: URL(fileURLWithPath: args[2]))
    let content: Data
    let signature: Data
    if args[1] == "feed", args.count == 4 {
        let marker = Data("<!-- sparkle-signatures:\n".utf8)
        guard let range = data.range(of: marker),
              data.range(of: marker, options: .backwards) == range,
              let block = String(data: data[range.upperBound...], encoding: .utf8),
              block.hasSuffix("-->\n") else { throw NSError(domain: "UpdateSignature", code: 2) }
        let lines = block.components(separatedBy: "\n")
        guard lines.count == 4, lines[0].hasPrefix("edSignature: "), lines[1].hasPrefix("length: "),
              lines[2] == "-->",
              let decoded = Data(base64Encoded: String(lines[0].dropFirst(13))),
              Int(lines[1].dropFirst(8)) == range.lowerBound else { throw NSError(domain: "UpdateSignature", code: 3) }
        content = data[..<range.lowerBound]
        signature = decoded
    } else if args[1] == "archive", args.count == 5, let decoded = Data(base64Encoded: args[4]) {
        content = data; signature = decoded
    } else { throw NSError(domain: "UpdateSignature", code: 4) }
    guard key.isValidSignature(signature, for: content) else { throw NSError(domain: "UpdateSignature", code: 5) }
}
do { try verify(); print("Update signature verified") }
catch { fputs("Update signature verification failed\n", stderr); exit(1) }
