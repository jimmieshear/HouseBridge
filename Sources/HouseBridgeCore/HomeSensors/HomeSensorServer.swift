import Foundation

/// A Unix-domain socket server for the HouseBridgeHomeKit helper. HomeKit only exists in the iOS SDK, so a small
/// Mac Catalyst app reads the accessories and sends one JSON object per line here; this class only moves lines.
///
/// The socket lives in the HouseBridge folder (0700 directory, 0600 socket): only this user can write to it.
public final class HomeSensorServer: @unchecked Sendable {
    public enum StartError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case alreadyListening
        case system(String, Int32)
        public var description: String {
            switch self {
            case .pathTooLong(let p): return "socket path is too long for a Unix socket: \(p)"
            case .alreadyListening: return "another HouseBridge is already listening for the HomeKit helper"
            case .system(let what, let code): return "\(what) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    private let path: String
    private let onLine: @Sendable (String) -> Void
    private let onClients: @Sendable (Int) -> Void
    private let queue = DispatchQueue(label: "housebridge.sensors")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, buffer: Data)] = [:]

    public init(path: String, onLine: @escaping @Sendable (String) -> Void, onClients: @escaping @Sendable (Int) -> Void) {
        self.path = path; self.onLine = onLine; self.onClients = onClients
    }

    private static func address(_ path: String) -> (sockaddr_un, socklen_t)? {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes); raw[bytes.count] = 0
        }
        return (addr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    public func start() throws {
        guard let (addr, length) = HomeSensorServer.address(path) else { throw StartError.pathTooLong(path) }
        // A live listener means a second HouseBridge; a leftover file from a crash can simply be replaced.
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        if probe >= 0 {
            var a = addr
            let connected = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(probe, $0, length) } } == 0
            close(probe)
            if connected { throw StartError.alreadyListening }
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket", errno) }
        var a = addr
        let bound = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) } }
        guard bound == 0 else { let e = errno; close(fd); throw StartError.system("bind", e) }
        chmod(path, 0o600)
        guard listen(fd, 4) == 0 else { let e = errno; close(fd); unlink(path); throw StartError.system("listen", e) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        acceptSource = source
        source.resume()
    }

    /// Synchronous, so a config reload can start the next server on the same path.
    public func stop() {
        queue.sync {
            acceptSource?.cancel(); acceptSource = nil
            if listener >= 0 { close(listener); listener = -1; unlink(path) }
            for (fd, client) in clients { client.source.cancel(); close(fd) }
            clients = [:]
        }
    }

    private func accept() {
        let fd = Foundation.accept(listener, nil, nil)
        guard fd >= 0 else { return }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.read(fd) }
        clients[fd] = (source, Data())
        source.resume()
        onClients(clients.count)
    }

    private func read(_ fd: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16384)
        let n = Foundation.read(fd, &chunk, chunk.count)
        if n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR) { drop(fd); return }
        guard n > 0, var client = clients[fd] else { return }
        client.buffer.append(contentsOf: chunk[0..<n])
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let lineData = client.buffer[client.buffer.startIndex..<newline]
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8), !line.isEmpty { onLine(line) }
        }
        if client.buffer.count > 1_000_000 { drop(fd); return }   // not a line-oriented peer
        clients[fd] = client
    }

    private func drop(_ fd: Int32) {
        clients.removeValue(forKey: fd)?.source.cancel()
        close(fd)
        onClients(clients.count)
    }
}
