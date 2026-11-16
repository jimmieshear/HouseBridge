import Foundation
import CryptoKit
import Security
import Matter

public enum MatterError: Error, CustomStringConvertible {
    case badCode, startFailed(String), timeout(String), failed(String), unknownNode(UInt64)
    public var description: String {
        switch self {
        case .badCode: return "that is not a valid Matter setup code (use the 11/21-digit manual code or the MT:… text of the QR code)"
        case .startFailed(let m): return "Matter controller did not start: \(m)"
        case .timeout(let m): return "timed out \(m)"
        case .failed(let m): return m
        case .unknownNode(let id): return "no commissioned node \(id)"
        }
    }
}

/// Our fabric's signing key as an `MTRKeypair`: ECDSA P-256 over SHA-256, which is what CryptoKit's `signature(for:)` does.
private final class FabricKeypair: NSObject, MTRKeypair {
    private let key: P256.Signing.PrivateKey
    init(raw: Data) throws { key = try P256.Signing.PrivateKey(rawRepresentation: raw) }

    private lazy var publicSecKey: SecKey = {
        let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        return SecKeyCreateWithData(key.publicKey.x963Representation as CFData, attrs as CFDictionary, nil)!
    }()
    @objc(copyPublicKey) func copyPublicKey() -> SecKey { publicSecKey }
    /// macOS 15.0-15.3 only know the non-retaining form (we keep the key alive for the controller's lifetime).
    @objc(publicKey) func publicKey() -> Unmanaged<SecKey> { Unmanaged.passUnretained(publicSecKey) }
    func signMessageECDSA_RAW(_ message: Data) -> Data {
        (try? key.signature(for: message).rawRepresentation) ?? Data()
    }
    func signMessageECDSA_DER(_ message: Data) -> Data {
        (try? key.signature(for: message).derRepresentation) ?? Data()
    }
}

private final class FileStorage: NSObject, MTRStorage {
    let store: MatterStore
    init(_ store: MatterStore) { self.store = store }
    func storageData(forKey key: String) -> Data? { store.data(forKey: key) }
    func setStorageData(_ value: Data, forKey key: String) -> Bool { store.set(value, forKey: key); return true }
    func removeStorageData(forKey key: String) -> Bool { store.remove(key: key); return true }
}

/// Our own Matter controller on a private fabric (multi-admin: the device stays paired to Apple Home, we are a second admin).
/// Stage 1: pair a device with a code from Home.app and read everything it exposes.
public final class MatterController: NSObject, MTRDeviceControllerDelegate, MTRDeviceAttestationDelegate, @unchecked Sendable {
    public let store: MatterStore
    private let log: @Sendable (LogEntry) -> Void
    private var controller: MTRDeviceController?
    private let queue = DispatchQueue(label: "housebridge.matter")
    private let lock = NSLock()
    private var pairing: (nodeID: NSNumber, cont: CheckedContinuation<Void, Error>)?

    public init(store: MatterStore, log: @escaping @Sendable (LogEntry) -> Void = { _ in }) {
        self.store = store
        self.log = log
    }

    // MARK: Lifecycle
    public func start() throws {
        guard controller == nil else { return }
        let factory = MTRDeviceControllerFactory.sharedInstance()
        let params = MTRDeviceControllerFactoryParams(storage: FileStorage(store))
        do { try factory.start(params) } catch { throw MatterError.startFailed("factory: " + describeError(error)) }
        let keypair: FabricKeypair
        do { keypair = try FabricKeypair(raw: store.rootKey) } catch { throw MatterError.startFailed("stored root key is unusable: \(error)") }
        let startup = MTRDeviceControllerStartupParams(ipk: store.ipk, fabricID: NSNumber(value: store.fabricID), nocSigner: keypair)
        startup.vendorID = NSNumber(value: MatterStore.vendorID)
        do {
            if store.fabricCreated { controller = try factory.createController(onExistingFabric: startup) }
            else { controller = try factory.createController(onNewFabric: startup); store.fabricCreated = true }
        } catch { throw MatterError.startFailed("controller: " + describeError(error)) }
        guard let controller else { throw MatterError.startFailed("no controller returned") }
        controller.setDeviceControllerDelegate(self, queue: queue)
        log(LogEntry(category: "matter", message: "controller started on fabric \(store.fabricID), \(store.nodes.count) node(s)"))
    }

    public func stop() {
        controller?.shutdown()
        controller = nil
        MTRDeviceControllerFactory.sharedInstance().stop()
    }

    // MARK: Pairing
    /// Joins a device that is already in Apple Home: in Home.app open the accessory → Settings → "Turn On Pairing Mode" and pass the code shown.
    public func pair(code: String, name: String?, timeout: TimeInterval = 120) async throws -> UInt64 {
        guard let controller else { throw MatterError.startFailed("start() was not called") }
        let payload = try Self.parse(code: code)
        let nodeID = NSNumber(value: store.allocateNodeID())
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    lock.withLock { pairing = (nodeID, cont) }
                    do { try controller.setupCommissioningSession(with: payload, newNodeID: nodeID) }
                    catch { finishPairing(error) }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw MatterError.timeout("after \(Int(timeout)) s waiting for the device. Is the pairing code still valid (they expire after ~3 minutes) and is this Mac on the device's network?")
            }
            defer { group.cancelAll() }
            do { try await group.next() }
            catch { _ = try? controller.cancelCommissioning(forNodeID: nodeID); finishPairing(error); throw error }
        }
        store.addNode(nodeID.uint64Value, name: name)
        log(LogEntry(category: "matter", message: "commissioned node \(nodeID)\(name.map { " as ‘\($0)’" } ?? "")"))
        return nodeID.uint64Value
    }

    /// Accepts the manual code (with or without dashes/spaces) or the `MT:…` QR text.
    public static func parse(code: String) throws -> MTRSetupPayload {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
        guard let payload = MTRSetupPayload(payload: cleaned) else { throw MatterError.badCode }
        return payload
    }

    private func finishPairing(_ error: Error?) {
        let p = lock.withLock { () -> (nodeID: NSNumber, cont: CheckedContinuation<Void, Error>)? in defer { pairing = nil }; return pairing }
        guard let p else { return }
        if let error { p.cont.resume(throwing: error) } else { p.cont.resume() }
    }

    public func controller(_ controller: MTRDeviceController, commissioningSessionEstablishmentDone error: Error?) {
        if let error { log(LogEntry(level: .error, category: "matter", message: "session setup failed: \(describeError(error))")); finishPairing(error); return }
        guard let id = lock.withLock({ pairing?.nodeID }) else { return }
        log(LogEntry(category: "matter", message: "secure session with the device established; commissioning"))
        let params = MTRCommissioningParameters()
        params.deviceAttestationDelegate = self
        if #available(macOS 15.4, *) { params.readEndpointInformation = true }
        do { try controller.commissionNode(withID: id, commissioningParams: params) } catch { finishPairing(error) }
    }

    /// Production devices are signed by CSA-approved authorities. We carry no PAA store, so a failed check is logged and accepted:
    /// the person holding the pairing code is the one vouching for the device.
    public func deviceAttestationFailed(for controller: MTRDeviceController, opaqueDeviceHandle: UnsafeMutableRawPointer, error: Error) {
        log(LogEntry(level: .warning, category: "matter", message: "device attestation not verified (\(describeError(error))); continuing"))
        do { try controller.continueCommissioningDevice(opaqueDeviceHandle, ignoreAttestationFailure: true) } catch { finishPairing(error) }
    }

    public func controller(_ controller: MTRDeviceController, commissioningComplete error: Error?, nodeID: NSNumber?) {
        if let error { log(LogEntry(level: .error, category: "matter", message: "commissioning failed: \(describeError(error))")) }
        finishPairing(error)
    }

    // MARK: Reading
    /// Reads every attribute of every endpoint (wildcard read), grouped as endpoint → cluster → [attribute: value].
    public func readEverything(node: UInt64, timeout: TimeInterval = 60) async throws -> [Int: [Int: [Int: String]]] {
        guard let controller else { throw MatterError.startFailed("start() was not called") }
        guard store.nodes.contains(where: { $0.id == node }) else { throw MatterError.unknownNode(node) }
        let device = MTRBaseDevice(nodeID: NSNumber(value: node), controller: controller)
        let values: [[String: Any]] = try await withCheckedThrowingContinuation { cont in
            device.readAttributes(withEndpointID: nil, clusterID: nil, attributeID: nil, params: nil, queue: queue) { values, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: values ?? []) }
            }
        }
        var out: [Int: [Int: [Int: String]]] = [:]
        for item in values {
            guard let path = item[MTRAttributePathKey] as? MTRAttributePath else { continue }
            let text: String
            if let data = item[MTRDataKey] as? [String: Any] { text = Self.render(data) }
            else if let err = item[MTRErrorKey] as? NSError { text = "(error \(err.code))" }
            else { continue }
            out[path.endpoint.intValue, default: [:]][path.cluster.intValue, default: [:]][path.attribute.intValue] = text
        }
        return out
    }

    /// Short text for a Matter data value (`{type, value}` dictionaries, nested for structs and lists).
    static func render(_ data: [String: Any]) -> String {
        let type = data[MTRTypeKey] as? String ?? ""
        let value = data[MTRValueKey]
        switch type {
        case MTRNullValueType: return "null"
        case MTRArrayValueType:
            let items = (value as? [[String: Any]] ?? []).compactMap { $0[MTRDataKey] as? [String: Any] }.map(render)
            return "[" + items.joined(separator: ", ") + "]"
        case MTRStructureValueType:
            let fields = (value as? [[String: Any]] ?? []).map { f -> String in
                let tag = (f[MTRContextTagKey] as? NSNumber)?.intValue ?? -1
                return "\(tag): " + render(f[MTRDataKey] as? [String: Any] ?? [:])
            }
            return "{" + fields.joined(separator: ", ") + "}"
        case MTROctetStringValueType: return "0x" + ((value as? Data) ?? Data()).map { String(format: "%02x", $0) }.joined()
        default: return value.map { "\($0)" } ?? "?"
        }
    }

    public func unpair(node: UInt64) {
        if #available(macOS 15.4, *) { controller?.forgetDevice(withNodeID: NSNumber(value: node)) }
        store.removeNode(node)
    }
}

// MARK: Names for the output of `list matter`
public enum MatterNames {
    public static let clusters: [Int: String] = [
        0x1D: "Descriptor", 0x28: "Basic Information", 0x2F: "Power Source", 0x3C: "Administrator Commissioning",
        0x5C: "Smoke CO Alarm", 0x400: "Illuminance Measurement", 0x402: "Temperature Measurement",
        0x403: "Pressure Measurement", 0x405: "Relative Humidity Measurement", 0x406: "Occupancy Sensing",
        0x42A: "CO Concentration", 0x42B: "Nitrogen Dioxide Concentration", 0x42C: "Ozone Concentration",
        0x42D: "PM2.5 Concentration", 0x42E: "Formaldehyde Concentration", 0x42F: "PM1 Concentration",
        0x430: "PM10 Concentration", 0x431: "Total VOC Concentration", 0x432: "Radon Concentration",
        0x5B: "Air Quality", 0x45: "Boolean State", 0x3B: "Generic Switch", 0x6: "On/Off", 0x8: "Level Control",
    ]
    public static let deviceTypes: [Int: String] = [
        0x15: "Contact Sensor", 0x106: "Light Sensor", 0x107: "Occupancy Sensor", 0x302: "Temperature Sensor",
        0x307: "Humidity Sensor", 0x76: "Smoke CO Alarm", 0x2C: "Air Quality Sensor", 0x11: "Bridged/Root Node",
        0x16: "Root Node", 0x13: "Bridged Node", 0xF: "Generic Switch",
    ]
}
