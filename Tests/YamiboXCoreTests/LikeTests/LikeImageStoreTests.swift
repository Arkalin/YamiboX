import Foundation
import Testing
@testable import YamiboXCore

@Test func likeImageStoreSavesLoadsDeletesAndDeletesAll() async throws {
    let store = LikeImageStore(baseDirectory: makeLikeImageStoreTestDirectory(prefix: "like-image-basic"))
    let firstData = Data(repeating: 3, count: 32)
    let secondData = Data(repeating: 8, count: 48)
    let jpegURL = try #require(URL(string: "https://img.example.com/a.JPG?x=1"))
    let noExtensionURL = try #require(URL(string: "https://img.example.com/a"))

    try await store.save(firstData, id: "first", sourceURL: jpegURL)
    try await store.save(secondData, id: "second", sourceURL: noExtensionURL)

    #expect(await store.loadData(id: "first") == firstData)
    #expect(await store.loadData(id: "second") == secondData)
    #expect(await store.fileExists(id: "first"))
    #expect(await store.fileExists(id: "missing") == false)

    try await store.delete(id: "first")
    #expect(await store.loadData(id: "first") == nil)
    #expect(await store.loadData(id: "second") == secondData)

    try await store.deleteAll()
    #expect(await store.loadData(id: "second") == nil)
}

@Test func likeImageStoreOverwriteRemovesStaleExtensionFile() async throws {
    let baseDirectory = makeLikeImageStoreTestDirectory(prefix: "like-image-overwrite")
    let store = LikeImageStore(baseDirectory: baseDirectory)
    let jpegURL = try #require(URL(string: "https://img.example.com/a.jpg"))
    let pngURL = try #require(URL(string: "https://img.example.com/a.png"))

    try await store.save(Data([1, 2, 3]), id: "x", sourceURL: jpegURL)
    try await store.save(Data([4, 5, 6]), id: "x", sourceURL: pngURL)

    let contents = try FileManager.default.contentsOfDirectory(at: baseDirectory, includingPropertiesForKeys: nil)
    #expect(contents.count == 1)
    #expect(contents.first?.pathExtension == "png")
    #expect(await store.loadData(id: "x") == Data([4, 5, 6]))
}

private func makeLikeImageStoreTestDirectory(prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}
