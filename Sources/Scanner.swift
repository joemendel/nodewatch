import Foundation

/// One dev server process that is listening on at least one TCP port.
struct DevServer: Identifiable, Sendable, Equatable {
    let pid: Int32
    let runtime: String          // node, bun, deno, python
    let ports: [Int]
    let exposed: Bool            // listening on all interfaces, reachable from the network
    let folder: String?          // working directory, nil when it is "/"
    let commandLine: String      // what was run, trimmed for display
    let uptime: String
    let launcher: Launcher

    var id: Int32 { pid }
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

enum Scanner {
    /// One lsof pass to find listeners, then four lookups run in parallel.
    /// Run one after another they cost ~450 ms, mostly process startup.
    static func scan(includePython: Bool) -> [DevServer] {
        let listeners = listeningProcesses(includePython: includePython)
        guard !listeners.isEmpty else { return [] }

        let pids = listeners.keys.sorted()
        nonisolated(unsafe) var cwds: [Int32: String] = [:]
        nonisolated(unsafe) var table: [Int32: ProcInfo] = [:]
        nonisolated(unsafe) var args: [Int32: String] = [:]
        nonisolated(unsafe) var services: [Int32: String] = [:]
        // Each index writes only its own variable, so there is no shared mutation.
        DispatchQueue.concurrentPerform(iterations: 4) { i in
            switch i {
            case 0: cwds = workingDirectories(pids: pids)
            case 1: table = processTable()
            case 2: args = commandLines(pids: pids)
            default: services = launchdLabels()
            }
        }

        var launchers: [Int32: Launcher] = [:]
        for pid in pids { launchers[pid] = launcher(for: pid, table: table, services: services) }
        // A server whose launcher exited lost its parent chain, but not the
        // environment it was started with. Check that for agent markers.
        let detached = pids.filter { launchers[$0] == .orphaned || launchers[$0] == .unknown }
        for (pid, name) in launchersFromEnvironment(pids: detached) {
            launchers[pid] = .agent("\(name) (detached)")
        }

        return pids.compactMap { pid -> DevServer? in
            guard let l = listeners[pid] else { return nil }
            let cwd = cwds[pid]
            return DevServer(
                pid: pid,
                runtime: l.runtime,
                ports: l.ports.sorted(),
                exposed: l.exposed,
                folder: (cwd == nil || cwd == "/") ? nil : cwd,
                commandLine: summarize(args[pid] ?? l.runtime),
                uptime: formatElapsed(table[pid]?.elapsed ?? ""),
                launcher: launchers[pid] ?? .unknown
            )
        }
        .sorted { $0.primaryPort < $1.primaryPort }
    }

    // MARK: - lsof

    private struct Listener {
        var runtime: String
        var ports: Set<Int> = []
        var exposed = false
    }

    private static func runtime(for command: String, includePython: Bool) -> String? {
        let c = command.lowercased()
        if c == "node" || c.hasPrefix("node") { return "node" }
        if c == "bun" { return "bun" }
        if c == "deno" { return "deno" }
        if includePython, c.hasPrefix("python") { return "python" }
        return nil
    }

    /// `+c 0` asks lsof for full command names instead of 9-character truncations.
    private static func listeningProcesses(includePython: Bool) -> [Int32: Listener] {
        let out = run("/usr/sbin/lsof", ["-nP", "+c", "0", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"])
        var result: [Int32: Listener] = [:]
        var pid: Int32 = 0
        var runtimeName: String?

        for line in out.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int32(value) ?? 0
                runtimeName = nil
            case "c":
                runtimeName = runtime(for: value, includePython: includePython)
            case "n":
                guard let runtimeName, pid > 0,
                      let colon = value.lastIndex(of: ":"),
                      let port = Int(value[value.index(after: colon)...]) else { continue }
                let host = value[..<colon]
                var l = result[pid] ?? Listener(runtime: runtimeName)
                l.ports.insert(port)
                if host == "*" || host == "0.0.0.0" || host == "[::]" { l.exposed = true }
                result[pid] = l
            default:
                continue
            }
        }
        return result
    }

    private static func workingDirectories(pids: [Int32]) -> [Int32: String] {
        let list = pids.map(String.init).joined(separator: ",")
        let out = run("/usr/sbin/lsof", ["-a", "-p", list, "-d", "cwd", "-F", "pn"])
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

    private static func processTable() -> [Int32: ProcInfo] {
        let out = run("/bin/ps", ["-axo", "pid=,ppid=,etime=,comm="])
        var table: [Int32: ProcInfo] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            table[pid] = ProcInfo(ppid: ppid, elapsed: String(parts[2]), executable: String(parts[3]))
        }
        return table
    }

    private static func commandLines(pids: [Int32]) -> [Int32: String] {
        let list = pids.map(String.init).joined(separator: ",")
        let out = run("/bin/ps", ["-o", "pid=,args=", "-p", list])
        var result: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            result[pid] = String(parts[1])
        }
        return result
    }

    /// Maps running launchd jobs (LaunchAgents) to their labels, skipping Apple's own.
    private static func launchdLabels() -> [Int32: String] {
        let out = run("/bin/launchctl", ["list"])
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

    /// Environment markers that identify who started a process. Only these exact
    /// names are checked: agent environments also carry tokens, so nothing else is
    /// read out of the `ps eww` output, kept, or shown.
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

    private static func launchersFromEnvironment(pids: [Int32]) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let list = pids.map(String.init).joined(separator: ",")
        let out = run("/bin/ps", ["eww", "-o", "pid=,command=", "-p", list])
        var result: [Int32: String] = [:]
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let tokens = Set(parts[1].split(separator: " ").map(String.init))
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

    /// "/opt/homebrew/bin/node /Users/joe/x/node_modules/.bin/vite --port 5173" -> "vite --port 5173"
    private static func summarize(_ args: String) -> String {
        var parts = args.split(separator: " ").map(String.init)
        if let first = parts.first, ["node", "bun", "deno"].contains((first as NSString).lastPathComponent) || first.lowercased().contains("python") {
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

    private static func run(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
