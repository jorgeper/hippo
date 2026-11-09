import Foundation
import Testing
import SyncEngine
@testable import DropboxAdapter

func makeClient(api: ScriptedTransport, auth authTransport: ScriptedTransport = ScriptedTransport(),
                token: String = "tok-1", uploadTransport: ScriptedTransport? = nil) -> DropboxClient {
    let store = MemoryTokenStore(DropboxTokens(accessToken: token, expiresAt: Date().addingTimeInterval(3600),
                                               refreshToken: "refresh", accountID: "dbid:acct"))
    let lock = FileManager.default.temporaryDirectory.appendingPathComponent("hippo-lock-\(UUID().uuidString)")
    let auth = DropboxAuth(appKey: "key", tokens: store, lockURL: lock, transport: authTransport)
    return DropboxClient(auth: auth, transport: api, uploadTransport: uploadTransport)
}

private func tagError(_ tags: Any, status: Int = 409, headers: [String: String] = [:]) -> Result<DropboxResponse, Error> {
    let data = try! JSONSerialization.data(withJSONObject: ["error": tags, "error_summary": "x"])
    return .success(DropboxResponse(status: status, headers: headers, body: data))
}

@Suite struct DropboxClientTests {
    @Test func retriesOnceAfter401() async throws {
        let api = ScriptedTransport(), authT = ScriptedTransport()
        let client = makeClient(api: api, auth: authT)
        api.enqueue(tagError([".tag": "expired_access_token"], status: 401))
        api.enqueue(ScriptedTransport.json(["ok": true]))
        authT.enqueue(ScriptedTransport.json(["access_token": "tok-2", "expires_in": 14400]))
        let data = try await client.rpc("files/get_metadata", ["path": "/x"])
        #expect(!data.isEmpty)
        let reqs = api.requests
        #expect(reqs.count == 2)
        #expect(reqs[0].headers["Authorization"] == "Bearer tok-1")
        #expect(reqs[1].headers["Authorization"] == "Bearer tok-2")
        #expect(reqs[0].url.absoluteString == "https://api.dropboxapi.com/2/files/get_metadata")
    }

    @Test func twoUnauthorizedThrowsNeedsAuthentication() async throws {
        let api = ScriptedTransport(), authT = ScriptedTransport()
        let client = makeClient(api: api, auth: authT)
        api.enqueue(tagError([".tag": "invalid_access_token"], status: 401))
        api.enqueue(tagError([".tag": "invalid_access_token"], status: 401))
        authT.enqueue(ScriptedTransport.json(["access_token": "tok-2", "expires_in": 14400]))
        do {
            _ = try await client.rpc("users/get_current_account")
            Issue.record("expected a throw")
        } catch let e as DropboxCallError {
            #expect(e.status == 401)
            #expect(e.storageError() == .needsAuthentication)
        }
        #expect(api.requests.count == 2)
    }

    @Test func rpcWithoutArgumentSendsNull() async throws {
        let api = ScriptedTransport()
        let client = makeClient(api: api)
        api.enqueue(ScriptedTransport.json(["account_id": "a"]))
        _ = try await client.rpc("users/get_current_account")
        guard case .json(let body) = api.requests[0].body else { Issue.record("not json"); return }
        #expect(String(decoding: body, as: UTF8.self) == "null")
    }

    @Test func contentCallsPutTheArgumentInTheHeaderAsASCII() async throws {
        let api = ScriptedTransport()
        let client = makeClient(api: api)
        api.enqueue(ScriptedTransport.json([:]))
        _ = try await client.upload("files/upload", arg: ["path": "/caf\u{e9}/x"],
                                    file: FileManager.default.temporaryDirectory)
        let r = api.requests[0]
        #expect(r.url.host == "content.dropboxapi.com")
        #expect(r.headers["Content-Type"] == "application/octet-stream")
        let header = try #require(r.headers["Dropbox-API-Arg"])
        #expect(header.unicodeScalars.allSatisfy { $0.isASCII })
        #expect(header == #"{"path":"/caf\u00e9/x"}"#)
    }

    @Test func errorMapping() async throws {
        struct Row { var status: Int; var body: Any; var headers: [String: String] = [:]; var expected: StorageError }
        let rows: [Row] = [
            Row(status: 429, body: [".tag": "too_many_requests"], headers: ["retry-after": "7"], expected: .rateLimited(retryAfter: 7)),
            Row(status: 429, body: [".tag": "too_many_requests"], expected: .rateLimited(retryAfter: 1)),
            Row(status: 409, body: [".tag": "too_many_write_operations", "retry_after": 3], expected: .rateLimited(retryAfter: 3)),
            Row(status: 409, body: [".tag": "path", "path": [".tag": "insufficient_space"]], expected: .quotaExceeded),
            Row(status: 503, body: [".tag": "x"], expected: .transient(code: "http_5xx")),
            Row(status: 409, body: [".tag": "path", "path": [".tag": "conflict", "conflict": [".tag": "file"]]],
                expected: .permanent(code: "api:path.conflict.file")),
            Row(status: 400, body: [".tag": "x"], expected: .transient(code: "http_400")),
        ]
        for row in rows {
            let api = ScriptedTransport()
            let client = makeClient(api: api)
            api.enqueue(tagError(row.body, status: row.status, headers: row.headers))
            do {
                _ = try await client.rpc("files/get_metadata", ["path": "/x"])
                Issue.record("expected a throw for \(row.status)")
            } catch let e as DropboxCallError {
                #expect(e.storageError() == row.expected)
            }
        }
    }

    @Test func tagsAndCorrectOffsetParse() {
        let body = Data(#"{"error":{".tag":"incorrect_offset","correct_offset":2048},"error_summary":"s"}"#.utf8)
        let e = DropboxCallError(status: 409, headers: [:], body: body)
        #expect(e.tags == ["incorrect_offset"] && e.correctOffset == 2048)
        let odd = DropboxCallError(status: 409, headers: [:], body: Data("not json".utf8))
        #expect(odd.tags.isEmpty && odd.correctOffset == nil)
        let str = DropboxCallError(status: 400, headers: [:], body: Data(#"{"error":"nope"}"#.utf8))
        #expect(str.tags.isEmpty)
    }

    @Test func urlErrorMapping() {
        let offline: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .dnsLookupFailed, .cannotFindHost,
                                        .cannotConnectToHost, .internationalRoamingOff, .dataNotAllowed]
        for code in offline {
            #expect(DropboxClient.storageError(for: URLError(code)) as? StorageError == .offline)
        }
        #expect(DropboxClient.storageError(for: URLError(.timedOut)) as? StorageError == .transient(code: "timeout"))
        #expect(DropboxClient.storageError(for: URLError(.cancelled)) is CancellationError)
        #expect(DropboxClient.storageError(for: URLError(.badServerResponse)) as? StorageError == .transient(code: "url_error"))
    }

    @Test func cancellationCancelsTheRequest() async throws {
        let api = ScriptedTransport()
        let client = makeClient(api: api)
        api.enqueue(ScriptedTransport.json([:]), delay: .seconds(30))
        let task = Task { try await client.rpc("files/get_metadata", ["path": "/x"]) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - start < .milliseconds(500))
    }
}
