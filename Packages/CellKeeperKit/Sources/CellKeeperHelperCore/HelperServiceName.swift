/// The names under which launchd knows CellKeeper's helper daemon. The app
/// connects to ``machService``; the daemon's launchd property list
/// (`Config/LaunchDaemons/io.github.saltedtan.CellKeeper.Helper.plist`)
/// declares both, and a test checks that the file and these constants agree.
public enum HelperServiceName {
    /// The launchd job label, which is also the property list's file name
    /// without its extension (`SMAppService.daemon(plistName:)` needs that).
    public static let label = "io.github.saltedtan.CellKeeper.Helper"
    /// The Mach service the daemon's listener serves and the app connects
    /// to. It is the label, as launchd convention suggests.
    public static let machService = label
}
