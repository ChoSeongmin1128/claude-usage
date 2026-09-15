// RFC 8032 test vector; never reads or writes a user's signing keychain.
import CryptoKit
import Foundation

let seedHex = "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60"
let seed = Data(stride(from: 0, to: seedHex.count, by: 2).map { offset in
    UInt8(seedHex.dropFirst(offset).prefix(2), radix: 16)!
})
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let data = try Data(contentsOf: url)
let signature = try key.signature(for: data).base64EncodedString()
let block = "<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(data.count)\n-->\n"
try (data + Data(block.utf8)).write(to: url, options: .atomic)
