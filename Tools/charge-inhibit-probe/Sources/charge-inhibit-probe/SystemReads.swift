import Foundation
import IOKit
import IOKit.ps
import ProbeCore

/// Every read the probe makes of the system. All of them are read-only:
/// IOPowerSources (public API), properties of the `AppleSmartBattery` and
/// `IODeviceTree:/chosen` registry entries (`IORegistryEntryCreateCFProperty`;
/// no user client is opened), `sysctlbyname`, the three fixed commands of
/// ``ReadOnlyCommand`` (`pmset -g battlimit`, `pmset -g assertions`,
/// `launchctl print system/<AlDente helper>`), file existence checks,
/// directory listings (names only), and the process table's executable
/// paths and names (`proc_listallpids`, `proc_pidpath`, `proc_name`).
///
/// Only allowlisted values are kept. The battery's description and registry
/// entry also carry serial numbers; those keys are never read into a sample.
enum SystemReads {
    // MARK: Battery

    /// One reading of the battery's charging state.
    static func sample(time: Double, phase: Sample.Phase) -> Sample {
        var sample = Sample(time: time, wallTime: Clock.wallTime(), phase: phase)
        readPowerSources(into: &sample)
        readSmartBattery(into: &sample)
        return sample
    }

    static func readPowerSources(into sample: inout Sample) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        var battery: [String: Any]?
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }
            battery = description
            break
        }

        switch providing {
        case kIOPSACPowerValue?: sample.externalPower = true
        case kIOPSBatteryPowerValue?: sample.externalPower = false
        default:
            switch battery?[kIOPSPowerSourceStateKey] as? String {
            case kIOPSACPowerValue?: sample.externalPower = true
            case kIOPSBatteryPowerValue?: sample.externalPower = false
            default: break
            }
        }

        guard let battery else {
            sample.batteryPresent = false
            return
        }
        sample.batteryPresent = bool(battery[kIOPSIsPresentKey]) ?? true
        if let current = int(battery[kIOPSCurrentCapacityKey]),
           let maximum = int(battery[kIOPSMaxCapacityKey]),
           current >= 0, maximum > 0 {
            let percent = (Double(current) / Double(maximum) * 100).rounded()
            if (0...100).contains(percent) { sample.percent = Int(percent) }
        }
        sample.isCharging = bool(battery[kIOPSIsChargingKey])
        sample.isCharged = bool(battery[kIOPSIsChargedKey])
    }

    static func readSmartBattery(into sample: inout Sample) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return }
        defer { IOObjectRelease(service) }

        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        sample.averageCurrent = milliamps(property("Amperage"))
        sample.instantCurrent = milliamps(property("InstantAmperage"))
        sample.registryIsCharging = bool(property("IsCharging"))
        sample.registryExternalConnected = bool(property("ExternalConnected"))
        if let charger = property("ChargerData") as? [String: Any],
           let reason = int(charger["NotChargingReason"]), reason >= 0 {
            sample.notChargingReason = UInt64(reason)
        }
        if let telemetry = property("PowerTelemetryData") as? [String: Any] {
            sample.systemPowerIn = int(telemetry["SystemPowerIn"])
        }
    }

    /// A signed current in mA, or nil if missing or implausible.
    static func milliamps(_ value: Any?) -> Int? {
        guard let current = int(value), (-20_000...20_000).contains(current) else { return nil }
        return current
    }

    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID() else { return nil }
        return Int(exactly: number.int64Value)
    }

    static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if CFGetTypeID(number) == CFNumberGetTypeID() { return number.intValue != 0 }
        return nil
    }

    // MARK: Machine

    static func machineInfo() -> Report.MachineInfo {
        Report.MachineInfo(
            model: sysctlString("hw.model") ?? "unknown model",
            osVersion: sysctlString("kern.osproductversion") ?? "unknown",
            osBuild: sysctlString("kern.osversion") ?? "unknown build",
            firmware: systemFirmwareVersion() ?? "unknown"
        )
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// `system-firmware-version` of `IODeviceTree:/chosen`, for example
    /// "mBoot-20457.1.29"; the same value System Information shows.
    static func systemFirmwareVersion() -> String? {
        let chosen = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/chosen")
        guard chosen != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(chosen) }
        guard let data = IORegistryEntryCreateCFProperty(chosen, "system-firmware-version" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data
        else { return nil }
        let text = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return text.isEmpty ? nil : text
    }

    // MARK: Preconditions

    static func systemState(redacting names: [String]) -> SystemState {
        let fileManager = FileManager.default
        let aldente = Preconditions.aldenteHelperPaths.filter { fileManager.fileExists(atPath: $0) }
        let aldenteNames = Set(Preconditions.aldenteHelperPaths.map { ($0 as NSString).lastPathComponent })
        let daemonNames = Preconditions.daemonDirectories
            .flatMap { (try? fileManager.contentsOfDirectory(atPath: $0)) ?? [] }
            .filter { !aldenteNames.contains($0) }
        let others = Preconditions.batteryToolNames(in: daemonNames).map { Privacy.safeName($0, names: names) }
        let service = ReadOnlyCommand.launchctlPrintAlDente.run()
        return SystemState(
            reading: sample(time: 0, phase: .baseline),
            chargeLimit: ChargeLimitReport.parse(ReadOnlyCommand.battlimit.run()?.successOutput),
            aldenteHelperFiles: aldente,
            aldenteService: LaunchdServiceState.parse(status: service?.status, output: (service?.output ?? "") + (service?.error ?? "")),
            aldenteProcesses: scanProcesses(matching: ProcessScan.isAlDente, names: names),
            otherBatteryDaemons: others,
            assertions: assertionListing(redacting: names)
        )
    }

    /// `pmset -g assertions`, reduced to its ChargeInhibit fields; nil if
    /// pmset could not be run.
    static func assertionListing(redacting names: [String]) -> AssertionListing? {
        ReadOnlyCommand.assertions.run()?.successOutput.map { AssertionListing.parse($0, redacting: names) }
    }

    /// The running processes whose executable path (`proc_pidpath`) or, if
    /// that cannot be read, name (`proc_name`) matches. Reads names only,
    /// never process memory. Nil if the process table cannot be listed.
    static func scanProcesses(matching isMatch: (String) -> Bool, names: [String]) -> ProcessScan? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        let capacity = Int(estimate) + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = pids.withUnsafeMutableBytes { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count))
        }
        guard count > 0 else { return nil }

        var matches: [String] = []
        var unreadable = 0
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let text: String
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                text = string(path)
            } else {
                var name = [CChar](repeating: 0, count: 256)
                errno = 0
                if proc_name(pid, &name, UInt32(name.count)) > 0 {
                    text = string(name)
                } else {
                    // A process that exited after the listing is not a reading failure.
                    if errno != ESRCH { unreadable += 1 }
                    continue
                }
            }
            if isMatch(text) {
                matches.append(Privacy.safeName((text as NSString).lastPathComponent, names: names))
            }
        }
        return ProcessScan(matches: matches.sorted(), unreadable: unreadable)
    }

    static func string(_ buffer: [CChar]) -> String {
        String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The local user's login and full names, to keep out of reports.
    static func namesToRedact() -> [String] {
        var logins = Set<String>()
        let environment = ProcessInfo.processInfo.environment
        for key in ["SUDO_USER", "USER", "LOGNAME"] {
            if let value = environment[key] { logins.insert(value) }
        }
        logins.insert(NSUserName())
        logins.remove("root")
        var names = logins
        for login in logins {
            guard let entry = getpwnam(login), let gecos = entry.pointee.pw_gecos else { continue }
            let fullName = String(cString: gecos).split(separator: ",").first.map(String.init) ?? ""
            if !fullName.isEmpty { names.insert(fullName) }
        }
        return names.sorted { $0.count > $1.count }
    }
}

/// The only commands the probe runs: three fixed, read-only getters.
struct ReadOnlyCommand: Sendable {
    let executable: String
    let arguments: [String]

    static let battlimit = ReadOnlyCommand(executable: "/usr/bin/pmset", arguments: ["-g", "battlimit"])
    static let assertions = ReadOnlyCommand(executable: "/usr/bin/pmset", arguments: ["-g", "assertions"])
    static let launchctlPrintAlDente = ReadOnlyCommand(
        executable: "/bin/launchctl",
        arguments: ["print", "system/\(Preconditions.aldenteHelperLabel)"]
    )

    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String

        /// Standard output if the command exited 0.
        var successOutput: String? { status == 0 ? output : nil }
    }

    /// The exit status and output, or nil if the command could not be run,
    /// was killed, or took longer than `timeout`.
    func run(timeout: TimeInterval = 5) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        let collectedOutput = DataBox()
        let collectedError = DataBox()
        let reads = DispatchGroup()
        for (pipe, box) in [(output, collectedOutput), (error, collectedError)] {
            let reader = pipe.fileHandleForReading
            reads.enter()
            DispatchQueue.global().async {
                box.set(reader.readDataToEndOfFile())
                reads.leave()
            }
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard reads.wait(timeout: .now() + 1) == .success, process.terminationReason == .exit else { return nil }
        return Result(
            status: process.terminationStatus,
            output: String(decoding: collectedOutput.get(), as: UTF8.self),
            error: String(decoding: collectedError.get(), as: UTF8.self)
        )
    }
}

final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func set(_ value: Data) {
        lock.lock()
        data = value
        lock.unlock()
    }

    func get() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
