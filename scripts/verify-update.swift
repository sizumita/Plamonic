// Checks an update archive's EdDSA signature (from Sparkle's sign_update) against a public key, as the installed
// app does with its SUPublicEDKey before it installs an update.
//
//   xcrun swift scripts/verify-update.swift PUBLIC_KEY FILE SIGNATURE
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("verify-update: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 3 else { fail("usage: xcrun swift scripts/verify-update.swift PUBLIC_KEY FILE SIGNATURE") }
guard let keyData = Data(base64Encoded: arguments[0]),
    let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else { fail("the public key is not a base64 Ed25519 key") }
guard let signature = Data(base64Encoded: arguments[2]) else { fail("the signature is not base64") }
guard let file = try? Data(contentsOf: URL(fileURLWithPath: arguments[1]), options: .alwaysMapped) else {
    fail("cannot read \(arguments[1])")
}
guard key.isValidSignature(signature, for: file) else {
    fail("the signature of \(arguments[1]) does not match the public key \(arguments[0])")
}
print("The signature of \(arguments[1]) matches the public key.")
