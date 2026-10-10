/// The daemon's build, reported by `hello` so the app can tell an older
/// helper from its own (research note 04, §1.5).
public enum HelperBuild {
    /// Equal to the app's build number, `CURRENT_PROJECT_VERSION` in
    /// `Config/CellKeeper.xcconfig`; a test checks that they agree. Raise
    /// both together.
    public static let number = 1
}
