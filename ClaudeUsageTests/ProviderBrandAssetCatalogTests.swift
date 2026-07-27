import AppKit
import XCTest
@testable import ClaudeUsage

@MainActor
final class ProviderBrandAssetCatalogTests: XCTestCase {
    private struct ImageRecord: Hashable {
        let filename: String
        let scale: String
        let luminosity: String?
    }

    func testCatalogInventoryMatchesRuntimeProviderBrandAssets() throws {
        let expected = Set(AppProviderKind.allCases.compactMap(\.brandAssetName))
        let actual = try providerImagesetURLs()
            .map { String($0.deletingPathExtension().lastPathComponent) }

        XCTAssertEqual(Set(actual), expected)
        XCTAssertEqual(actual.count, expected.count)
    }

    func testProviderImagesetsMatchSVGAppearanceAndPaddingContract() throws {
        for imagesetURL in try providerImagesetURLs() {
            let assetName = imagesetURL.deletingPathExtension().lastPathComponent
            let sourceName = try sourceName(for: assetName)
            let sourceURL = sourceDirectory.appendingPathComponent("\(sourceName).svg")
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let usesCurrentColor = source.contains("currentColor")

            let expectedRecords = Set(
                usesCurrentColor
                    ? [
                        ImageRecord(filename: "\(sourceName).png", scale: "1x", luminosity: nil),
                        ImageRecord(filename: "\(sourceName)-dark.png", scale: "1x", luminosity: "dark"),
                        ImageRecord(filename: "\(sourceName)@2x.png", scale: "2x", luminosity: nil),
                        ImageRecord(filename: "\(sourceName)-dark@2x.png", scale: "2x", luminosity: "dark"),
                    ]
                    : [
                        ImageRecord(filename: "\(sourceName).png", scale: "1x", luminosity: nil),
                        ImageRecord(filename: "\(sourceName)@2x.png", scale: "2x", luminosity: nil),
                    ]
            )
            let actualRecords = try imageRecords(in: imagesetURL)
            XCTAssertEqual(actualRecords, expectedRecords, assetName)

            let actualFiles = try Set(
                FileManager.default.contentsOfDirectory(atPath: imagesetURL.path)
            )
            XCTAssertEqual(
                actualFiles,
                Set(expectedRecords.map(\.filename) + ["Contents.json"]),
                "\(assetName)에 contract 밖의 잔여 파일이 있습니다."
            )

            for record in expectedRecords {
                try assertPaddingContract(
                    imageURL: imagesetURL.appendingPathComponent(record.filename),
                    scale: record.scale
                )
            }
        }
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var assetCatalog: URL {
        repositoryRoot
            .appendingPathComponent("ClaudeUsage", isDirectory: true)
            .appendingPathComponent("Assets.xcassets", isDirectory: true)
    }

    private var sourceDirectory: URL {
        repositoryRoot
            .appendingPathComponent("DesignAssets", isDirectory: true)
            .appendingPathComponent("ProviderBrandSources", isDirectory: true)
    }

    private func providerImagesetURLs() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: assetCatalog,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.lastPathComponent.hasPrefix("Provider")
                && $0.lastPathComponent.hasSuffix("Icon.imageset")
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func sourceName(for assetName: String) throws -> String {
        guard assetName.hasPrefix("Provider"), assetName.hasSuffix("Icon") else {
            XCTFail("잘못된 provider asset 이름: \(assetName)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return String(assetName.dropFirst("Provider".count).dropLast("Icon".count)).lowercased()
    }

    private func imageRecords(in imagesetURL: URL) throws -> Set<ImageRecord> {
        let data = try Data(
            contentsOf: imagesetURL.appendingPathComponent("Contents.json")
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["images", "info", "properties"])
        let info = try XCTUnwrap(object["info"] as? [String: Any])
        XCTAssertEqual(info["author"] as? String, "xcode")
        XCTAssertEqual(info["version"] as? Int, 1)
        XCTAssertEqual(Set(info.keys), ["author", "version"])
        let properties = try XCTUnwrap(object["properties"] as? [String: Any])
        XCTAssertEqual(properties["preserves-vector-representation"] as? Bool, false)
        XCTAssertEqual(properties["template-rendering-intent"] as? String, "original")
        XCTAssertEqual(
            Set(properties.keys),
            ["preserves-vector-representation", "template-rendering-intent"]
        )
        let images = try XCTUnwrap(object["images"] as? [[String: Any]])

        return try Set(images.map { image in
            let appearances = image["appearances"] as? [[String: String]]
            let luminosity: String?
            if let appearances {
                XCTAssertEqual(Set(image.keys), ["appearances", "filename", "idiom", "scale"])
                XCTAssertEqual(appearances.count, 1)
                XCTAssertEqual(
                    appearances.first,
                    ["appearance": "luminosity", "value": "dark"]
                )
                luminosity = appearances.first?["value"]
            } else {
                XCTAssertEqual(Set(image.keys), ["filename", "idiom", "scale"])
                luminosity = nil
            }
            XCTAssertEqual(image["idiom"] as? String, "universal")
            return ImageRecord(
                filename: try XCTUnwrap(image["filename"] as? String),
                scale: try XCTUnwrap(image["scale"] as? String),
                luminosity: luminosity
            )
        })
    }

    private func assertPaddingContract(imageURL: URL, scale: String) throws {
        let data = try Data(contentsOf: imageURL)
        let image = try XCTUnwrap(NSBitmapImageRep(data: data), imageURL.lastPathComponent)
        let expectedSize = scale == "2x" ? 128 : 64
        XCTAssertEqual(image.pixelsWide, expectedSize, imageURL.lastPathComponent)
        XCTAssertEqual(image.pixelsHigh, expectedSize, imageURL.lastPathComponent)

        var minimumX = expectedSize
        var minimumY = expectedSize
        var maximumX = -1
        var maximumY = -1

        for y in 0..<image.pixelsHigh {
            for x in 0..<image.pixelsWide {
                guard image.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0 else {
                    continue
                }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }

        XCTAssertGreaterThanOrEqual(maximumX, minimumX, imageURL.lastPathComponent)
        XCTAssertGreaterThanOrEqual(maximumY, minimumY, imageURL.lastPathComponent)

        let contentWidth = maximumX - minimumX + 1
        let contentHeight = maximumY - minimumY + 1
        let maximumContentSize = Int(Double(expectedSize) * 0.84) + 2
        XCTAssertLessThanOrEqual(contentWidth, maximumContentSize, imageURL.lastPathComponent)
        XCTAssertLessThanOrEqual(contentHeight, maximumContentSize, imageURL.lastPathComponent)

        let horizontalImbalance = abs(minimumX - (expectedSize - maximumX - 1))
        let verticalImbalance = abs(minimumY - (expectedSize - maximumY - 1))
        XCTAssertLessThanOrEqual(horizontalImbalance, 2, imageURL.lastPathComponent)
        XCTAssertLessThanOrEqual(verticalImbalance, 2, imageURL.lastPathComponent)
    }
}
