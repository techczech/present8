import Foundation
import AppKit
import CryptoKit

final class SlideScreenshotStore {
    private let fileManager = FileManager.default
    private let screenshotsDirectoryName = "screenshots"

    func ensureScreenshotsDirectory(in deckFolderURL: URL) -> Bool {
        let directoryURL = screenshotsDirectoryURL(in: deckFolderURL)
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    func screenshotURL(for item: DeckItem, deckFolderURL: URL) -> URL {
        let filename = "\(Self.hashHex(item.cacheKey)).jpg"
        return screenshotsDirectoryURL(in: deckFolderURL).appendingPathComponent(filename, isDirectory: false)
    }

    func existingScreenshotURL(for item: DeckItem, deckFolderURL: URL) -> URL? {
        let fileURL = screenshotURL(for: item, deckFolderURL: deckFolderURL)
        return fileManager.isReadableFile(atPath: fileURL.path) ? fileURL : nil
    }

    func previewToken(for item: DeckItem) -> String {
        String(Self.hashHex(item.cacheKey).prefix(16))
    }

    func writeJPEG(_ data: Data, for item: DeckItem, deckFolderURL: URL) -> Bool {
        guard ensureScreenshotsDirectory(in: deckFolderURL) else { return false }
        let destinationURL = screenshotURL(for: item, deckFolderURL: deckFolderURL)
        do {
            try data.write(to: destinationURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func jpegData(from image: NSImage, compression: CGFloat = 0.82) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff) else {
            return nil
        }

        return representation.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }

    private func screenshotsDirectoryURL(in deckFolderURL: URL) -> URL {
        deckFolderURL.appendingPathComponent(screenshotsDirectoryName, isDirectory: true)
    }

    private static func hashHex(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
