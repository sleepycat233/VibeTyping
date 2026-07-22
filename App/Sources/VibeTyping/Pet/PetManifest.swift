import CoreGraphics
import Foundation
import ImageIO

struct PetManifest: Decodable, Equatable, Sendable {
    let id: String
    let displayName: String
    let description: String
    let spriteVersionNumber: Int?
    let spritesheetPath: String
}

struct PetGrid: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let cellWidth: Int
    let cellHeight: Int
}

struct PetAtlas: @unchecked Sendable {
    let manifest: PetManifest
    let grid: PetGrid
    let spriteURL: URL
    let frames: [[CGImage]]
}

enum PetManifestError: Error, Equatable, LocalizedError {
    case invalidManifest
    case unsupportedVersion(Int)
    case unsafeSpritePath
    case spriteMissing
    case invalidDimensions(width: Int, height: Int)
    case cropFailed(row: Int, column: Int)

    var errorDescription: String? {
        switch self {
        case .invalidManifest: "The pet manifest is invalid."
        case .unsupportedVersion(let version): "Pet sprite version \(version) is unsupported."
        case .unsafeSpritePath: "The pet sprite path must stay inside the pet directory."
        case .spriteMissing: "The pet spritesheet is missing or unreadable."
        case .invalidDimensions(let width, let height): "Unexpected pet atlas size \(width)x\(height)."
        case .cropFailed(let row, let column): "Could not crop pet frame \(row):\(column)."
        }
    }
}

enum PetManifestLoader {
    static let columns = 8
    static let cellWidth = 192
    static let cellHeight = 208

    static func load(petDirectory: URL) throws -> PetAtlas {
        let manifestURL = petDirectory.appendingPathComponent("pet.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(PetManifest.self, from: data) else {
            throw PetManifestError.invalidManifest
        }
        let rows: Int
        switch manifest.spriteVersionNumber {
        case nil, 1: rows = 9
        case 2: rows = 11
        case .some(let version): throw PetManifestError.unsupportedVersion(version)
        }
        guard !manifest.spritesheetPath.isEmpty,
              !manifest.spritesheetPath.hasPrefix("/"),
              !manifest.spritesheetPath.split(separator: "/").contains("..") else {
            throw PetManifestError.unsafeSpritePath
        }
        let root = petDirectory.standardizedFileURL
        let spriteURL = root.appendingPathComponent(manifest.spritesheetPath).standardizedFileURL
        guard spriteURL.path.hasPrefix(root.path + "/") else { throw PetManifestError.unsafeSpritePath }
        guard let source = CGImageSourceCreateWithURL(spriteURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PetManifestError.spriteMissing
        }
        let expectedWidth = columns * cellWidth
        let expectedHeight = rows * cellHeight
        guard image.width == expectedWidth, image.height == expectedHeight else {
            throw PetManifestError.invalidDimensions(width: image.width, height: image.height)
        }

        var frames: [[CGImage]] = []
        for row in 0..<rows {
            var rowFrames: [CGImage] = []
            for column in 0..<columns {
                let rect = CGRect(
                    x: column * cellWidth,
                    y: row * cellHeight,
                    width: cellWidth,
                    height: cellHeight
                )
                guard let frame = image.cropping(to: rect) else {
                    throw PetManifestError.cropFailed(row: row, column: column)
                }
                rowFrames.append(frame)
            }
            frames.append(rowFrames)
        }
        return PetAtlas(
            manifest: manifest,
            grid: PetGrid(columns: columns, rows: rows, cellWidth: cellWidth, cellHeight: cellHeight),
            spriteURL: spriteURL,
            frames: frames
        )
    }
}

enum PetState: String, Equatable, Sendable {
    case idle
    case waiting
    case running
    case review
    case failed

    var atlasRow: Int {
        switch self {
        case .idle: 0
        case .failed: 5
        case .waiting: 6
        case .running: 7
        case .review: 8
        }
    }

    static func from(session phase: SessionPhase) -> PetState {
        switch phase {
        case .listening: .waiting
        case .startingServer, .transcribing, .applying: .running
        case .ready: .review
        case .error: .failed
        case .idle: .idle
        }
    }
}
