import Foundation

/// The stored Dropbox sign-in. Secret: never log, never put in an error.
public struct DropboxTokens: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted: account ID only.
    public var description: String { "DropboxTokens(account: \(accountID))" }
    public var debugDescription: String { description }

    public var accessToken: String
    public var expiresAt: Date
    public var refreshToken: String
    public var accountID: String
    public var needsReauthentication: Bool = false
    /// The account holder's display name, saved after sign-in (`users/get_current_account`). Personal data:
    /// shown in Settings and Detail only, never logged. Nil in tokens saved before it was kept.
    public var accountName: String?

    public init(accessToken: String, expiresAt: Date, refreshToken: String, accountID: String,
                needsReauthentication: Bool = false, accountName: String? = nil) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.needsReauthentication = needsReauthentication
        self.accountName = accountName
    }
}
