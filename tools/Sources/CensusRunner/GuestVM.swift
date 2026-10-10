import Foundation

/// A throwaway macOS guest, cloned from the stopped golden Lima instance (ADR 0006).
///
/// Isolation is per run, not per cell: the guest is created fresh for a run and deleted at the end.
/// `limactl snapshot` is unimplemented for macOS guests, but `limactl clone` is an instant APFS copy.
public struct GuestVM: Sendable {
    public var golden: String
    public var instance: String

    public static let goldenName = "census-macos"
    /// Where a cell's package is unpacked inside the guest. Fixed, so attribution is a prefix test.
    public static let packageRoot = "/Users/aj.guest/pkg"
    public static let outDirectory = "/Users/aj.guest/out"
    public static let stageDirectory = "/Users/aj.guest/stage"
    public static let swiftPMCache = "/Users/aj.guest/swiftpm-cache"
    public static let moduleCache = "/Users/aj.guest/modcache"

    /// The restore image's SHA-256, read from the pinned Lima template, as the guest's identity in each record.
    public static func restoreImageDigest(template: String = "tools/vm/census-macos.yaml") -> String? {
        guard let text = try? String(contentsOfFile: template, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("digest:") {
            return "ipsw-" + line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: CharacterSet(charactersIn: " \""))
        }
        return nil
    }

    public init(golden: String = GuestVM.goldenName, runId: String) {
        self.golden = golden
        self.instance = "census-run-" + runId.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    /// Clones the golden instance, boots the clone, and refuses to continue until the egress firewall is
    /// verifiably active. Any stale instance of the same name is deleted first.
    public func create() async throws {
        _ = try? await Shell.run("limactl", ["delete", instance, "--force"])
        try await Shell.check("limactl", ["clone", golden, instance, "--tty=false"])
        // `limactl start` can be slow to report READY on a first boot (it waits for boot scripts), and its
        // exit status is not what matters: a working SSH session is.
        _ = try? await Shell.run("limactl", ["start", instance, "--tty=false"], timeout: 300)
        try await waitUntil("SSH to the guest", seconds: 180) { (try? await shell("true"))?.succeeded == true }
        try await requireFirewall()
        _ = try await shell("mkdir -p \(GuestVM.stageDirectory) \(GuestVM.swiftPMCache) \(GuestVM.moduleCache)")
    }

    /// The pf policy loads from a LaunchDaemon *after* SSH comes up, so a build started immediately could
    /// run before it. Wait for the rules, then check behaviour, not just configuration: the NAT host
    /// address must not answer ping.
    func requireFirewall() async throws {
        try await waitUntil("the guest egress firewall", seconds: 120) {
            let rules = (try? await shell("P=$(cat ~/password); echo \"$P\" | sudo -S -p '' pfctl -sr 2>/dev/null"))?.stdoutString ?? ""
            return rules.contains("block drop out quick proto tcp from any to <private>")
        }
        let ping = try await shell("ping -c 1 -t 3 192.168.5.1 >/dev/null 2>&1; echo $?")
        guard ping.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) != "0" else {
            throw GuestError.firewallNotEffective
        }
    }

    private func waitUntil(_ what: String, seconds: Int, _ condition: () async -> Bool) async throws {
        for _ in 0..<(seconds / 3) {
            if await condition() { return }
            try await Task.sleep(for: .seconds(3))
        }
        throw GuestError.timedOut(what)
    }

    public func destroy() async {
        _ = try? await Shell.run("limactl", ["stop", instance], timeout: 300)
        _ = try? await Shell.run("limactl", ["delete", instance, "--force"])
    }

    @discardableResult
    public func shell(_ script: String, timeout: TimeInterval? = nil) async throws -> ProcessResult {
        try await Shell.run("limactl", ["shell", instance, "--", "bash", "-c", script], timeout: timeout)
    }

    public func copyTo(_ local: URL, remote: String) async throws {
        try await Shell.check("limactl", ["copy", local.path, "\(instance):\(remote)"], timeout: 600)
    }

    public func copyFrom(remote: String, local: URL) async throws {
        try await Shell.check("limactl", ["copy", "\(instance):\(remote)", local.path], timeout: 600)
    }

    /// Reads `sw_vers`, `xcodebuild -version` and `swift --version` for the run record (F7).
    public func describe() async -> String {
        let r = try? await shell("sw_vers; xcodebuild -version; swift --version 2>&1 | head -1")
        return r?.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
    }
}

public enum GuestError: Error, CustomStringConvertible {
    case timedOut(String)
    case firewallNotEffective
    public var description: String {
        switch self {
        case .timedOut(let what): "timed out waiting for \(what)"
        case .firewallNotEffective:
            "guest egress firewall is loaded but the host NAT address still answers ping; refusing to build"
        }
    }
}
