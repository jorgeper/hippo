/// The on-disk format this build writes. Readers accept any minor (a missing `schema_minor` is 0) and
/// reject an unknown major.
public enum FormatVersion {
    public static let major = 1
    public static let minor = 1
}
