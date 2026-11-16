import XCTest
@testable import HouseBridgeCore

final class MatterTests: XCTestCase {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("hb-matter-\(UUID().uuidString)/matter.json")
    }

    func testStorePersistsFabricNodesAndStorageWithPrivateMode() throws {
        let url = tempFile()
        let a = MatterStore(url: url)
        let id1 = a.allocateNodeID(), id2 = a.allocateNodeID()
        XCTAssertEqual(id2, id1 + 1)
        a.addNode(id1, name: "Owl")
        a.set(Data([1, 2, 3]), forKey: "k")
        a.fabricCreated = true

        let b = MatterStore(url: url)
        XCTAssertEqual(b.rootKey, a.rootKey)
        XCTAssertEqual(b.ipk.count, 16)
        XCTAssertEqual(b.nodes.map(\.id), [id1])
        XCTAssertEqual(b.nodes.first?.name, "Owl")
        XCTAssertEqual(b.data(forKey: "k"), Data([1, 2, 3]))
        XCTAssertTrue(b.fabricCreated)
        XCTAssertGreaterThan(b.allocateNodeID(), id2, "ids are never reused after a restart")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        b.removeNode(id1)
        XCTAssertTrue(MatterStore(url: url).nodes.isEmpty)
    }

    func testSetupCodeParsing() throws {
        // The connectedhomeip example code: passcode 20202021, discriminator 3840.
        let p = try MatterController.parse(code: "3497-011-2332")
        XCTAssertEqual(p.setupPasscode.intValue, 20202021)
        XCTAssertThrowsError(try MatterController.parse(code: "123"))
        XCTAssertThrowsError(try MatterController.parse(code: "hello"))
    }
}
