import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FitJourney

struct MediaTests {
    private func tempStore(limits: MediaLimits = .standard) -> MediaStore {
        MediaStore(root: URL.temporaryDirectory.appending(path: "media-tests-\(UUID().uuidString)", directoryHint: .isDirectory), limits: limits)
    }

    /// PNG sintético de `width` x `height`.
    private func pngData(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0.4, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func fileNamesAreUniqueAndSanitized() {
        let a = MediaStore.makeFileName(ext: "jpg")
        let b = MediaStore.makeFileName(ext: "jpg")
        #expect(a != b)
        #expect(a.hasSuffix(".jpg"))
        #expect(MediaStore.makeFileName(ext: "../x/MOV").hasSuffix(".xmov"))
        #expect(!MediaStore.makeFileName(ext: "").contains("."))
    }

    @Test func rejectsUnsafeFileNames() {
        #expect(MediaStore.isSafe(fileName: "abc.jpg"))
        #expect(!MediaStore.isSafe(fileName: "../abc.jpg"))
        #expect(!MediaStore.isSafe(fileName: "a/b.jpg"))
        #expect(!MediaStore.isSafe(fileName: ".hidden"))
        #expect(!MediaStore.isSafe(fileName: ""))
        #expect(tempStore().url(for: "../escape") == nil)
    }

    @Test func videoLimits() {
        let limits = MediaLimits.standard
        #expect(MediaStore.violation(duration: 30, bytes: 10_000_000, limits: limits) == nil)
        #expect(MediaStore.violation(duration: 60, bytes: 10_000_000, limits: limits) == nil)
        #expect(MediaStore.violation(duration: 75, bytes: 10_000_000, limits: limits) == .videoTooLong(limit: 60))
        #expect(MediaStore.violation(duration: 10, bytes: 201 * 1_048_576, limits: limits) == .videoTooLarge(limitMB: 200))
        #expect(MediaStore.violation(duration: 10, bytes: 1000, limits: MediaLimits(maxVideoDuration: 5)) == .videoTooLong(limit: 5))
        #expect(MediaStoreError.videoTooLong(limit: 60).errorDescription?.contains("60") == true)
    }

    @Test func fileNamesOfMedia() {
        #expect(MediaStore.fileNames(of: .image(fileName: "a.jpg")) == ["a.jpg"])
        #expect(MediaStore.fileNames(of: .localVideo(fileName: "v.mov", thumbnailFileName: "t.jpg")) == ["v.mov", "t.jpg"])
        #expect(MediaStore.fileNames(of: .localVideo(fileName: "v.mov", thumbnailFileName: nil)) == ["v.mov"])
        #expect(MediaStore.fileNames(of: .externalVideo(url: URL(string: "https://youtu.be/dQw4w9WgXcQ")!, provider: .youtube, videoID: "dQw4w9WgXcQ")).isEmpty)
    }

    @Test func savesImageDownscaledAndDeletesIt() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let name = try await store.saveImage(data: try pngData(width: 4000, height: 1000))
        let url = try #require(store.url(for: name))
        #expect(FileManager.default.fileExists(atPath: url.path()))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require(props[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(props[kCGImagePropertyPixelHeight] as? Int)
        #expect(max(width, height) <= 2048)
        #expect(width > height)

        store.delete(.image(fileName: name))
        #expect(!FileManager.default.fileExists(atPath: url.path()))
    }

    @Test func smallImageIsNotUpscaled() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let name = try await store.saveImage(data: try pngData(width: 300, height: 200))
        let url = try #require(store.url(for: name))
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((props[kCGImagePropertyPixelWidth] as? Int) == 300)
    }

    @Test func unreadableImageFails() async {
        let store = tempStore()
        await #expect(throws: MediaStoreError.unreadableImage) {
            _ = try await store.saveImage(data: Data("not an image".utf8))
        }
    }

    @Test func duplicateCopiesFilesAndKeepsLinks() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let name = try await store.saveImage(data: try pngData(width: 100, height: 100))
        let copy = try await store.duplicate(.image(fileName: name))
        guard case .image(let copyName) = copy else { Issue.record("esperava imagem"); return }
        #expect(copyName != name)
        store.delete(.image(fileName: name))
        let copyURL = try #require(store.url(for: copyName))
        #expect(FileManager.default.fileExists(atPath: copyURL.path()))
        let link = MediaRef.externalVideo(url: URL(string: "https://vimeo.com/123")!, provider: .vimeo, videoID: "123")
        #expect(try await store.duplicate(link) == link)
    }

    @Test func purgeRemovesOnlyOrphans() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let keep = try await store.saveImage(data: try pngData(width: 50, height: 50))
        let orphan = try await store.saveImage(data: try pngData(width: 50, height: 50))
        #expect(store.purgeOrphans(keeping: [keep]) == 1)
        let keepURL = try #require(store.url(for: keep))
        let orphanURL = try #require(store.url(for: orphan))
        #expect(FileManager.default.fileExists(atPath: keepURL.path()))
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path()))
    }

    @Test func deletingMissingFileIsHarmless() {
        tempStore().delete(.image(fileName: "nao-existe.jpg"))
    }
}

struct ExerciseFilterTests {
    @Test func searchIgnoresAccentsAndCase() {
        var filter = ExerciseFilter()
        filter.query = "TRAPEZIO"
        #expect(filter.matches(name: "Encolhimento de trapézio", primary: [.traps], secondary: [], equipment: .dumbbell))
        filter.query = "supino halteres"
        #expect(filter.matches(name: "Supino reto com halteres", primary: [.chest], secondary: [], equipment: .dumbbell))
        filter.query = "supino agachamento"
        #expect(!filter.matches(name: "Supino reto com halteres", primary: [.chest], secondary: [], equipment: .dumbbell))
    }

    @Test func englishNameMatches() {
        var filter = ExerciseFilter()
        filter.query = "bench"
        #expect(filter.matches(name: "Supino reto com barra", englishName: "Barbell Bench Press", primary: [.chest], secondary: [], equipment: .barbell))
    }

    @Test func musclesAndEquipmentFilters() {
        var filter = ExerciseFilter()
        filter.muscles = [.triceps]
        #expect(filter.matches(name: "Supino", primary: [.chest], secondary: [.triceps], equipment: .barbell))
        #expect(!filter.matches(name: "Rosca", primary: [.biceps], secondary: [], equipment: .barbell))
        filter.equipment = [.cable]
        #expect(!filter.matches(name: "Supino", primary: [.chest], secondary: [.triceps], equipment: .barbell))
        #expect(filter.isActive)
        #expect(!ExerciseFilter().isActive)
    }
}
