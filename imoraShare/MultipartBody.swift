    import Foundation

// NOTE: this file is duplicated verbatim in imora/Core/Backup/MultipartBody.swift.
// the share extension builds the same request bodies and the targets share no
// module - change both or neither.

/// streaming multipart/form-data writer. the body is assembled in a file so
/// large videos never pass through memory.
nonisolated enum MultipartBody {
    static let chunkSize = 1 << 20

    static func contentType(boundary: String) -> String {
        "multipart/form-data; boundary=\(boundary)"
    }

    /// writes text fields followed by one file part into a new file inside
    /// `directory` and returns its url. the caller owns the returned file.
    static func makeBodyFile(
        fields: [(name: String, value: String)],
        fileField: String,
        filename: String,
        contentsOf source: URL,
        boundary: String,
        in directory: URL
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bodyURL = directory.appending(path: "body-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: bodyURL)
        defer { try? handle.close() }

        var head = ""
        for field in fields {
            head += "--\(boundary)\r\n"
            head += "Content-Disposition: form-data; name=\"\(sanitize(field.name))\"\r\n\r\n"
            head += "\(field.value)\r\n"
        }
        head += "--\(boundary)\r\n"
        head += "Content-Disposition: form-data; name=\"\(sanitize(fileField))\"; filename=\"\(sanitize(filename))\"\r\n"
        head += "Content-Type: application/octet-stream\r\n\r\n"
        try handle.write(contentsOf: Data(head.utf8))

        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        // chunks come back autoreleased - drain per iteration so peak memory
        // stays one chunk instead of the whole file. share extensions die
        // around 120mb otherwise.
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty else { return false }
            try handle.write(contentsOf: chunk)
            return true
        }) {}

        try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return bodyURL
    }

    /// quotes and newlines would break part headers.
    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
    }
}
