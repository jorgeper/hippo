import Foundation

/// Carries no token strings and no response bodies.
public enum DropboxAuthError: Error, Equatable, Sendable {
    case needsReauthentication, offline, transient(code: String), notConfigured
}

public final class DropboxAuth: Sendable {
    public static let scopes = ["files.content.write", "files.content.read", "files.metadata.read", "account_info.read"]
    private static let tokenURL = URL(string: "https://api.dropboxapi.com/oauth2/token")!
    private static let revokeURL = URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!
    private static let leeway: TimeInterval = 60

    private let appKey: String
    private let tokens: any TokenStore
    private let lockURL: URL
    private let transport: any DropboxTransport
    private let now: @Sendable () -> Date

    public init(appKey: String, tokens: any TokenStore, lockURL: URL, transport: any DropboxTransport,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.appKey = appKey
        self.tokens = tokens
        self.lockURL = lockURL
        self.transport = transport
        self.now = now
    }

    public var storedAccountID: String? { (try? tokens.load())??.accountID }
    public var needsReauthentication: Bool { (try? tokens.load())??.needsReauthentication ?? false }

    public func authorizationURL(pkce: PKCE, redirectURI: String?) -> URL {
        var c = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        var items = [URLQueryItem(name: "client_id", value: appKey),
                     URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "token_access_type", value: "offline"),
                     URLQueryItem(name: "code_challenge", value: pkce.challenge),
                     URLQueryItem(name: "code_challenge_method", value: "S256"),
                     URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " "))]
        if let redirectURI { items.append(URLQueryItem(name: "redirect_uri", value: redirectURI)) }
        c.queryItems = items
        return c.url!
    }

    private struct TokenResponse: Decodable {
        var access_token: String
        var expires_in: Double
        var refresh_token: String?
        var account_id: String?
    }

    private static func form(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let s = pairs.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
        return Data(s.utf8)
    }

    private func post(_ pairs: [(String, String)]) async throws -> DropboxResponse {
        let req = DropboxRequest(url: Self.tokenURL, body: .form(Self.form(pairs)))
        do { return try await transport.send(req) }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError {
            if e.code == .cancelled { throw CancellationError() }
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut:
                throw DropboxAuthError.offline
            default: throw DropboxAuthError.transient(code: "url_\(e.code.rawValue)")
            }
        } catch { throw DropboxAuthError.transient(code: "transport") }
    }

    public func exchange(code: String, pkce: PKCE, redirectURI: String?) async throws -> DropboxTokens {
        var pairs = [("grant_type", "authorization_code"), ("code", code), ("code_verifier", pkce.verifier),
                     ("client_id", appKey)]
        if let redirectURI { pairs.append(("redirect_uri", redirectURI)) }
        let resp = try await post(pairs)
        guard resp.status == 200 else {
            if Self.isInvalidGrant(resp) { throw DropboxAuthError.needsReauthentication }
            throw DropboxAuthError.transient(code: "http_\(resp.status)")
        }
        guard let t = try? JSONDecoder().decode(TokenResponse.self, from: resp.body),
              let refresh = t.refresh_token, let account = t.account_id else {
            throw DropboxAuthError.transient(code: "bad_response")
        }
        let result = DropboxTokens(accessToken: t.access_token, expiresAt: now().addingTimeInterval(t.expires_in),
                                   refreshToken: refresh, accountID: account)
        do { try tokens.save(result) } catch { throw DropboxAuthError.transient(code: "store") }
        return result
    }

    private static func isInvalidGrant(_ r: DropboxResponse) -> Bool {
        guard r.status == 400,
              let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any] else { return false }
        return o["error"] as? String == "invalid_grant"
    }

    private func stored() throws -> DropboxTokens {
        let t: DropboxTokens?
        do { t = try tokens.load() } catch { throw DropboxAuthError.transient(code: "store") }
        guard let t else { throw DropboxAuthError.notConfigured }
        if t.needsReauthentication { throw DropboxAuthError.needsReauthentication }
        return t
    }

    private func isFresh(_ t: DropboxTokens) -> Bool { t.expiresAt.timeIntervalSince(now()) > Self.leeway }

    public func accessToken() async throws -> String {
        let first = try stored()
        if isFresh(first) { return first.accessToken }
        let fd = try await acquireLock()
        defer { flock(fd, LOCK_UN); close(fd) }
        var current = try stored()  // another process may have refreshed meanwhile
        if isFresh(current) { return current.accessToken }
        let resp = try await post([("grant_type", "refresh_token"), ("refresh_token", current.refreshToken),
                                   ("client_id", appKey)])
        guard resp.status == 200 else {
            if Self.isInvalidGrant(resp) {
                current.needsReauthentication = true
                try? tokens.save(current)
                throw DropboxAuthError.needsReauthentication
            }
            throw DropboxAuthError.transient(code: "http_\(resp.status)")
        }
        guard let t = try? JSONDecoder().decode(TokenResponse.self, from: resp.body) else {
            throw DropboxAuthError.transient(code: "bad_response")
        }
        current.accessToken = t.access_token
        current.expiresAt = now().addingTimeInterval(t.expires_in)
        do { try tokens.save(current) } catch { throw DropboxAuthError.transient(code: "store") }
        return current.accessToken
    }

    /// Polls a non-blocking `flock` so waiting never parks a cooperative thread and stays cancellable.
    private func acquireLock() async throws -> Int32 {
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw DropboxAuthError.transient(code: "lock") }
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { close(fd); throw DropboxAuthError.transient(code: "lock") }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { close(fd); throw error }
        }
        return fd
    }

    public func invalidateAccessToken() throws {
        guard var t = try tokens.load() else { return }
        t.expiresAt = .distantPast
        try tokens.save(t)
    }

    public func signOut() async {
        if let t = (try? tokens.load()) ?? nil {
            let req = DropboxRequest(url: Self.revokeURL, headers: ["Authorization": "Bearer \(t.accessToken)"])
            let transport = self.transport
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = try? await transport.send(req) }
                group.addTask { try? await Task.sleep(for: .seconds(5)) }
                await group.next()
                group.cancelAll()
            }
        }
        try? tokens.clear()
    }
}
