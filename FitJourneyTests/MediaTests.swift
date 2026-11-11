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

// MARK: - Revisão: cancelamento, duplicação, referências, WebView

struct MediaRobustnessTests {
    private func tempStore(limits: MediaLimits = .standard) -> MediaStore {
        MediaStore(root: URL.temporaryDirectory.appending(path: "media-tests-\(UUID().uuidString)", directoryHint: .isDirectory), limits: limits)
    }

    private func files(in store: MediaStore) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: store.root.path())) ?? []
    }

    private func png() throws -> Data {
        let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    @Test func cancelledImageSaveWritesNothing() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let data = try png()
        let task = Task { () -> String in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.saveImage(data: data)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(files(in: store).isEmpty)
    }

    @Test func videoSizeIsValidatedFirstAndNothingIsCopied() async throws {
        let store = tempStore(limits: MediaLimits(maxVideoBytes: 10))
        defer { try? FileManager.default.removeItem(at: store.root) }
        let source = URL.temporaryDirectory.appending(path: "big-\(UUID().uuidString).mov")
        try Data(count: 100).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        await #expect(throws: MediaStoreError.videoTooLarge(limitMB: 0)) { _ = try await store.saveVideo(from: source) }
        #expect(files(in: store).isEmpty)
    }

    @Test func unreadableOrMissingVideoFailsClearly() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let garbage = URL.temporaryDirectory.appending(path: "garbage-\(UUID().uuidString).mov")
        try Data("nope".utf8).write(to: garbage)
        defer { try? FileManager.default.removeItem(at: garbage) }
        await #expect(throws: MediaStoreError.unreadableVideo) { _ = try await store.saveVideo(from: garbage) }
        // Tamanho ilegível (arquivo inexistente) é erro, não 0 byte.
        let missing = URL.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).mov")
        await #expect(throws: MediaStoreError.unreadableVideo) { _ = try await store.saveVideo(from: missing) }
        #expect(files(in: store).isEmpty)
    }

    @Test func partialDuplicateFailureCleansCopies() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let good = try await store.saveImage(data: try png())
        let before = Set(files(in: store))
        await #expect(throws: (any Error).self) {
            _ = try await store.duplicate([.image(fileName: good), .image(fileName: "ausente.jpg")])
        }
        #expect(Set(files(in: store)) == before)
    }

    @Test func purgeIgnoresDirectories() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        try FileManager.default.createDirectory(at: store.root.appending(path: "subdir"), withIntermediateDirectories: true)
        #expect(store.purgeOrphans(keeping: []) == 0)
        #expect(files(in: store) == ["subdir"])
    }

    @MainActor
    @Test func deleteKeepsFilesReferencedByAnotherExercise() async throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let container = try PersistenceController.makeContainer(inMemory: true)
        let context = container.mainContext
        let name = try await store.saveImage(data: try png())
        let other = try await store.saveImage(data: try png())
        let a = Exercise(name: "A"), b = Exercise(name: "B")
        a.media = [.image(fileName: name), .image(fileName: other)]
        b.media = [.image(fileName: name)]
        context.insert(a); context.insert(b)
        try context.save()

        let removed = a.media
        a.media = []
        try context.save()
        store.deleteUnreferenced(removed, in: context)
        let nameURL = try #require(store.url(for: name))
        let otherURL = try #require(store.url(for: other))
        #expect(FileManager.default.fileExists(atPath: nameURL.path()))   // B ainda usa
        #expect(!FileManager.default.fileExists(atPath: otherURL.path())) // ninguém usa
    }

    @MainActor
    @Test func maintenancePurgesOrphansAndOldTemporaries() async throws {
        let store = tempStore()
        let temp = URL.temporaryDirectory.appending(path: "fj-temp-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: store.root); try? FileManager.default.removeItem(at: temp) }
        let container = try PersistenceController.makeContainer(inMemory: true)
        let keep = try await store.saveImage(data: try png())
        let orphan = try await store.saveImage(data: try png())
        let exercise = Exercise(name: "A")
        exercise.media = [.image(fileName: keep)]
        container.mainContext.insert(exercise)
        try container.mainContext.save()

        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let old = temp.appending(path: "old.mov"), fresh = temp.appending(path: "fresh.mov")
        try Data(count: 1).write(to: old); try Data(count: 1).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3 * 86400)], ofItemAtPath: old.path())

        let removed = await MediaMaintenance.runAtLaunch(container: container, store: store, temporaryDirectory: temp)
        #expect(removed == 2)
        let keepURL = try #require(store.url(for: keep))
        let orphanURL = try #require(store.url(for: orphan))
        #expect(FileManager.default.fileExists(atPath: keepURL.path()))
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path()))
        #expect(!FileManager.default.fileExists(atPath: old.path()))
        #expect(FileManager.default.fileExists(atPath: fresh.path()))
    }
}

struct EmbedPolicyTests {
    private let base = URL(string: "https://www.youtube-nocookie.com/")!

    @Test func embedURLRevalidatesIDs() {
        #expect(EmbedPolicy.embedURL(provider: .youtube, videoID: "dQw4w9WgXcQ")?.absoluteString.hasPrefix("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?") == true)
        #expect(EmbedPolicy.embedURL(provider: .youtube, videoID: "x\"><script>") == nil)
        #expect(EmbedPolicy.embedURL(provider: .youtube, videoID: "short") == nil)
        #expect(EmbedPolicy.embedURL(provider: .vimeo, videoID: "123456")?.host() == "player.vimeo.com")
        #expect(EmbedPolicy.embedURL(provider: .vimeo, videoID: "12a") == nil)
        #expect(EmbedPolicy.embedURL(provider: .other, videoID: nil) == nil)
    }

    @Test func watchURLFallsBackOnlyToHTTP() {
        let stored = URL(string: "https://example.com/v")!
        #expect(EmbedPolicy.watchURL(provider: .youtube, videoID: "dQw4w9WgXcQ", stored: stored)?.absoluteString == "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        #expect(EmbedPolicy.watchURL(provider: .youtube, videoID: "bad", stored: stored) == stored)
        #expect(EmbedPolicy.watchURL(provider: .other, videoID: nil, stored: URL(string: "javascript:alert(1)")!) == nil)
    }

    @Test func mainFrameOnlyInitialLoad() {
        #expect(EmbedPolicy.allowsNavigation(to: URL(string: "about:blank"), isMainFrame: true, baseURL: base))
        #expect(EmbedPolicy.allowsNavigation(to: base, isMainFrame: true, baseURL: base))
        #expect(!EmbedPolicy.allowsNavigation(to: URL(string: "https://evil.example/"), isMainFrame: true, baseURL: base))
        #expect(!EmbedPolicy.allowsNavigation(to: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), isMainFrame: true, baseURL: base))
    }

    @Test func subframesOnlyAllowlistedHTTPSHosts() {
        func allows(_ s: String) -> Bool { EmbedPolicy.allowsNavigation(to: URL(string: s), isMainFrame: false, baseURL: base) }
        #expect(allows("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?playsinline=1"))
        #expect(allows("https://player.vimeo.com/video/123"))
        #expect(allows("about:blank"))
        #expect(!allows("http://www.youtube-nocookie.com/embed/x"))
        #expect(!allows("https://youtube-nocookie.com.evil.example/embed"))
        #expect(!allows("https://evil.example/"))
        #expect(!allows("javascript:alert(1)"))
        #expect(!EmbedPolicy.allowsNavigation(to: URL(string: "https://player.vimeo.com/video/1"), isMainFrame: false, targetIsNil: true, baseURL: base))
    }

    @Test func htmlIsSandboxed() throws {
        let url = try #require(EmbedPolicy.embedURL(provider: .youtube, videoID: "dQw4w9WgXcQ"))
        #expect(EmbedPolicy.html(embedURL: url).contains("sandbox=\"allow-scripts allow-same-origin allow-presentation\""))
    }
}
