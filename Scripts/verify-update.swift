import Foundation
import CryptoKit

let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
guard let publicData = Data(base64Encoded: CommandLine.arguments[2]),
      let signature = Data(base64Encoded: CommandLine.arguments[3]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicData),
      key.isValidSignature(signature, for: archive) else {
    fatalError("Update signature does not match the public key embedded in Airloom")
}
print("Sparkle Ed25519 signature verified against Airloom's embedded key.")
