import Darwin
import Foundation

/// A process identity that survives PID reuse: macOS can hand a PID to a new
/// process once the old one exits, but the pair (pid, start time) is unique.
struct ProcessKey: Hashable, Sendable {
    let pid: Int32
    let start: UInt64            // microseconds since 1970

    /// Reads the start time from the kernel. nil when the process is gone.
    static func current(_ pid: Int32) -> ProcessKey? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessKey(pid: pid, start: UInt64(info.pbi_start_tvsec) * 1_000_000 + UInt64(info.pbi_start_tvusec))
    }

    /// True only if this exact process is still running.
    var isAlive: Bool { ProcessKey.current(pid) == self }
}

/// One dev server process that is listening on at least one TCP port.
struct DevServer: Identifiable, Sendable, Equatable {
    let key: ProcessKey
    let runtime: String          // node, bun, deno, python
    let ports: [Int]
    let exposed: Bool            // bound to something other than loopback: reachable from the network
    let openHost: String         // where Open should point; localhost unless bound to one specific address
    let folder: String?          // working directory, nil when it is "/"
    let commandLine: String      // what was run, trimmed for display
    let uptime: String
    let launcher: Launcher

    var pid: Int32 { key.pid }
    var id: ProcessKey { key }
    var primaryPort: Int { ports.first ?? 0 }

    var projectName: String {
        if let folder { return (folder as NSString).lastPathComponent }
        return commandLine
    }
}

/// Who started a server, found by walking its parent processes.
enum Launcher: Sendable, Equatable {
    case agent(String)           // Claude Code, Codex, Cursor...
    case terminal(String)        // Terminal, iTerm2, Ghostty...
    case service(String)         // a launchd job with a label (LaunchAgent)
    case orphaned                // parent has exited; adopted by launchd
    case unknown

    var label: String {
        switch self {
        case .agent(let name): name
        case .terminal(let name): name
        case .service(let label): "Service · \(label)"
        case .orphaned: "Orphaned (launcher exited)"
        case .unknown: "Unknown"
        }
    }

    var isService: Bool {
        if case .service = self { return true }
        return false
    }
}

struct ScanResult: Sendable {
    var servers: [DevServer]
    var local: LocalStatus?      // nil when Local isn't included or isn't running
}

enum Scanner {
    /// One lsof pass to find listeners, then four lookups run in parallel
    /// (about 250 ms in all, mostly process startup).
    ///
    /// `knownLaunchers` carries launcher results from earlier scans, so a
    /// detached server's environment is read once, not on every poll.
    /// Returns nil when the scan itself failed, so callers can tell
    /// "couldn't look" apart from "nothing running".
    static func scan(includePython: Bool, includeLocal: Bool, knownLaunchers: [ProcessKey: Launcher]) async -> ScanResult? {
        guard let all = allListeners() else { return nil }
        let local = includeLocal ? scanLocal(listeners: all) : nil

        var listeners: [Int32: Listener] = [:]
        for (pid, l) in all {
            guard let runtime = runtime(for: l.command, includePython: includePython) else { continue }
            var dev = l
            dev.runtime = runtime
            listeners[pid] = dev
        }
        guard !listeners.isEmpty else { return ScanResult(servers: [], local: local) }

        let pids = listeners.keys.sorted()
        async let cwds = workingDirectories(pids: pids)
        async let table = processTable()
        async let args = commandLines(pids: pids)
        async let services = launchdLabels()
        let servers = await assemble(listeners: listeners, pids: pids, knownLaunchers: knownLaunchers,
                                     cwds: cwds, table: table, args: args, services: services)
        return ScanResult(servers: servers, local: local)
    }

    private static func assemble(
        listeners: [Int32: Listener], pids: [Int32], knownLaunchers: [ProcessKey: Launcher],
        cwds: [Int32: String], table: [Int32: ProcInfo], args: [Int32: String], services: [Int32: String]
    ) -> [DevServer] {
        var keys: [Int32: ProcessKey] = [:]
        for pid in pids { keys[pid] = ProcessKey.current(pid) }   // nil: exited mid-scan, dropped below

        var launchers: [Int32: Launcher] = [:]
        var needsEnvironment: [Int32] = []
        for pid in pids {
            guard let key = keys[pid] else { continue }
            if let known = knownLaunchers[key] { launchers[pid] = known; continue }
            let found = launcher(for: pid, table: table, services: services)
            launchers[pid] = found
            if found == .orphaned || found == .unknown { needsEnvironment.append(pid) }
        }
        // A server whose launcher exited lost its parent chain, but not the
        // environment it was started with. Check that for agent markers.
        for (pid, name) in launchersFromEnvironment(pids: needsEnvironment, args: args) {
            launchers[pid] = .agent("\(name) (detached)")
        }

        return pids.compactMap { pid -> DevServer? in
            guard let l = listeners[pid], let key = keys[pid] else { return nil }
            let cwd = cwds[pid]
            return DevServer(
                key: key,
                runtime: l.runtime,
                ports: l.ports.sorted(),
                exposed: l.exposed,
                openHost: l.openHost,
                folder: (cwd == nil || cwd == "/") ? nil : cwd,
                commandLine: summarize(args[pid] ?? l.runtime),
                uptime: formatElapsed(table[pid]?.elapsed ?? ""),
                launcher: launchers[pid] ?? .unknown
            )
        }
        .sorted { $0.primaryPort < $1.primaryPort }
    }

    // MARK: - lsof

    struct Listener: Sendable {
        var command: String
        var runtime: String = ""
        var ports: Set<Int> = []
        var hosts: Set<String> = []

        static func isLoopback(_ host: String) -> Bool {
            host.hasPrefix("127.") || host == "[::1]" || host == "localhost"
        }

        /// lsof prints both the IPv4 and IPv6 wildcard as "*". Anything that is
        /// not loopback (wildcard, a LAN address, a Tailscale address) can be
        /// reached from another machine.
        var exposed: Bool { hosts.contains { !Listener.isLoopback($0) } }

        /// A server bound only to one specific address doesn't answer on
        /// localhost, so Open has to use that address.
        var openHost: String {
            let specific = hosts.filter { $0 != "*" && !Listener.isLoopback($0) }
            if hosts.contains(where: { $0 == "*" || Listener.isLoopback($0) }) || specific.count != 1 {
                return "localhost"
            }
            return specific.first ?? "localhost"
        }
    }

    private static func runtime(for command: String, includePython: Bool) -> String? {
        switch command.lowercased() {
        case "node", "nodejs": return "node"
        case "bun": return "bun"
        case "deno": return "deno"
        case let c where includePython && c.hasPrefix("python"): return "python"
        default: return nil
        }
    }

    /// Every TCP listener you own, with its command name. Dev servers and Local
    /// are both picked out of this one pass.
    /// `+c 0` asks lsof for full command names instead of 9-character truncations.
    private static func allListeners() -> [Int32: Listener]? {
        guard let out = run("/usr/sbin/lsof", ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]) else { return nil }
        var result: [Int32: Listener] = [:]
        var pid: Int32 = 0
        var command = ""

        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value) ?? 0
                command = ""
            case "c":
                command = value
            case "n":
                guard pid > 0,
                      let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                var l = result[pid] ?? Listener(command: command)
                l.ports.insert(port)
                l.hosts.insert(String(value[..<colon]))
                result[pid] = l
            default:
                continue
            }
        }
        return result
    }

    private static func workingDirectories(pids: [Int32]) async -> [Int32: String] {
        let list = pids.map(String.init).joined(separator: ",")
        let out = run("/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd", "-F", "pn"]) ?? ""
        var result: [Int32: String] = [:]
        var pid: Int32 = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") { pid = Int32(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n"), pid > 0 { result[pid] = String(line.dropFirst()) }
        }
        return result
    }

    // MARK: - ps / launchctl

    private struct ProcInfo {
        let ppid: Int32
        let elapsed: String
        let executable: String   // full path; may contain spaces
    }

    private static func processTable() async -> [Int32: ProcInfo] {
        let out = run("/bin/ps", ["-axo", "pid=,ppid=,etime=,comm="]) ?? ""
        var table: [Int32: ProcInfo] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            table[pid] = ProcInfo(ppid: ppid, elapsed: String(parts[2]), executable: String(parts[3]))
        }
        return table
    }

    private static func commandLines(pids: [Int32]) async -> [Int32: String] {
        let list = pids.map(String.init).joined(separator: ",")
        let out = run("/bin/ps", ["-o", "pid=,args=", "-p", list]) ?? ""
        var result: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            result[pid] = String(parts[1])
        }
        return result
    }

    /// Maps running launchd jobs (LaunchAgents) to their labels, skipping Apple's own.
    private static func launchdLabels() async -> [Int32: String] {
        let out = run("/bin/launchctl", ["list"]) ?? ""
        var result: [Int32: String] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t")
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            let label = String(parts[2])
            if !label.hasPrefix("com.apple.") { result[pid] = label }
        }
        return result
    }

    // MARK: - Launcher detection

    private static let agents: [(match: String, name: String)] = [
        ("/.local/share/claude/", "Claude Code"),
        ("/claude-code/", "Claude Code"),
        ("Claude.app/", "Claude"),
        ("codex", "Codex"),
        ("Cursor.app/", "Cursor"),
        ("Windsurf.app/", "Windsurf"),
        ("Antigravity.app/", "Antigravity"),
        ("Visual Studio Code.app/", "VS Code"),
        ("Zed.app/", "Zed"),
    ]

    private static let terminals: [(match: String, name: String)] = [
        ("Terminal.app/", "Terminal"),
        ("iTerm.app/", "iTerm2"),
        ("Ghostty.app/", "Ghostty"),
        ("Warp.app/", "Warp"),
        ("WezTerm.app/", "WezTerm"),
        ("kitty.app/", "kitty"),
        ("Alacritty.app/", "Alacritty"),
    ]

    /// Walks up the parent chain. An agent anywhere above the server wins over the
    /// terminal it runs in, because "Claude Code in Terminal" is the useful answer.
    private static func launcher(for pid: Int32, table: [Int32: ProcInfo], services: [Int32: String]) -> Launcher {
        if let label = services[pid] { return .service(label) }

        var terminal: String?
        var current = table[pid]?.ppid ?? 0
        var steps = 0
        while current > 1, steps < 40, let info = table[current] {
            if let label = services[current] { return .service(label) }
            let exe = info.executable
            let base = (exe as NSString).lastPathComponent.lowercased()
            if base == "claude" { return .agent("Claude Code") }
            if let hit = agents.first(where: { exe.contains($0.match) }) { return .agent(hit.name) }
            if terminal == nil, let hit = terminals.first(where: { exe.contains($0.match) }) { terminal = hit.name }
            current = info.ppid
            steps += 1
        }
        if let terminal { return .terminal(terminal) }
        if table[pid]?.ppid == 1 { return .orphaned }
        return .unknown
    }

    /// Environment markers that identify who started a process.
    private static let environmentMarkers: [(token: String, name: String)] = [
        ("CLAUDECODE=1", "Claude Code"),
        ("__CFBundleIdentifier=com.anthropic.claudefordesktop", "Claude"),
        ("CODEX_SANDBOX=", "Codex"),
        ("CODEX_MANAGED_BY_NPM=", "Codex"),
        ("__CFBundleIdentifier=com.todesktop.230313mzl4w4u92", "Cursor"),
        ("TERM_PROGRAM=vscode", "VS Code"),
        ("TERM_PROGRAM=Apple_Terminal", "Terminal"),
        ("TERM_PROGRAM=iTerm.app", "iTerm2"),
        ("TERM_PROGRAM=ghostty", "Ghostty"),
        ("TERM_PROGRAM=WarpTerminal", "Warp"),
    ]

    /// `ps eww` prints the arguments followed by the whole environment, which in
    /// agent sessions includes tokens. Only the marker names above are matched;
    /// the text is dropped when this returns and is never logged or shown. The
    /// caller caches the result per process, so each server is read once.
    ///
    /// The arguments are cut off first so a process can't fake a launcher by
    /// passing "CLAUDECODE=1" as an argument.
    private static func launchersFromEnvironment(pids: [Int32], args: [Int32: String]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = run("/bin/ps", ["eww", "-o", "pid=,command=", "-p", list]) else { return [:] }
        var result: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            var full = parts[1]
            if let a = args[pid], full.hasPrefix(a) { full = full.dropFirst(a.count) }
            let tokens = Set(full.split(separator: " ").map(String.init))
            // Earlier entries win: an agent beats the terminal it ran in.
            if let hit = environmentMarkers.first(where: { marker in
                marker.token.hasSuffix("=")
                    ? tokens.contains { $0.hasPrefix(marker.token) }
                    : tokens.contains(marker.token)
            }) {
                result[pid] = hit.name
            }
        }
        return result
    }

    // MARK: - Helpers

    /// "/opt/homebrew/bin/node /Users/you/app/node_modules/.bin/vite --port 5173" -> "vite --port 5173"
    private static func summarize(_ args: String) -> String {
        var parts = args.split(separator: " ").map(String.init)
        if let first = parts.first, ["node", "nodejs", "bun", "deno"].contains((first as NSString).lastPathComponent) || first.lowercased().contains("python") {
            parts.removeFirst()
        }
        parts = parts.map { $0.hasPrefix("/") ? ($0 as NSString).lastPathComponent : $0 }
        let text = parts.joined(separator: " ")
        return text.count > 60 ? String(text.prefix(57)) + "…" : (text.isEmpty ? args : text)
    }

    /// ps etime is "[[dd-]hh:]mm:ss".
    static func formatElapsed(_ etime: String) -> String {
        guard !etime.isEmpty else { return "" }
        var days = 0
        var rest = Substring(etime)
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let nums = rest.split(separator: ":").compactMap { Int($0) }
        let (h, m) = nums.count == 3 ? (nums[0], nums[1]) : (0, nums.first ?? 0)
        if days > 0 { return "\(days)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return m > 0 ? "\(m)m" : "just now"
    }

    /// Runs a command and returns its output, or nil if it couldn't start or
    /// had to be killed. The deadline matters: lsof can hang on an unresponsive
    /// network mount, and a hung scan would otherwise freeze the list for good.
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        // Apps launched by launchd have no locale. Set one so non-ASCII paths
        // come back as UTF-8 rather than escaped.
        task.environment = ["LANG": "en_US.UTF-8"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }

        let deadline = DispatchWorkItem { if task.isRunning { task.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        // Read to EOF before waiting, so a full pipe buffer can't deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        deadline.cancel()
        if task.terminationReason == .uncaughtSignal { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
