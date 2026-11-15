import Foundation
import Network
import Security
import CryptoKit

// MARK: - SDP

/// The parts of a session description (RFC 4566) a camera client needs.
struct SDPMedia {
    var kind: String                 // "video" / "audio"
    var payloadType: Int
    var codec: String                // upper-cased rtpmap name, e.g. H264, MPEG4-GENERIC
    var clockRate: Int
    var channels: Int
    var control: String?
    var fmtp: [String: String]
}

enum SDP {
    static func parse(_ text: String) -> [SDPMedia] {
        var media: [SDPMedia] = []
        var rtpmaps: [Int: (String, Int, Int)] = [:]
        var fmtps: [Int: [String: String]] = [:]
        /// Attributes seen so far belong to the last `m=` section; apply them to it and start collecting afresh.
        func flush() {
            if let i = media.indices.last {
                if let m = rtpmaps[media[i].payloadType] { media[i].codec = m.0; media[i].clockRate = m.1; media[i].channels = m.2 }
                media[i].fmtp = fmtps[media[i].payloadType] ?? [:]
            }
            rtpmaps = [:]; fmtps = [:]
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("m=") {
                flush()
                let parts = line.dropFirst(2).split(separator: " ")
                guard parts.count >= 4, let pt = Int(parts[3]) else { continue }
                media.append(SDPMedia(kind: String(parts[0]), payloadType: pt, codec: "", clockRate: 90000, channels: 1, control: nil, fmtp: [:]))
            } else if line.hasPrefix("a="), let last = media.indices.last {
                let attr = line.dropFirst(2)
                if attr.hasPrefix("control:") { media[last].control = String(attr.dropFirst(8)) }
                else if attr.hasPrefix("rtpmap:") {
                    let rest = attr.dropFirst(7).split(separator: " ", maxSplits: 1)
                    guard rest.count == 2, let pt = Int(rest[0]) else { continue }
                    let enc = rest[1].split(separator: "/")
                    rtpmaps[pt] = (enc.first.map { $0.uppercased() } ?? "", enc.count > 1 ? Int(enc[1]) ?? 90000 : 90000, enc.count > 2 ? Int(enc[2]) ?? 1 : 1)
                } else if attr.hasPrefix("fmtp:") {
                    let rest = attr.dropFirst(5).split(separator: " ", maxSplits: 1)
                    guard rest.count == 2, let pt = Int(rest[0]) else { continue }
                    var map: [String: String] = [:]
                    for pair in rest[1].split(separator: ";") {
                        let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                        if kv.count == 2 { map[kv[0].lowercased()] = kv[1] }
                    }
                    fmtps[pt] = map
                }
            }
        }
        flush()
        return media
    }

    /// H.264 parameter sets from `sprop-parameter-sets` (base64, comma separated: SPS then PPS).
    static func parameterSets(_ fmtp: [String: String]) -> (sps: Data?, pps: Data?) {
        let parts = (fmtp["sprop-parameter-sets"] ?? "").split(separator: ",").compactMap { Data(base64Encoded: String($0)) }
        return (parts.first, parts.dropFirst().first)
    }
}

// MARK: - Transport

/// A byte pipe to the camera. Callbacks come on the queue the client owns.
protocol RTSPTransport: AnyObject {
    func connect(_ done: @escaping (Error?) -> Void)
    func send(_ data: Data)
    func close()
    var onData: ((Data) -> Void)? { get set }
    var onClose: ((Error?) -> Void)? { get set }
}

enum RTSPError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let m) = self { return m }; return "RTSP error" }
}

/// TCP, or TLS pinned to the console's certificate (trust on first use, like the rest of the UniFi connection).
final class NWRTSPTransport: RTSPTransport, @unchecked Sendable {
    var onData: ((Data) -> Void)?
    var onClose: ((Error?) -> Void)?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var finished = false

    init(host: String, port: Int, tls: Bool, hosts: KnownHosts?, queue: DispatchQueue) {
        self.queue = queue
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 10
        tcp.noDelay = true
        let params: NWParameters
        if tls {
            let options = NWProtocolTLS.Options()
            sec_protocol_options_set_verify_block(options.securityProtocolOptions, { _, trust, complete in
                let t = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let hosts, let chain = SecTrustCopyCertificateChain(t) as? [SecCertificate], let leaf = chain.first else { return complete(false) }
                let fingerprint = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
                // A separate pin from the HTTPS one: the streaming port may present its own certificate.
                complete(hosts.verify(host: "\(host):\(port)", fingerprint: fingerprint) != .mismatch)
            }, queue)
            params = NWParameters(tls: options, tcp: tcp)
        } else {
            params = NWParameters(tls: nil, tcp: tcp)
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(clamping: port)) ?? 554, using: params)
    }

    func connect(_ done: @escaping (Error?) -> Void) {
        var reported = false
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if !reported { reported = true; done(nil) }
                self.receive()
            case .failed(let error), .waiting(let error):
                if !reported { reported = true; done(error); self.connection.cancel() } else { self.finish(error) }
            case .cancelled: self.finish(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onData?(data) }
            if error != nil || complete { self.finish(error); return }
            self.receive()
        }
    }

    private func finish(_ error: Error?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
        onClose?(error)
    }

    func send(_ data: Data) { connection.send(content: data, completion: .contentProcessed { _ in }) }
    func close() { finish(nil) }
}

// MARK: - Client

/// An RTSP 1.0 player (RFC 2326): DESCRIBE, SETUP over interleaved TCP, PLAY, keepalive. Everything runs on `queue`,
/// including the packet callbacks. It never writes RTP, only reads what the camera sends.
final class RTSPClient: @unchecked Sendable {
    struct Response {
        var status: Int
        var headers: [String: String]
        var body: Data
    }

    private let url: URL
    private let transport: RTSPTransport
    private let queue: DispatchQueue
    private var buffer = Data()
    private var cseq = 0
    private var pending: [Int: (Result<Response, Error>) -> Void] = [:]
    private var session: String?
    private var keepalive: DispatchSourceTimer?
    private var closed = false
    private var channels: [UInt8: (SDPMedia, isRTCP: Bool)] = [:]

    /// Called for each RTP packet with the media description it belongs to.
    var onPacket: ((SDPMedia, RTPPacket) -> Void)?
    var onClose: ((Error?) -> Void)?

    init(url: URL, transport: RTSPTransport, queue: DispatchQueue) {
        self.url = url
        self.transport = transport
        self.queue = queue
        transport.onData = { [weak self] data in self?.queue.async { self?.receive(data) } }
        transport.onClose = { [weak self] error in self?.queue.async { self?.finish(error) } }
    }

    /// Connects, negotiates and starts the media flowing. `wanted` picks which of the offered tracks to set up.
    func play(wanted: @escaping ([SDPMedia]) -> [SDPMedia]) async throws -> [SDPMedia] {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            transport.connect { error in
                self.queue.async { if let error { c.resume(throwing: error) } else { c.resume() } }
            }
        }
        let describe = try await request("DESCRIBE", url.absoluteString, ["Accept": "application/sdp"])
        guard describe.status == 200 else { throw RTSPError.failed("DESCRIBE answered \(describe.status)") }
        let all = SDP.parse(String(decoding: describe.body, as: UTF8.self))
        let chosen = wanted(all)
        guard !chosen.isEmpty else { throw RTSPError.failed("the camera offers no usable stream") }
        let base = describe.headers["content-base"] ?? url.absoluteString

        var channel: UInt8 = 0
        for media in chosen {
            let control = media.control ?? ""
            let target = control.lowercased().hasPrefix("rtsp") ? control
                : control.isEmpty || control == "*" ? base : base + (base.hasSuffix("/") ? "" : "/") + control
            let setup = try await request("SETUP", target, ["Transport": "RTP/AVP/TCP;unicast;interleaved=\(channel)-\(channel + 1)"])
            guard setup.status == 200 else { throw RTSPError.failed("SETUP answered \(setup.status)") }
            if let header = setup.headers["session"] { session = String(header.split(separator: ";")[0]).trimmingCharacters(in: .whitespaces) }
            channels[channel] = (media, false)
            channels[channel + 1] = (media, true)
            channel += 2
        }
        let timeout = setupTimeout(from: nil)
        let play = try await request("PLAY", base, ["Range": "npt=0.000-"])
        guard play.status == 200 else { throw RTSPError.failed("PLAY answered \(play.status)") }
        startKeepalive(base: base, every: timeout)
        return chosen
    }

    private func setupTimeout(from header: String?) -> TimeInterval { 25 }

    func stop() {
        queue.async {
            guard !self.closed else { return }
            if self.session != nil { self.sendRequest("TEARDOWN", self.url.absoluteString, [:]) { _ in } }
            self.finish(nil)
        }
    }

    // MARK: Requests

    private func request(_ method: String, _ target: String, _ headers: [String: String]) async throws -> Response {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Response, Error>) in
            queue.async {
                if self.closed { return c.resume(throwing: RTSPError.failed("connection closed")) }
                self.sendRequest(method, target, headers) { c.resume(with: $0) }
            }
        }
    }

    private func sendRequest(_ method: String, _ target: String, _ headers: [String: String], completion: @escaping (Result<Response, Error>) -> Void) {
        cseq += 1
        var text = "\(method) \(target) RTSP/1.0\r\nCSeq: \(cseq)\r\nUser-Agent: HouseBridge\r\n"
        if let session { text += "Session: \(session)\r\n" }
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { text += "\(k): \(v)\r\n" }
        text += "\r\n"
        pending[cseq] = completion
        let number = cseq
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in   // a camera that never answers must not hang a viewer
            if let done = self?.pending.removeValue(forKey: number) { done(.failure(RTSPError.failed("\(method) timed out"))) }
        }
        transport.send(Data(text.utf8))
    }

    private func startKeepalive(base: String, every interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in self?.sendRequest("OPTIONS", base, [:]) { _ in } }
        timer.resume()
        keepalive = timer
    }

    // MARK: Input

    /// Responses and `$`-framed interleaved packets arrive on the same byte stream, in any mix.
    func receive(_ data: Data) {
        buffer.append(data)
        while !buffer.isEmpty, !closed {
            if buffer[buffer.startIndex] == 0x24 {   // '$'
                guard buffer.count >= 4 else { return }
                let length = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
                guard buffer.count >= 4 + length else { return }
                let channel = buffer[buffer.startIndex + 1]
                let payload = Data(buffer[(buffer.startIndex + 4)..<(buffer.startIndex + 4 + length)])
                buffer = Data(buffer.dropFirst(4 + length))
                if let (media, isRTCP) = channels[channel], !isRTCP, let packet = RTPPacket(payload) { onPacket?(media, packet) }
                continue
            }
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > 65536 { finish(RTSPError.failed("oversized RTSP header")) }
                return
            }
            let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let status = lines.removeFirst().split(separator: " ")
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            guard buffer.distance(from: end.upperBound, to: buffer.endIndex) >= length else { return }
            let bodyEnd = buffer.index(end.upperBound, offsetBy: length)
            let body = Data(buffer[end.upperBound..<bodyEnd])
            buffer = Data(buffer[bodyEnd...])
            guard status.count >= 2, status[0].hasPrefix("RTSP"), let code = Int(status[1]) else { finish(RTSPError.failed("bad RTSP response")); return }
            if let number = Int(headers["cseq"] ?? ""), let done = pending.removeValue(forKey: number) {
                done(.success(Response(status: code, headers: headers, body: body)))
            }
        }
    }

    private func finish(_ error: Error?) {
        guard !closed else { return }
        closed = true
        keepalive?.cancel(); keepalive = nil
        transport.close()
        for done in pending.values { done(.failure(error ?? RTSPError.failed("connection closed"))) }
        pending = [:]
        onClose?(error)
    }
}
