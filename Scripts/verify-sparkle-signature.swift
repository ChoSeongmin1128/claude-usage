#!/usr/bin/env swift

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("오류: \(message)\n").utf8))
    exit(1)
}

// Sparkle 2.10 SPUExtractAppcastContent/signAppcast wire format. Verify the
// original bytes, not reserialized XML; embedded notes are covered too.
func signedFeed(_ data: Data) -> (content: Data, signature: String) {
    let prefix = Data("<!-- sparkle-signatures:\n".utf8)
    guard data.count <= 2 * 1024 * 1024,
          let range = data.range(of: prefix, options: .backwards),
          let block = String(data: data[range.upperBound...], encoding: .utf8)
    else {
        fail("appcast feed 서명 블록이 없거나 유효하지 않습니다.")
    }
    let lines = block.components(separatedBy: "\n")
    guard lines.count == 4, lines[2] == "-->", lines[3].isEmpty,
          lines[0].hasPrefix("edSignature: "), lines[1].hasPrefix("length: "),
          let length = Int(lines[1].dropFirst("length: ".count)),
          length == range.lowerBound
    else {
        fail("appcast 서명 블록의 길이 또는 구조가 유효하지 않습니다.")
    }
    return (Data(data[..<range.lowerBound]), String(lines[0].dropFirst("edSignature: ".count)))
}

guard [3, 4].contains(CommandLine.arguments.count) else {
    fail("file path, public key, archive의 경우 Ed25519 signature가 필요합니다.")
}
let fileURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let publicKeyData = Data(base64Encoded: CommandLine.arguments[2]), publicKeyData.count == 32 else {
    fail("SUPublicEDKey가 32-byte Ed25519 공개키가 아닙니다.")
}

do {
    let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
    let content: Data
    let signature: String
    if CommandLine.arguments.count == 3 {
        guard fileURL.pathExtension == "xml" else { fail("내장 서명은 XML feed에만 허용합니다.") }
        (content, signature) = signedFeed(data)
    } else {
        content = data
        signature = CommandLine.arguments[3]
    }
    guard let signatureData = Data(base64Encoded: signature), signatureData.count == 64 else {
        fail("64-byte Ed25519 서명이 필요합니다.")
    }
    let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
    guard publicKey.isValidSignature(signatureData, for: content) else {
        fail("Sparkle Ed25519 서명이 내용 및 신뢰한 공개키와 일치하지 않습니다.")
    }
} catch {
    fail("Sparkle Ed25519 검증을 실행하지 못했습니다.")
}

print("Sparkle Ed25519 서명 검증 완료")
