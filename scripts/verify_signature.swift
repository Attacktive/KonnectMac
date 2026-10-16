import Foundation
import CryptoKit

guard CommandLine.arguments.count == 4 else {
	fputs("Usage: verify_signature <file-path> <base64-signature> <base64-public-key>\n", stderr)
	exit(1)
}

let filePath = CommandLine.arguments[1]
let signatureBase64 = CommandLine.arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
let publicKeyBase64 = CommandLine.arguments[3].trimmingCharacters(in: .whitespacesAndNewlines)

guard let signatureData = Data(base64Encoded: signatureBase64) else {
	fputs("Error: Signature is not valid Base64.\n", stderr)
	exit(2)
}

guard let publicKeyData = Data(base64Encoded: publicKeyBase64) else {
	fputs("Error: Public key is not valid Base64.\n", stderr)
	exit(3)
}

guard let fileData = FileManager.default.contents(atPath: filePath) else {
	fputs("Error: Could not read file at \(filePath).\n", stderr)
	exit(4)
}

do {
	let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
	guard publicKey.isValidSignature(signatureData, for: fileData) else {
		fputs("Error: Signature verification failed. The signature does not match the file and public key.\n", stderr)
		exit(5)
	}

	print("Signature valid.")
} catch {
	fputs("Error initializing public key: \(error)\n", stderr)
	exit(6)
}
