import XCTest
@testable import MaterialCapture

final class MaterialSharingTests: XCTestCase {
    func testShareItemsZipFoldersAndHonourTheSelection() throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appending(path: "share-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        let folder = staging.appending(path: "brick material")
        let bundle = folder.appending(path: "brick.pbrmaterial")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: bundle.appending(path: "manifest.json"))
        try Data(repeating: 7, count: 2048).write(to: bundle.appending(path: "albedo.png"))
        try Data("glb".utf8).write(to: folder.appending(path: "brick.glb"))
        let unreal = folder.appending(path: "brick-unreal")
        try fm.createDirectory(at: unreal, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: unreal.appending(path: "T_Brick_D.png"))
        try Data().write(to: folder.appending(path: ".hidden"))

        let everything = try MaterialSharing.items(forExportFolder: folder, selection: .everything)
        XCTAssertEqual(everything.map(\.lastPathComponent), ["brick.pbrmaterial.zip", "brick-unreal.zip", "brick.glb"])
        for item in everything { XCTAssertTrue(fm.fileExists(atPath: item.path), item.lastPathComponent) }
        // Archives are real zips ("PK" signature) and live inside the staging folder.
        let zip = try Data(contentsOf: everything[0])
        XCTAssertEqual(Array(zip.prefix(2)), [0x50, 0x4B])
        XCTAssertTrue(everything[0].path.hasPrefix(staging.path))

        let bundleOnly = try MaterialSharing.items(forExportFolder: folder, selection: .bundleOnly)
        XCTAssertEqual(bundleOnly.map(\.lastPathComponent), ["brick.pbrmaterial.zip"])
        let one = try MaterialSharing.items(forExportFolder: folder, selection: .target("glb"))
        XCTAssertFalse(one.contains { $0.lastPathComponent.hasPrefix("brick.pbrmaterial") })

        XCTAssertNil(MaterialSharing.Selection.everything.exportTargets)
        XCTAssertEqual(MaterialSharing.Selection.bundleOnly.exportTargets, [])
        XCTAssertEqual(MaterialSharing.Selection.target("usdz").exportTargets, ["usdz"])
    }
}
