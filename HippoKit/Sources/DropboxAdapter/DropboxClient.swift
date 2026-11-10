import Foundation
import SyncEngine

/// Authenticated calls to the Dropbox HTTP API. The only place the access token is read.
public final class DropboxClient: Sendable {
    private static let rpcBase = "https://api.dropboxapi.com/2/"
    private static let contentBase = "https://content.dropboxapi.com/2/"

    private let auth: DropboxAuth
    private let transport: any DropboxTransport
    private let uploadTransport: (any DropboxTransport)?

    /// `uploadTransport` carries `.file` bodies (a background session on iOS); nil uses `transport`.
    public init(auth: DropboxAuth, transport: any DropboxTransport, uploadTransport: (any DropboxTransport)? = nil) {
        self.auth = auth
        self.transport = transport
        self.uploadTransport = uploadTransport
    }

    public var usesBackgroundUploads: Bool { uploadTransport != nil }

    public static func storageError(for error: URLError) -> any Error {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed, .cannotFindHost,
             .cannotConnectToHost, .internationalRoamingOff, .dataNotAllowed:
            return StorageError.offline
        case .timedOut: return StorageError.transient(code: "timeout")
        case .cancelled: return CancellationError()
        default: return StorageError.transient(code: "url_error")
        }
    }

    /// Maps anything a client call can throw to a `StorageError` (or `CancellationError`).
    static func storageError(for error: any Error) -> any Error {
        switch error {
        case is StorageError, is CancellationError: return error
        case let e as DropboxCallError: return e.storageError()
        case let e as URLError: return storageError(for: e)
        case let e as DropboxAuthError:
            switch e {
            case .needsReauthentication, .notConfigured: return StorageError.needsAuthentication
            case .offline: return StorageError.offline
            case .transient(let code): return StorageError.transient(code: code)
            }
        default: return StorageError.transient(code: "unknown")
        }
    }

    // MARK: Calls

    public func rpc(_ endpoint: String, _ arg: (some Encodable)?) async throws -> Data {
        let body: Data
        if let arg { body = try Self.encode(arg) } else { body = Data("null".utf8) }
        let url = URL(string: Self.rpcBase + endpoint)!
        return try await perform { token in
            DropboxRequest(url: url, headers: ["Authorization": "Bearer \(token)", "Content-Type": "application/json"],
                           body: .json(body))
        }.body
    }

    public func rpc(_ endpoint: String) async throws -> Data {
        try await rpc(endpoint, Optional<String>.none)
    }

    /// Content endpoint with an optional file body; returns the response body (JSON metadata, or thumbnail bytes).
    /// `scratchFile`: see `DropboxRequest.removesFileIfAbandoned`.
    public func upload(_ endpoint: String, arg: some Encodable, file: URL? = nil, scratchFile: Bool = false) async throws -> Data {
        let header = Self.headerJSON(try Self.encode(arg))
        let url = URL(string: Self.contentBase + endpoint)!
        let body: DropboxRequest.Body = file.map { .file($0) } ?? .none
        let viaUploadTransport = file != nil
        return try await perform(uploadTransport: viaUploadTransport) { token in
            DropboxRequest(url: url, headers: ["Authorization": "Bearer \(token)", "Dropbox-API-Arg": header,
                                               "Content-Type": "application/octet-stream"], body: body,
                           removesFileIfAbandoned: scratchFile)
        }.body
    }

    /// Streams the file to `to`; returns the `Dropbox-API-Result` header bytes.
    public func download(_ endpoint: String, arg: some Encodable, to localURL: URL,
                         progress: (@Sendable (Int64) -> Void)? = nil) async throws -> Data {
        let header = Self.headerJSON(try Self.encode(arg))
        let url = URL(string: Self.contentBase + endpoint)!
        let resp = try await perform(download: (localURL, progress)) { token in
            DropboxRequest(url: url, headers: ["Authorization": "Bearer \(token)", "Dropbox-API-Arg": header],
                           body: .none)
        }
        return Data((resp.headers["dropbox-api-result"] ?? "").utf8)
    }

    // MARK: Plumbing

    private func perform(uploadTransport useUpload: Bool = false, download: (URL, (@Sendable (Int64) -> Void)?)? = nil,
                         _ build: (String) -> DropboxRequest) async throws -> DropboxResponse {
        for attempt in 0..<2 {
            let token: String
            do { token = try await auth.accessToken() } catch { throw Self.storageError(for: error) }
            let request = build(token)
            let response: DropboxResponse
            if let (localURL, progress) = download {
                response = try await transport.download(request, to: localURL, progress: progress)
            } else {
                response = try await (useUpload ? (uploadTransport ?? transport) : transport).send(request)
            }
            if (200..<300).contains(response.status) { return response }
            if response.status == 401, attempt == 0 {
                do { try auth.invalidateAccessToken() } catch { throw StorageError.transient(code: "store") }
                continue
            }
            throw DropboxCallError(status: response.status, headers: response.headers, body: response.body)
        }
        throw DropboxCallError(status: 401)
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// `Dropbox-API-Arg` must be ASCII: non-ASCII scalars are written as `\uXXXX`.
    private static func headerJSON(_ json: Data) -> String {
        var out = ""
        for scalar in String(decoding: json, as: UTF8.self).unicodeScalars {
            if scalar.isASCII { out.unicodeScalars.append(scalar) }
            else { for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) } }
        }
        return out
    }
}
