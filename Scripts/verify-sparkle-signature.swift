#!/usr/bin/env swift

import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("오류: \(message)\n").utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4 else {
    fail("archive path, public key, Ed25519 signature가 필요합니다.")
}

let archiveURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard
    let publicKeyData = Data(base64Encoded: CommandLine.arguments[2]),
    publicKeyData.count == 32
else {
    fail("SUPublicEDKey가 32-byte Ed25519 공개키가 아닙니다.")
}
guard
    let signatureData = Data(base64Encoded: CommandLine.arguments[3]),
    signatureData.count == 64
else {
    fail("appcast의 sparkle:edSignature가 64-byte Ed25519 서명이 아닙니다.")
}

do {
    let publicKey = try Curve25519.Signing.PublicKey(
        rawRepresentation: publicKeyData
    )
    let archive = try Data(contentsOf: archiveURL, options: .mappedIfSafe)
    guard publicKey.isValidSignature(signatureData, for: archive) else {
        fail("Sparkle Ed25519 서명이 ZIP 내용 및 앱 공개키와 일치하지 않습니다.")
    }
} catch {
    fail("Sparkle Ed25519 검증을 실행하지 못했습니다.")
}

print("Sparkle Ed25519 서명 검증 완료")
