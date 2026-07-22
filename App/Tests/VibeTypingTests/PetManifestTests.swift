import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import VibeTyping

final class PetManifestTests: XCTestCase {
    func testBundledV2PetLoads() throws {
        let directory = try XCTUnwrap(
            Bundle.module.resourceURL?.appendingPathComponent("Pets/default")
        )
        let atlas = try PetManifestLoader.load(petDirectory: directory)
        XCTAssertEqual(atlas.grid, PetGrid(columns: 8, rows: 11, cellWidth: 192, cellHeight: 208))
        XCTAssertEqual(atlas.frames.count, 11)
        XCTAssertEqual(atlas.frames[0].count, 8)
    }

    func testV1PetLoads() throws {
        let directory = try makePet(version: 1, width: 1_536, height: 1_872)
        let atlas = try PetManifestLoader.load(petDirectory: directory)
        XCTAssertEqual(atlas.grid.rows, 9)
        XCTAssertEqual(atlas.frames.count, 9)
    }

    func testRejectsPathTraversal() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = #"{"id":"bad","displayName":"Bad","description":"Bad","spritesheetPath":"../bad.png"}"#
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("pet.json"))
        XCTAssertThrowsError(try PetManifestLoader.load(petDirectory: directory)) { error in
            XCTAssertEqual(error as? PetManifestError, .unsafeSpritePath)
        }
    }

    func testStateMappingUsesCodexRows() {
        XCTAssertEqual(PetState.from(session: .idle).atlasRow, 0)
        XCTAssertEqual(PetState.from(session: .listening).atlasRow, 6)
        XCTAssertEqual(PetState.from(session: .transcribing).atlasRow, 7)
        XCTAssertEqual(PetState.from(session: .ready).atlasRow, 8)
        XCTAssertEqual(PetState.from(session: .error).atlasRow, 5)
    }

    func testAnimationFrameCountsExcludeUnusedAtlasCells() throws {
        let directory = try XCTUnwrap(
            Bundle.module.resourceURL?.appendingPathComponent("Pets/default")
        )
        let atlas = try PetManifestLoader.load(petDirectory: directory)
        let expected: [(PetState, Int)] = [
            (.idle, 6),
            (.waiting, 6),
            (.running, 6),
            (.review, 6),
            (.failed, 8),
        ]

        for (state, count) in expected {
            XCTAssertEqual(PetAnimationSpec.frameCount(for: state), count)
            XCTAssertTrue(
                atlas.frames[state.atlasRow].prefix(count).allSatisfy(containsVisiblePixel),
                "\(state) includes a transparent animation frame"
            )
        }

        XCTAssertFalse(containsVisiblePixel(atlas.frames[PetState.idle.atlasRow][7]))
    }

    private func makePet(version: Int, width: Int, height: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = """
        {"id":"test","displayName":"Test","description":"Test","spriteVersionNumber":\(version),"spritesheetPath":"spritesheet.png"}
        """
        try Data(manifest.utf8).write(to: directory.appendingPathComponent("pet.json"))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let image = try XCTUnwrap(context.makeImage())
        let url = directory.appendingPathComponent("spritesheet.png")
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return directory
    }

    private func containsVisiblePixel(_ image: CGImage) -> Bool {
        var rgba = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(
            data: &rgba,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return stride(from: 3, to: rgba.count, by: 4).contains { rgba[$0] > 0 }
    }
}
