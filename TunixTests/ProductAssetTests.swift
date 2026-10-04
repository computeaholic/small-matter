import Foundation
import ImageIO
import XCTest

final class ProductAssetTests: XCTestCase {
    func testSmallMatterAppIconContainsEveryMacScaleAndCanonicalVectorSource() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconDirectory = repositoryRoot
            .appendingPathComponent("Tunix/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
        let contentsURL = iconDirectory.appendingPathComponent("Contents.json")
        let contents = try Data(contentsOf: contentsURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: contents) as? [String: Any])
        let images = try XCTUnwrap(json["images"] as? [[String: Any]])
        let macFilenames: Set<String> = Set(images.compactMap { image in
            guard image["idiom"] as? String == "mac" else { return nil }
            return image["filename"] as? String
        })
        let expectedFilenames = Set([16, 32, 64, 128, 256, 512, 1024].map { "SmallMatterIcon-\($0).png" })
        XCTAssertEqual(macFilenames, expectedFilenames)

        for size in [16, 32, 64, 128, 256, 512, 1024] {
            let url = iconDirectory.appendingPathComponent("SmallMatterIcon-\(size).png")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
            XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, size)
            XCTAssertEqual((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, size)
        }

        let vectorSource = try String(
            contentsOf: repositoryRoot.appendingPathComponent("Tunix/Brand/SmallMatterIcon.svg")
        )
        XCTAssertFalse(vectorSource.contains("linearGradient"))
        XCTAssertTrue(vectorSource.contains("stroke=\"#7DD3F7\""))
        XCTAssertTrue(vectorSource.contains("<path"))
    }
}
