#!/usr/bin/env swift
//
// ClaudeUsage DMG 배경 PNG 생성기
// 540x380 @ 2x (실제 1080x760) 배경을 렌더링해 output 경로에 저장.
// make-dmg.sh 에서 1회성 호출 또는 사전 렌더된 결과를 저장소에 커밋해 사용.
//

import AppKit
import Foundation
import CoreGraphics

let width: CGFloat = 540
let height: CGFloat = 380
let scale: CGFloat = 2.0

let pixelWidth = Int(width * scale)
let pixelHeight = Int(height * scale)

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: pixelWidth,
    height: pixelHeight,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    FileHandle.standardError.write("CGContext 생성 실패\n".data(using: .utf8)!)
    exit(1)
}

// 좌표계를 상단 원점 기준으로 전환 (AppKit 관례에 맞춤)
ctx.scaleBy(x: scale, y: scale)

// 1) 배경 그라데이션 (위 → 아래로 아주 옅은 블루그레이)
let topColor = CGColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1)
let bottomColor = CGColor(red: 0.90, green: 0.92, blue: 0.95, alpha: 1)
let gradient = CGGradient(
    colorsSpace: cs,
    colors: [topColor, bottomColor] as CFArray,
    locations: [0, 1]
)!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: 0),
    end: CGPoint(x: 0, y: height),
    options: []
)

// 2) 중앙 안내 화살표 (앱 → Applications 방향)
let arrowY = height / 2 - 10
let arrowColor = CGColor(red: 0.55, green: 0.58, blue: 0.64, alpha: 1)

ctx.setStrokeColor(arrowColor)
ctx.setLineWidth(3)
ctx.setLineCap(.round)

// 화살표 본체
let arrowStartX: CGFloat = width / 2 - 50
let arrowEndX: CGFloat = width / 2 + 50
ctx.move(to: CGPoint(x: arrowStartX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
ctx.strokePath()

// 화살표 머리 (꺾임)
ctx.move(to: CGPoint(x: arrowEndX - 12, y: arrowY - 8))
ctx.addLine(to: CGPoint(x: arrowEndX, y: arrowY))
ctx.addLine(to: CGPoint(x: arrowEndX - 12, y: arrowY + 8))
ctx.strokePath()

// 3) 하단 안내 텍스트
let label = "ClaudeUsage 를 Applications 폴더로 드래그해 설치"
let textColor = NSColor(red: 0.30, green: 0.33, blue: 0.40, alpha: 1)
let font = NSFont.systemFont(ofSize: 12, weight: .medium)
let attributes: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: textColor,
]
let attrStr = NSAttributedString(string: label, attributes: attributes)

let textSize = attrStr.size()
let textRect = NSRect(
    x: (width - textSize.width) / 2,
    y: 30,
    width: textSize.width,
    height: textSize.height
)

// NSAttributedString 은 flipped 좌표계를 사용하므로 NSGraphicsContext 로 감쌈
let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx
attrStr.draw(in: textRect)
NSGraphicsContext.restoreGraphicsState()

// 4) PNG 저장
guard let cgImage = ctx.makeImage() else {
    FileHandle.standardError.write("CGImage 생성 실패\n".data(using: .utf8)!)
    exit(1)
}

let rep = NSBitmapImageRep(cgImage: cgImage)
rep.size = NSSize(width: width, height: height)
guard let data = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("PNG 인코딩 실패\n".data(using: .utf8)!)
    exit(1)
}

let outputPath: String
if CommandLine.arguments.count >= 2 {
    outputPath = CommandLine.arguments[1]
} else {
    outputPath = "Scripts/dmg-assets/background.png"
}

let outputURL = URL(fileURLWithPath: outputPath)
do {
    try data.write(to: outputURL)
    print("생성됨: \(outputPath) (\(pixelWidth)x\(pixelHeight) @ \(scale)x)")
} catch {
    FileHandle.standardError.write("저장 실패: \(error.localizedDescription)\n".data(using: .utf8)!)
    exit(1)
}
