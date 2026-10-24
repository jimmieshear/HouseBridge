import Foundation

/// HomeKit's TLV8 encoding: type byte, length byte, value. Values over 255 bytes are split into consecutive
/// fragments of the same type; a zero-length 0xFF item separates repeated records.
enum TLV8 {
    enum Tag: UInt8 {
        case method = 0, identifier = 1, salt = 2, publicKey = 3, proof = 4, encryptedData = 5
        case state = 6, error = 7, retryDelay = 8, certificate = 9, signature = 10, permissions = 11
        case fragmentData = 12, fragmentLast = 13, flags = 0x13, separator = 0xFF
    }

    enum ErrorCode: UInt8 {
        case unknown = 1, authentication = 2, backoff = 3, maxPeers = 4, maxTries = 5, unavailable = 6, busy = 7
    }

    struct Item: Equatable { var tag: UInt8; var value: Data }

    static func encode(_ items: [(Tag, Data)]) -> Data {
        var out = Data()
        for (tag, value) in items {
            if value.isEmpty { out.append(contentsOf: [tag.rawValue, 0]); continue }
            var offset = value.startIndex
            while offset < value.endIndex {
                let end = value.index(offset, offsetBy: 255, limitedBy: value.endIndex) ?? value.endIndex
                out.append(tag.rawValue)
                out.append(UInt8(value.distance(from: offset, to: end)))
                out.append(value[offset..<end])
                offset = end
            }
        }
        return out
    }

    /// Adjacent items of the same type are joined when the earlier one was a full 255-byte fragment.
    static func decode(_ data: Data) -> [Item]? {
        var items: [Item] = []
        var i = data.startIndex
        var lastWasFull = false
        while i < data.endIndex {
            guard data.distance(from: i, to: data.endIndex) >= 2 else { return nil }
            let tag = data[i], length = Int(data[data.index(after: i)])
            let start = data.index(i, offsetBy: 2)
            guard data.distance(from: start, to: data.endIndex) >= length else { return nil }
            let value = data[start..<data.index(start, offsetBy: length)]
            if lastWasFull, var last = items.last, last.tag == tag, tag != Tag.separator.rawValue {
                last.value.append(value)
                items[items.count - 1] = last
            } else {
                items.append(Item(tag: tag, value: Data(value)))
            }
            lastWasFull = length == 255
            i = data.index(start, offsetBy: length)
        }
        return items
    }

    /// First value of each tag (what single-record messages need).
    static func dictionary(_ data: Data) -> [UInt8: Data]? {
        guard let items = decode(data) else { return nil }
        var out: [UInt8: Data] = [:]
        for item in items where out[item.tag] == nil { out[item.tag] = item.value }
        return out
    }
}
