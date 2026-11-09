import Foundation

/// The stored Dropbox sign-in. Secret: never log, never put in an error.
public struct DropboxTokens: Codable, Equatable, Sendable {
    public var accessToken: String
    public var expiresAt: Date
    public var refreshToken: String
    public var accountID: String
    public var needsReauthentication: Bool = false

    public init(accessToken: String, expiresAt: Date, refreshToken: String, accountID: String,
                needsReauthentication: Bool = false) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.accountID = accountID
        self.needsReauthentication = needsReauthentication
    }
}
