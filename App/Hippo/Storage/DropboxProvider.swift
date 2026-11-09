import Foundation
import AuthenticationServices
import Synchronization
import UIKit
import LocalRepository
import SyncEngine
import DropboxAdapter
import HippoPresentation

enum DropboxProviderError: Error, Equatable {
    /// The person closed the sign-in sheet or declined access: nothing to report.
    case cancelled
    /// The callback came back without an authorization code.
    case noCode
    /// There is no window to show sign-in over, or the sign-in sheet couldn't start.
    case noWindow
}

/// Dropbox as a `StorageProvider`: PKCE sign-in in `ASWebAuthenticationSession`, tokens in the shared
/// Keychain, uploads of whole files on a background `URLSession` (design §4.1, §6.1). App process only.
final class DropboxProvider: StorageProvider {
    static let uploadSessionIdentifier = "com.jorgeper.hippo.dropbox-uploads"

    let kind = "dropbox"
    let displayName = "Dropbox"

    private let appKey: String
    private let storeRoot: URL
    private let auth: DropboxAuth
    private let client: DropboxClient
    private let uploads: BackgroundUploadTransport

    /// The provider the app environment built, so background-session events reach its transport.
    private static let current = Mutex<DropboxProvider?>(nil)

    /// Nil when the build has no app key (no `Config/Secrets.xcconfig`): Dropbox is then absent.
    init?(appKey: String, storeRoot: URL, accessGroup: String?) {
        guard !appKey.isEmpty else { return nil }
        self.appKey = appKey
        self.storeRoot = storeRoot
        let transport = URLSessionTransport()
        auth = DropboxAuth(appKey: appKey, tokens: KeychainTokenStore(accessGroup: accessGroup),
                           lockURL: storeRoot.appendingPathComponent("dropbox-refresh.lock"), transport: transport)
        uploads = BackgroundUploadTransport(identifier: Self.uploadSessionIdentifier,
                                            sharedContainerIdentifier: AppEnvironment.appGroupID)
        client = DropboxClient(auth: auth, transport: transport, uploadTransport: uploads)
        Self.current.withLock { $0 = self }
    }

    private var callbackScheme: String { "db-\(appKey)" }
    private var redirectURI: String { "\(callbackScheme)://2/token" }

    // MARK: StorageProvider

    @MainActor func connect() async throws -> Destination {
        let pkce = PKCE.make()
        guard let signIn = WebSignIn(keyWindowOf: .shared) else { throw DropboxProviderError.noWindow }
        let callback = try await signIn.run(url: auth.authorizationURL(pkce: pkce, redirectURI: redirectURI),
                                            scheme: callbackScheme)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            // `error=access_denied` is the person tapping Cancel on Dropbox's page.
            if items.contains(where: { $0.name == "error" }) { throw DropboxProviderError.cancelled }
            throw DropboxProviderError.noCode
        }
        _ = try await auth.exchange(code: code, pkce: pkce, redirectURI: redirectURI)
        let account = try JSONDecoder().decode(Account.self, from: try await client.rpc("users/get_current_account"))
        return Destination(id: "dropbox:\(account.account_id)", providerKind: kind,
                           accountIdentifier: account.account_id, remoteRoot: "",
                           displayName: account.name.display_name, status: .active)
    }

    func makeAdapter(for d: Destination) throws -> any StorageAdapter {
        DropboxAdapter(client: client, accountID: d.accountIdentifier, rootPrefix: "",
                       scratchDirectory: storeRoot.appendingPathComponent("transfers", isDirectory: true))
    }

    func signOut(_ d: Destination) async { await auth.signOut() }

    func accountStatus(_ d: Destination) async -> ProviderAccountStatus {
        guard d.status == .active else { return .ok }
        return auth.needsReauthentication || auth.storedAccountID == nil ? .needsSignIn : .ok
    }

    // MARK: Background session

    /// Hands iOS's completion handler to the upload session named `identifier`; calls it at once for any other.
    static func handleBackgroundEvents(identifier: String, completion: @escaping @Sendable () -> Void) {
        guard let uploads = current.withLock({ $0?.uploads }), uploads.identifier == identifier else {
            completion()
            return
        }
        uploads.setEventsCompletion(completion)
    }

    // MARK: Wire types

    private struct Account: Decodable {
        struct Name: Decodable { var display_name: String }
        var account_id: String
        var name: Name
    }
}

/// One run of `ASWebAuthenticationSession`, anchored to the key window. Holds the session until it ends.
@MainActor
private final class WebSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private let anchor: ASPresentationAnchor
    private var session: ASWebAuthenticationSession?

    /// Nil when the app has no window to show sign-in over.
    init?(keyWindowOf app: UIApplication) {
        let scenes = app.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? scenes.first?.windows.first else {
            return nil
        }
        anchor = window
    }

    func run(url: URL, scheme: String) async throws -> URL {
        defer { session = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            // `@Sendable`: the completion handler is not promised to arrive on the main thread.
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme(scheme)) { @Sendable callback, error in
                if let error {
                    let cancelled = (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin
                    once.resume(.failure(cancelled ? DropboxProviderError.cancelled : error))
                } else if let callback {
                    once.resume(.success(callback))
                } else {
                    once.resume(.failure(DropboxProviderError.noCode))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            if !session.start() { once.resume(.failure(DropboxProviderError.noWindow)) }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor
    }
}

/// Resumes a continuation at most once, whichever of the session's completion or a failed `start()` comes first.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<URL, Error>?>
    init(_ c: CheckedContinuation<URL, Error>) { continuation = Mutex(c) }
    func resume(_ result: Result<URL, Error>) {
        continuation.withLock { c in
            c?.resume(with: result)
            c = nil
        }
    }
}
