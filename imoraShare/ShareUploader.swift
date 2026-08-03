import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

/// turns the shared media into upload tasks on a background url session and
/// returns. the system owns the transfers from there: they run with the sheet
/// dismissed and the app closed, and the app adopts the session on its next
/// launch to clean up and report.
nonisolated enum ShareUploader {
    struct Credentials: Sendable {
        let apiURL: URL
        let token: String
        let deviceId: String
    }

    struct Prepared: Sendable {
        let bodyURL: URL
        let filename: String
        let checksum: String
        let boundary: String
    }

    /// nil until the app has signed in and mirrored the session into the app
    /// group; the sheet turns that into a sign-in prompt.
    static func credentials() -> Credentials? {
        guard let defaults = ShareTransfer.defaults,
              let urlString = defaults.string(forKey: ShareTransfer.serverURLKey),
              let apiURL = URL(string: urlString),
              let token = readToken()
        else { return nil }
        let deviceId = defaults.string(forKey: ShareTransfer.deviceIdKey) ?? "imora-share"
        return Credentials(apiURL: apiURL, token: token, deviceId: deviceId)
    }

    /// the app writes the token into the app group access group; a group-less
    /// query searches every group this process can see and finds it there.
    private static func readToken() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ShareTransfer.tokenService,
            kSecAttrAccount as String: ShareTransfer.tokenAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - staging

    /// builds one finished multipart body in the app group for one provider.
    /// all of it happens inside the load callback because the url it hands
    /// over is only valid there.
    static func prepare(_ provider: NSItemProvider, deviceId: String) async -> Prepared? {
        let isVideo = provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        let type: UTType = isVideo ? .movie : .image
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url, let directory = ShareTransfer.bodyDirectory else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: buildBody(from: url, deviceId: deviceId, in: directory))
            }
        }
    }

    private static func buildBody(from url: URL, deviceId: String, in directory: URL) -> Prepared? {
        guard let checksum = try? sha1Base64(ofFile: url) else { return nil }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = attributes?[.creationDate] as? Date
            ?? attributes?[.modificationDate] as? Date
            ?? Date()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let id = UUID().uuidString
        let fields: [(name: String, value: String)] = [
            ("deviceAssetId", "share-\(id)"),
            ("deviceId", deviceId),
            ("fileCreatedAt", iso.string(from: created)),
            ("fileModifiedAt", iso.string(from: created)),
            ("isFavorite", "false"),
            ("duration", "0"),
        ]
        let boundary = "imora-\(id)"
        guard let bodyURL = try? MultipartBody.makeBodyFile(
            fields: fields,
            fileField: "assetData",
            filename: url.lastPathComponent,
            contentsOf: url,
            boundary: boundary,
            in: directory
        ) else { return nil }
        return Prepared(
            bodyURL: bodyURL,
            filename: url.lastPathComponent,
            checksum: checksum,
            boundary: boundary
        )
    }

    /// streaming sha1 of the staged file, the checksum the server dedups on.
    private static func sha1Base64(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).base64EncodedString()
    }

    // MARK: - enqueue

    /// one background session per drop, so its identifier can be handed to the
    /// app through a marker file and adopted independently of other batches.
    static func enqueue(_ items: [Prepared], credentials: Credentials) {
        guard !items.isEmpty else { return }
        let identifier = ShareTransfer.sessionPrefix + UUID().uuidString
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sharedContainerIdentifier = ShareTransfer.appGroup
        config.sessionSendsLaunchEvents = true
        let session = URLSession(configuration: config)

        ShareTransfer.markSession(identifier)
        for item in items {
            var request = URLRequest(url: credentials.apiURL.appending(path: "assets"))
            request.httpMethod = "POST"
            request.setValue(MultipartBody.contentType(boundary: item.boundary), forHTTPHeaderField: "Content-Type")
            request.setValue(item.checksum, forHTTPHeaderField: "x-immich-checksum")
            request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let task = session.uploadTask(with: request, fromFile: item.bodyURL)
            task.taskDescription = ShareTransfer.encode(
                ShareTicket(bodyPath: item.bodyURL.path, filename: item.filename)
            )
            task.resume()
        }
    }
}
