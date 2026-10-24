import Foundation
import Network

/// Advertises the bridge over Bonjour (`_hap._tcp`) and hands each TCP connection to `HAPServer`.
/// Everything runs on `queue`, which is also the queue the owner must use to touch the server.
final class HAPListener {
    private let server: HAPServer
    private let queue: DispatchQueue
    private let name: String
    private let txt: () -> [String: String]
    private let log: (String) -> Void
    private var listener: NWListener?

    init(server: HAPServer, queue: DispatchQueue, name: String, txt: @escaping () -> [String: String],
         log: @escaping (String) -> Void) {
        self.server = server
        self.queue = queue
        self.name = name
        self.txt = txt
        self.log = log
    }

    /// `ready` is called with the TCP port once the listener is accepting connections.
    func start(port: UInt16?, ready: @escaping (UInt16) -> Void, failed: @escaping (Error) -> Void) throws {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)?.noDelay = true
        let endpointPort = port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.service = makeService()
        listener.stateUpdateHandler = { [weak listener] state in
            switch state {
            case .ready: if let p = listener?.port?.rawValue { ready(p) }
            case .failed(let error): failed(error)
            default: break
            }
        }
        listener.serviceRegistrationUpdateHandler = { [log] change in
            if case .add(let endpoint) = change { log("advertising as \(endpoint)") }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        server.closeConnections(controller: nil)
    }

    /// Republishes the TXT record after `c#` or the paired flag changes.
    func refreshAdvertisement() { listener?.service = makeService() }

    private func makeService() -> NWListener.Service {
        NWListener.Service(name: name, type: "_hap._tcp", domain: nil, txtRecord: NWTXTRecord(txt()))
    }

    private func accept(_ nw: NWConnection) {
        let connection = server.newConnection()
        connection.send = { data, thenClose in
            nw.send(content: data, completion: .contentProcessed { _ in if thenClose { nw.cancel() } })
        }
        connection.close = { nw.cancel() }
        nw.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                nw.stateUpdateHandler = nil
                connection.connectionDidClose()
            default: break
            }
        }
        nw.start(queue: queue)
        receive(nw, connection)
    }

    private func receive(_ nw: NWConnection, _ connection: HAPConnection) {
        nw.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            if let data, !data.isEmpty { connection.receive(data) }
            if complete || error != nil { nw.cancel(); return }
            self?.receive(nw, connection)
        }
    }
}
