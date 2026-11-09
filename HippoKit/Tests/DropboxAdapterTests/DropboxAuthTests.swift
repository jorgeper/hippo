import Foundation
import CryptoKit
import Testing
import SyncEngine
@testable import DropboxAdapter

@Suite struct DropboxAuthTests {
    // Obviously fake fixtures.
    static let t0 = Date(timeIntervalSince1970: 1_000_000)
    static let oldAccess = "FAKE-OLD-ACCESS"
    static let newAccess = "FAKE-NEW-ACCESS"
    static let refresh = "FAKE-REFRESH"

    func tokens(expiresIn: TimeInterval, flag: Bool = false) -> DropboxTokens {
        DropboxTokens(accessToken: Self.oldAccess, expiresAt: Self.t0.addingTimeInterval(expiresIn),
                      refreshToken: Self.refresh, accountID: "dbid:FAKE", needsReauthentication: flag)
    }

    func lockURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("hippo-lock-\(UUID().uuidString)") }

    func auth(_ store: any TokenStore, _ transport: ScriptedTransport, lock: URL? = nil) -> DropboxAuth {
        DropboxAuth(appKey: "FAKEAPPKEY", tokens: store, lockURL: lock ?? lockURL(), transport: transport, now: { Self.t0 })
    }

    func formBody(_ r: DropboxRequest) -> String {
        if case .form(let d) = r.body { return String(decoding: d, as: UTF8.self) }
        return ""
    }

    @Test func authorizationURLCarriesPKCEAndOfflineAccess() throws {
        let pkce = PKCE.make()
        let url = auth(MemoryTokenStore(), ScriptedTransport()).authorizationURL(pkce: pkce, redirectURI: "db-FAKE://2/token")
        let items = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(items["code_challenge"] == pkce.challenge)
        #expect(items["code_challenge_method"] == "S256")
        #expect(items["token_access_type"] == "offline")
        #expect(items["response_type"] == "code")
        #expect(items["redirect_uri"] == "db-FAKE://2/token")
        #expect(items["client_secret"] == nil)
        #expect(Set(items["scope"]!.split(separator: " ").map(String.init)) == Set(DropboxAuth.scopes))
        let bare = auth(MemoryTokenStore(), ScriptedTransport()).authorizationURL(pkce: pkce, redirectURI: nil)
        #expect(!bare.absoluteString.contains("redirect_uri"))
    }

    @Test func exchangeSavesTokensWithExpiry() async throws {
        let store = MemoryTokenStore()
        let transport = ScriptedTransport()
        transport.enqueue(ScriptedTransport.json(["access_token": Self.newAccess, "expires_in": 14400,
                                                  "refresh_token": Self.refresh, "account_id": "dbid:FAKE"]))
        let pkce = PKCE.make()
        let got = try await auth(store, transport).exchange(code: "FAKECODE", pkce: pkce, redirectURI: nil)
        #expect(got == (try store.load()))
        #expect(got.accessToken == Self.newAccess)
        #expect(got.refreshToken == Self.refresh)
        #expect(got.accountID == "dbid:FAKE")
        #expect(got.expiresAt == Self.t0.addingTimeInterval(14400))
        let body = formBody(transport.requests[0])
        #expect(body.contains("code_verifier=\(pkce.verifier)"))
        #expect(body.contains("grant_type=authorization_code"))
        #expect(!body.contains("secret"))
        #expect(!body.contains("redirect_uri"))
    }

    @Test func freshTokenIsReturnedWithoutRefresh() async throws {
        let transport = ScriptedTransport()
        let a = auth(MemoryTokenStore(tokens(expiresIn: 3600)), transport)
        #expect(try await a.accessToken() == Self.oldAccess)
        #expect(transport.requests.isEmpty)
    }

    @Test func expiringTokenIsRefreshedOnce() async throws {
        let store = MemoryTokenStore(tokens(expiresIn: 30))
        let transport = ScriptedTransport()
        transport.enqueue(ScriptedTransport.json(["access_token": Self.newAccess, "expires_in": 14400]))
        let a = auth(store, transport)
        #expect(try await a.accessToken() == Self.newAccess)
        #expect(try await a.accessToken() == Self.newAccess)
        #expect(transport.requests.count == 1)
        let saved = try #require(try store.load())
        #expect(saved.accessToken == Self.newAccess)
        #expect(saved.refreshToken == Self.refresh)
        #expect(saved.accountID == "dbid:FAKE")
        let body = formBody(transport.requests[0])
        #expect(body.contains("grant_type=refresh_token"))
        #expect(body.contains("client_id=FAKEAPPKEY"))
    }

    @Test func concurrentRefreshesShareOneRequest() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileTokenStore(url: dir.appendingPathComponent("tokens.json"))
        try store.save(tokens(expiresIn: 30))
        let lock = dir.appendingPathComponent("refresh.lock")
        let transport = ScriptedTransport()
        transport.enqueue(ScriptedTransport.json(["access_token": Self.newAccess, "expires_in": 14400]), delay: .milliseconds(100))
        let a = auth(store, transport, lock: lock)
        let b = auth(store, transport, lock: lock)
        async let x = a.accessToken()
        async let y = b.accessToken()
        let (rx, ry) = try await (x, y)
        #expect(rx == Self.newAccess)
        #expect(ry == Self.newAccess)
        #expect(transport.requests.count == 1)
        let attrs = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("tokens.json").path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func invalidGrantMarksNeedsReauthentication() async throws {
        let store = MemoryTokenStore(tokens(expiresIn: 30))
        let transport = ScriptedTransport()
        transport.enqueue(ScriptedTransport.json(["error": "invalid_grant", "error_description": "refresh token is invalid or revoked"],
                                                 status: 400))
        let a = auth(store, transport)
        await #expect(throws: DropboxAuthError.needsReauthentication) { try await a.accessToken() }
        #expect(try store.load()?.needsReauthentication == true)
        #expect(a.needsReauthentication)
        await #expect(throws: DropboxAuthError.needsReauthentication) { try await a.accessToken() }
        #expect(transport.requests.count == 1)
    }

    @Test func offlineRefreshIsOffline() async throws {
        let original = tokens(expiresIn: 30)
        let store = MemoryTokenStore(original)
        let transport = ScriptedTransport()
        transport.enqueue(.failure(URLError(.notConnectedToInternet)))
        await #expect(throws: DropboxAuthError.offline) { try await auth(store, transport).accessToken() }
        #expect(try store.load() == original)
    }

    @Test func serverErrorIsTransientAndNoTokensIsNotConfigured() async throws {
        let transport = ScriptedTransport()
        transport.enqueue(ScriptedTransport.json(["error": "x"], status: 500))
        await #expect(throws: DropboxAuthError.transient(code: "http_500")) {
            try await auth(MemoryTokenStore(tokens(expiresIn: 30)), transport).accessToken()
        }
        await #expect(throws: DropboxAuthError.notConfigured) { try await auth(MemoryTokenStore(), transport).accessToken() }
    }

    @Test func invalidateForcesRefresh() async throws {
        let store = MemoryTokenStore(tokens(expiresIn: 3600))
        let transport = ScriptedTransport()
        transport.enqueue(ScriptedTransport.json(["access_token": Self.newAccess, "expires_in": 14400]))
        let a = auth(store, transport)
        try a.invalidateAccessToken()
        #expect(try await a.accessToken() == Self.newAccess)
    }

    @Test func signOutRevokesThenClears() async throws {
        let store = MemoryTokenStore(tokens(expiresIn: 3600))
        let transport = ScriptedTransport()
        transport.enqueue(.success(DropboxResponse(status: 200)))
        await auth(store, transport).signOut()
        #expect(transport.requests.count == 1)
        #expect(transport.requests[0].url.path == "/2/auth/token/revoke")
        #expect(transport.requests[0].headers["Authorization"] == "Bearer \(Self.oldAccess)")
        #expect(try store.load() == nil)

        let store2 = MemoryTokenStore(tokens(expiresIn: 3600))
        let failing = ScriptedTransport()
        failing.enqueue(.failure(URLError(.notConnectedToInternet)))
        await auth(store2, failing).signOut()
        #expect(try store2.load() == nil)
    }

    @Test func tokensNeverAppearInErrors() async throws {
        var errors: [Error] = []
        func capture(_ store: MemoryTokenStore, _ result: Result<DropboxResponse, Error>) async {
            let transport = ScriptedTransport()
            transport.enqueue(result)
            do { _ = try await auth(store, transport).accessToken() } catch { errors.append(error) }
        }
        let leaky = "{\"error\":\"invalid_grant\",\"refresh_token\":\"\(Self.refresh)\",\"access_token\":\"\(Self.oldAccess)\"}"
        await capture(MemoryTokenStore(tokens(expiresIn: 30)), .success(DropboxResponse(status: 400, body: Data(leaky.utf8))))
        await capture(MemoryTokenStore(tokens(expiresIn: 30)), .success(DropboxResponse(status: 503, body: Data(leaky.utf8))))
        await capture(MemoryTokenStore(tokens(expiresIn: 30)), .failure(URLError(.notConnectedToInternet)))
        await capture(MemoryTokenStore(tokens(expiresIn: 30)), .success(DropboxResponse(status: 200, body: Data(leaky.utf8))))
        #expect(errors.count == 4)
        let sample = tokens(expiresIn: 30)
        let req = DropboxRequest(url: URL(string: "https://example.invalid/x")!,
                                 headers: ["Authorization": "Bearer \(Self.oldAccess)"], body: .none)
        for text in [String(describing: sample), String(reflecting: sample), String(describing: req), String(reflecting: req)] {
            #expect(!text.contains(Self.oldAccess) && !text.contains(Self.refresh) && !text.contains("Bearer"))
        }
        for e in errors {
            let text = String(describing: e) + String(reflecting: e) + e.localizedDescription
            #expect(!text.contains(Self.oldAccess) && !text.contains(Self.refresh) && !text.contains(Self.newAccess))
        }
    }

    @Test func accountNameIsStoredApartAndOldTokensStillDecode() throws {
        // Tokens saved before the account name was kept carry no `accountName` key.
        let old = #"{"accessToken":"A","expiresAt":0,"refreshToken":"R","accountID":"dbid:FAKE","needsReauthentication":false}"#
        let decoded = try JSONDecoder().decode(DropboxTokens.self, from: Data(old.utf8))
        #expect(decoded.accountName == nil && decoded.accountID == "dbid:FAKE")

        let store = MemoryTokenStore(tokens(expiresIn: 3600))
        let a = auth(store, ScriptedTransport())
        #expect(a.storedAccountName(accountID: "dbid:FAKE") == nil)
        try a.saveAccountName("Fake Person")
        #expect(try store.load()?.accountName == "Fake Person")
        #expect(a.storedAccountName(accountID: "dbid:FAKE") == "Fake Person")
        // Another account's destination never gets this account's name.
        #expect(a.storedAccountName(accountID: "dbid:OTHER") == nil)
        // Round-trips, and stays out of the redacted description.
        let encoded = try JSONEncoder().encode(try #require(try store.load()))
        #expect(try JSONDecoder().decode(DropboxTokens.self, from: encoded).accountName == "Fake Person")
        #expect(!String(describing: try #require(try store.load())).contains("Fake Person"))
    }

    @Test func checkAccountRejectsAnotherAccountsDestination() throws {
        let a = auth(MemoryTokenStore(tokens(expiresIn: 3600)), ScriptedTransport())
        try a.checkAccount("dbid:FAKE")
        #expect(throws: StorageError.permanent(code: "account_mismatch")) { try a.checkAccount("dbid:OTHER") }
        // Signed out: nothing stored to compare, so the adapter's own calls report the missing sign-in.
        try auth(MemoryTokenStore(), ScriptedTransport()).checkAccount("dbid:OTHER")
    }

    @Test func timeoutIsTransientNotOffline() async throws {
        let transport = ScriptedTransport()
        transport.enqueue(.failure(URLError(.timedOut)))
        await #expect(throws: DropboxAuthError.transient(code: "timeout")) {
            try await auth(MemoryTokenStore(tokens(expiresIn: 30)), transport).accessToken()
        }
    }

    @Test func unreadableTokenFileThrowsRatherThanLookingSignedOut() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A directory where the file should be: reading fails with something other than no-such-file.
        let store = FileTokenStore(url: dir)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try FileTokenStore(url: dir.appendingPathComponent("absent.json")).load() == nil)
    }

    @Test func pkceVerifierAndChallengeShape() {
        let p = PKCE.make()
        #expect(p.verifier.count == 43)
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        #expect(p.verifier.unicodeScalars.allSatisfy(alphabet.contains))
        let digest = Data(SHA256.hash(data: Data(p.verifier.utf8)))
        let expected = digest.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        #expect(p.challenge == expected)
        #expect(PKCE.make() != p)
    }
}
