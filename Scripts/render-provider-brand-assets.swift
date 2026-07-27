#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

private let rasterSourceSize = 512
private let contentRatio = 0.84

private enum PipelineError: LocalizedError {
    case invalidArguments(String)
    case invalidCatalog(String)
    case invalidSource(String)
    case renderFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidArguments(message),
             let .invalidCatalog(message),
             let .invalidSource(message),
             let .renderFailed(message),
             let .writeFailed(message):
            return message
        }
    }
}

private struct Options {
    let sourceDirectory: URL
    let catalogDirectory: URL
    let outputDirectory: URL

    static func parse(arguments: [String]) throws -> Options {
        var values: [String: String] = [:]
        var index = 0

        while index < arguments.count {
            let key = arguments[index]
            guard ["--source-dir", "--catalog-dir", "--output-dir"].contains(key) else {
                throw PipelineError.invalidArguments("알 수 없는 옵션입니다: \(key)")
            }
            guard index + 1 < arguments.count else {
                throw PipelineError.invalidArguments("\(key) 값이 필요합니다.")
            }
            values[key] = arguments[index + 1]
            index += 2
        }

        guard
            let sourcePath = values["--source-dir"],
            let catalogPath = values["--catalog-dir"],
            let outputPath = values["--output-dir"]
        else {
            throw PipelineError.invalidArguments(
                "--source-dir, --catalog-dir, --output-dir을 모두 지정해야 합니다."
            )
        }

        return Options(
            sourceDirectory: URL(fileURLWithPath: sourcePath, isDirectory: true),
            catalogDirectory: URL(fileURLWithPath: catalogPath, isDirectory: true),
            outputDirectory: URL(fileURLWithPath: outputPath, isDirectory: true)
        )
    }
}

private struct ProviderAsset {
    let assetName: String
    let sourceName: String
    let sourceURL: URL
    let usesCurrentColor: Bool

    var imagesetName: String {
        "\(assetName).imageset"
    }

    var expectedPNGNames: [String] {
        let regular = ["\(sourceName).png", "\(sourceName)@2x.png"]
        guard usesCurrentColor else { return regular }
        return regular + ["\(sourceName)-dark.png", "\(sourceName)-dark@2x.png"]
    }
}

private func providerAssets(options: Options) throws -> [ProviderAsset] {
    let fileManager = FileManager.default
    let catalogEntries = try fileManager.contentsOfDirectory(
        at: options.catalogDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )

    let prefix = "Provider"
    let suffix = "Icon.imageset"
    let assetNames = catalogEntries.compactMap { url -> String? in
        guard
            url.lastPathComponent.hasPrefix(prefix),
            url.lastPathComponent.hasSuffix(suffix),
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else {
            return nil
        }

        return String(url.lastPathComponent.dropLast(".imageset".count))
    }
    .sorted()

    guard !assetNames.isEmpty else {
        throw PipelineError.invalidCatalog(
            "Provider*Icon.imageset을 찾지 못했습니다: \(options.catalogDirectory.path)"
        )
    }

    return try assetNames.map { assetName in
        let providerStart = assetName.index(assetName.startIndex, offsetBy: prefix.count)
        let providerEnd = assetName.index(assetName.endIndex, offsetBy: -"Icon".count)
        let providerName = String(assetName[providerStart..<providerEnd])
        guard !providerName.isEmpty else {
            throw PipelineError.invalidCatalog("잘못된 provider asset 이름입니다: \(assetName)")
        }

        let sourceName = providerName.lowercased()
        let sourceURL = options.sourceDirectory.appendingPathComponent("\(sourceName).svg")
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw PipelineError.invalidSource(
                "\(assetName)의 SVG source를 찾지 못했습니다: \(sourceURL.path)"
            )
        }

        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        return ProviderAsset(
            assetName: assetName,
            sourceName: sourceName,
            sourceURL: sourceURL,
            usesCurrentColor: source.contains("currentColor")
        )
    }
}

private func quickLookRenderedSVG(sourceURL: URL) throws -> CGImage {
    let fileManager = FileManager.default
    var source = try String(contentsOf: sourceURL, encoding: .utf8)
    source = source
        .replacingOccurrences(of: "height=\"1em\"", with: "height=\"512\"")
        .replacingOccurrences(of: "width=\"1em\"", with: "width=\"512\"")
        .replacingOccurrences(of: "currentColor", with: "#000000")

    let temporaryDirectory = fileManager.temporaryDirectory
        .appendingPathComponent("provider-svg-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: temporaryDirectory) }

    let fixedSourceURL = temporaryDirectory
        .appendingPathComponent("\(sourceURL.deletingPathExtension().lastPathComponent)-fixed.svg")
    try Data(source.utf8).write(to: fixedSourceURL, options: .atomic)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
    process.arguments = [
        "-t",
        "-s", "\(rasterSourceSize)",
        "-o", temporaryDirectory.path,
        fixedSourceURL.path,
    ]
    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = outputPipe
    try process.run()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let output = String(
            data: outputPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        throw PipelineError.renderFailed(
            "Quick Look SVG 렌더링에 실패했습니다 (\(process.terminationStatus)): \(output)"
        )
    }

    let renderedURL = temporaryDirectory
        .appendingPathComponent("\(fixedSourceURL.lastPathComponent).png")
    guard
        let source = CGImageSourceCreateWithURL(renderedURL as CFURL, nil),
        let rendered = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        throw PipelineError.renderFailed(
            "Quick Look SVG PNG를 읽지 못했습니다: \(renderedURL.path)"
        )
    }

    return try imageByRemovingBoundaryBackground(rendered)
}

private func bitmapContext(width: Int, height: Int) throws -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw PipelineError.renderFailed("RGBA bitmap context 생성에 실패했습니다.")
    }
    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.clear(CGRect(x: 0, y: 0, width: width, height: height))
    return context
}

private func imageByRemovingBoundaryBackground(_ image: CGImage) throws -> CGImage {
    let context = try bitmapContext(width: image.width, height: image.height)
    context.draw(
        image,
        in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
    )
    guard let rawData = context.data else {
        throw PipelineError.renderFailed("Quick Look RGBA pixel buffer를 읽지 못했습니다.")
    }

    let bytesPerRow = context.bytesPerRow
    let bytes = rawData.bindMemory(
        to: UInt8.self,
        capacity: bytesPerRow * image.height
    )
    let pixelCount = image.width * image.height
    var visited = [Bool](repeating: false, count: pixelCount)
    var queue: [Int] = []
    queue.reserveCapacity(pixelCount)

    func isBoundaryBackground(_ index: Int) -> Bool {
        let x = index % image.width
        let y = index / image.width
        let offset = (y * bytesPerRow) + (x * 4)
        return bytes[offset + 3] > 0
            && bytes[offset] >= 250
            && bytes[offset + 1] >= 250
            && bytes[offset + 2] >= 250
    }

    let corners = [
        0,
        image.width - 1,
        (image.height - 1) * image.width,
        pixelCount - 1,
    ]
    for index in corners where !visited[index] && isBoundaryBackground(index) {
        visited[index] = true
        queue.append(index)
    }

    var cursor = 0
    while cursor < queue.count {
        let index = queue[cursor]
        cursor += 1
        let x = index % image.width
        let y = index / image.width
        let offset = (y * bytesPerRow) + (x * 4)
        bytes[offset] = 0
        bytes[offset + 1] = 0
        bytes[offset + 2] = 0
        bytes[offset + 3] = 0

        let neighbors = [
            x > 0 ? index - 1 : -1,
            x + 1 < image.width ? index + 1 : -1,
            y > 0 ? index - image.width : -1,
            y + 1 < image.height ? index + image.width : -1,
        ]
        for neighbor in neighbors
        where neighbor >= 0 && !visited[neighbor] && isBoundaryBackground(neighbor) {
            visited[neighbor] = true
            queue.append(neighbor)
        }
    }

    guard let output = context.makeImage() else {
        throw PipelineError.renderFailed("투명 배경 SVG bitmap 생성에 실패했습니다.")
    }
    return output
}

private func alphaBounds(of image: CGImage) throws -> CGRect {
    guard
        image.bitsPerPixel == 32,
        let provider = image.dataProvider,
        let providerData = provider.data,
        let bytes = CFDataGetBytePtr(providerData)
    else {
        throw PipelineError.renderFailed("RGBA pixel data를 읽지 못했습니다.")
    }

    var minimumX = image.width
    var minimumY = image.height
    var maximumX = -1
    var maximumY = -1

    for y in 0..<image.height {
        let row = bytes + (y * image.bytesPerRow)
        for x in 0..<image.width where row[(x * 4) + 3] > 0 {
            minimumX = min(minimumX, x)
            minimumY = min(minimumY, y)
            maximumX = max(maximumX, x)
            maximumY = max(maximumY, y)
        }
    }

    guard maximumX >= minimumX, maximumY >= minimumY else {
        throw PipelineError.renderFailed("SVG 렌더링 결과가 완전히 투명합니다.")
    }

    return CGRect(
        x: minimumX,
        y: minimumY,
        width: maximumX - minimumX + 1,
        height: maximumY - minimumY + 1
    )
}

private func paddedSquareImage(source: CGImage, targetSize: Int) throws -> CGImage {
    let bounds = try alphaBounds(of: source)
    guard let cropped = source.cropping(to: bounds) else {
        throw PipelineError.renderFailed("SVG alpha bounds crop에 실패했습니다.")
    }

    let innerSize = max(1, Int(Double(targetSize) * contentRatio))
    let scale = min(
        Double(innerSize) / Double(cropped.width),
        Double(innerSize) / Double(cropped.height)
    )
    let renderedWidth = max(1, Int((Double(cropped.width) * scale).rounded()))
    let renderedHeight = max(1, Int((Double(cropped.height) * scale).rounded()))
    let x = (targetSize - renderedWidth) / 2
    let y = (targetSize - renderedHeight) / 2

    let context = try bitmapContext(width: targetSize, height: targetSize)
    context.draw(
        cropped,
        in: CGRect(x: x, y: y, width: renderedWidth, height: renderedHeight)
    )

    guard let output = context.makeImage() else {
        throw PipelineError.renderFailed("\(targetSize)x\(targetSize) PNG bitmap 생성에 실패했습니다.")
    }
    return output
}

private func monochromeImage(source: CGImage, white: Bool) throws -> CGImage {
    let context = try bitmapContext(width: source.width, height: source.height)
    context.draw(
        source,
        in: CGRect(x: 0, y: 0, width: source.width, height: source.height)
    )
    guard let rawData = context.data else {
        throw PipelineError.renderFailed("monochrome RGBA pixel buffer를 읽지 못했습니다.")
    }

    let bytes = rawData.bindMemory(
        to: UInt8.self,
        capacity: context.bytesPerRow * source.height
    )
    for y in 0..<source.height {
        for x in 0..<source.width {
            let offset = (y * context.bytesPerRow) + (x * 4)
            let sourceAlpha = Int(bytes[offset + 3])
            let coverage: UInt8
            if sourceAlpha == 0 {
                coverage = 0
            } else {
                let red = min(255, (Int(bytes[offset]) * 255) / sourceAlpha)
                let green = min(255, (Int(bytes[offset + 1]) * 255) / sourceAlpha)
                let blue = min(255, (Int(bytes[offset + 2]) * 255) / sourceAlpha)
                let luminance = ((54 * red) + (183 * green) + (19 * blue)) / 256
                coverage = UInt8((sourceAlpha * (255 - luminance)) / 255)
            }
            let component = white ? coverage : 0
            bytes[offset] = component
            bytes[offset + 1] = component
            bytes[offset + 2] = component
            bytes[offset + 3] = coverage
        }
    }

    guard let output = context.makeImage() else {
        throw PipelineError.renderFailed("monochrome bitmap 생성에 실패했습니다.")
    }
    return output
}

private func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw PipelineError.writeFailed("PNG destination 생성에 실패했습니다: \(url.path)")
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw PipelineError.writeFailed("PNG 저장에 실패했습니다: \(url.path)")
    }
}

private func imageRecord(
    filename: String,
    scale: String,
    dark: Bool
) -> [String: Any] {
    var record: [String: Any] = [
        "filename": filename,
        "idiom": "universal",
        "scale": scale,
    ]
    if dark {
        record["appearances"] = [
            [
                "appearance": "luminosity",
                "value": "dark",
            ],
        ]
    }
    return record
}

private func contentsJSON(for asset: ProviderAsset) throws -> Data {
    var images: [[String: Any]] = [
        imageRecord(filename: "\(asset.sourceName).png", scale: "1x", dark: false),
    ]
    if asset.usesCurrentColor {
        images.append(
            imageRecord(filename: "\(asset.sourceName)-dark.png", scale: "1x", dark: true)
        )
    }
    images.append(
        imageRecord(filename: "\(asset.sourceName)@2x.png", scale: "2x", dark: false)
    )
    if asset.usesCurrentColor {
        images.append(
            imageRecord(filename: "\(asset.sourceName)-dark@2x.png", scale: "2x", dark: true)
        )
    }

    let object: [String: Any] = [
        "images": images,
        "info": [
            "author": "xcode",
            "version": 1,
        ],
        "properties": [
            "preserves-vector-representation": false,
            "template-rendering-intent": "original",
        ],
    ]
    var data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    )
    data.append(0x0A)
    return data
}

private func render(
    asset: ProviderAsset,
    into outputDirectory: URL
) throws {
    let fileManager = FileManager.default
    let imagesetURL = outputDirectory.appendingPathComponent(asset.imagesetName, isDirectory: true)
    if fileManager.fileExists(atPath: imagesetURL.path) {
        try fileManager.removeItem(at: imagesetURL)
    }
    try fileManager.createDirectory(at: imagesetURL, withIntermediateDirectories: true)

    let rendered = try quickLookRenderedSVG(sourceURL: asset.sourceURL)
    for (size, scaleSuffix) in [(64, ""), (128, "@2x")] {
        let padded = try paddedSquareImage(source: rendered, targetSize: size)
        if asset.usesCurrentColor {
            let light = try monochromeImage(source: padded, white: false)
            let dark = try monochromeImage(source: padded, white: true)
            try writePNG(
                light,
                to: imagesetURL.appendingPathComponent(
                    "\(asset.sourceName)\(scaleSuffix).png"
                )
            )
            try writePNG(
                dark,
                to: imagesetURL.appendingPathComponent(
                    "\(asset.sourceName)-dark\(scaleSuffix).png"
                )
            )
        } else {
            try writePNG(
                padded,
                to: imagesetURL.appendingPathComponent(
                    "\(asset.sourceName)\(scaleSuffix).png"
                )
            )
        }
    }

    let contentsURL = imagesetURL.appendingPathComponent("Contents.json")
    try contentsJSON(for: asset).write(to: contentsURL, options: .atomic)

    let actualFiles = try Set(
        fileManager.contentsOfDirectory(atPath: imagesetURL.path)
    )
    let expectedFiles = Set(asset.expectedPNGNames + ["Contents.json"])
    guard actualFiles == expectedFiles else {
        throw PipelineError.writeFailed(
            "\(asset.imagesetName)의 생성 파일이 contract와 다릅니다: \(actualFiles.sorted())"
        )
    }
}

private func run() throws {
    let options = try Options.parse(arguments: Array(CommandLine.arguments.dropFirst()))
    let assets = try providerAssets(options: options)
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        at: options.outputDirectory,
        withIntermediateDirectories: true
    )

    let expectedImagesets = Set(assets.map(\.imagesetName))
    let existingOutputEntries = try fileManager.contentsOfDirectory(
        at: options.outputDirectory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    )
    for entry in existingOutputEntries
    where entry.lastPathComponent.hasPrefix("Provider")
        && entry.lastPathComponent.hasSuffix("Icon.imageset")
        && !expectedImagesets.contains(entry.lastPathComponent) {
        try fileManager.removeItem(at: entry)
    }

    for asset in assets {
        try render(asset: asset, into: options.outputDirectory)
        let variants = asset.usesCurrentColor ? "light/dark" : "original color"
        print("생성됨: \(asset.imagesetName) (\(variants))")
    }
}

do {
    try run()
} catch {
    let message = "Provider 브랜드 asset 생성 실패: \(error.localizedDescription)\n"
    FileHandle.standardError.write(Data(message.utf8))
    exit(EXIT_FAILURE)
}
