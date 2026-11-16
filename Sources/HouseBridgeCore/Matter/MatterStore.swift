import Foundation
import CryptoKit

/// Everything the Matter controller must remember, in `matter.json` (0600): our own fabric (root key, IPK, ids), the nodes
/// we commissioned, and the key/value blobs Matter.framework asks us to keep (`MTRStorage`: fabric table, CASE resumption, ...).
/// The root key can issue certificates for devices on this fabric, so the file is a secret like `homekit.json`.
public final class MatterStore: @unchecked Sendable {
    public struct Node: Codable, Sendable { public var id: UInt64; public var name: String?; public var added: Date }
    struct Model: Codable {
        var rootKey: Data                 // raw P-256 private key
        var ipk: Data                     // 16 bytes
        var fabricID: UInt64 = 1
        var fabricCreated = false         // false until createControllerOnNewFabric has succeeded once
        var nextNodeID: UInt64 = 0x4842_0001   // "HB" + counter: ids we hand to devices we commission
        var nodes: [Node] = []
        var storage: [String: Data] = [:]
    }

    /// Vendor id for a self-made controller: 0xFFF1 is the CSA test range, which needs no registration.
    public static let vendorID: UInt16 = 0xFFF1

    private let url: URL
    private let lock = NSLock()
    private var model: Model

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let m = try? JSONDecoder.iso.decode(Model.self, from: data) {
            model = m
        } else {
            model = Model(rootKey: P256.Signing.PrivateKey().rawRepresentation,
                          ipk: Data((0..<16).map { _ in UInt8.random(in: 0...255) }))
            save()
        }
    }

    public var rootKey: Data { lock.withLock { model.rootKey } }
    public var ipk: Data { lock.withLock { model.ipk } }
    public var fabricID: UInt64 { lock.withLock { model.fabricID } }
    public var fabricCreated: Bool {
        get { lock.withLock { model.fabricCreated } }
        set { mutate { $0.fabricCreated = newValue } }
    }
    public var nodes: [Node] { lock.withLock { model.nodes } }

    public func allocateNodeID() -> UInt64 {
        mutate { let id = $0.nextNodeID; $0.nextNodeID += 1; return id }
    }
    public func addNode(_ id: UInt64, name: String?) {
        mutate { $0.nodes.removeAll { $0.id == id }; $0.nodes.append(Node(id: id, name: name, added: Date())) }
    }
    public func removeNode(_ id: UInt64) { mutate { $0.nodes.removeAll { $0.id == id } } }

    // MARK: MTRStorage backing
    func data(forKey key: String) -> Data? { lock.withLock { model.storage[key] } }
    func set(_ value: Data, forKey key: String) { mutate { $0.storage[key] = value } }
    func remove(key: String) { mutate { $0.storage.removeValue(forKey: key) } }

    @discardableResult
    private func mutate<T>(_ change: (inout Model) -> T) -> T {
        let result: T = lock.withLock { change(&model) }
        save()
        return result
    }

    private func save() {
        let data = lock.withLock { try? JSONEncoder.iso.encode(model) }
        guard let data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
}
private extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
