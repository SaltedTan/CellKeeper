import CellKeeperCore
import Foundation

extension DiagnosticsEnvironment {
    /// This app and Mac: the app's version and build, the macOS version and
    /// build, and the model identifier from `sysctl hw.model` (for example
    /// "Mac16,1"; never a serial number).
    public static func current(bundle: Bundle = .main) -> DiagnosticsEnvironment {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return DiagnosticsEnvironment(
            appVersion: build.map { "\(version) (\($0))" } ?? version,
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            modelIdentifier: modelIdentifier()
        )
    }

    static func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        let model = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return model.isEmpty ? nil : model
    }
}
