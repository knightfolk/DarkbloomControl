import Foundation

public enum BoundedFileTail {
    public static func read(url: URL, maxBytes: Int) throws -> Data {
        guard maxBytes > 0 else { return Data() }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let byteCount = min(UInt64(maxBytes), size)
        let offset = size - byteCount
        try handle.seek(toOffset: offset)
        var data = try handle.read(upToCount: Int(byteCount)) ?? Data()

        if offset > 0, let newline = data.firstIndex(of: 0x0A) {
            data = Data(data[data.index(after: newline)...])
        }
        return data
    }
}
