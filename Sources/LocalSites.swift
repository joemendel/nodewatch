import Foundation

/// A running site in Local (localwp.com), the WordPress development app.
struct LocalSite: Identifiable, Sendable, Equatable {
    let id: String               // Local's internal site ID
    let name: String
    let domain: String           // e.g. mysite.local
    let folder: String?
    let php: String?
    let uptime: String
    let url: String              // the domain through Local's router, or localhost:port without it
}

/// Local's shared services plus its running sites.
struct LocalStatus: Sendable, Equatable {
    var sites: [LocalSite] = []
    var routerPorts: [Int] = []
    var routerExposed = false
    var mailpitURL: String?      // web page of Mailpit, which catches the sites' outgoing email
    var mailpitExposed = false
}

extension Scanner {
    static let localBundleID = "com.getflywheel.lightning.local"

    /// Local runs each site as its own nginx, PHP-FPM and MySQL, plus one shared
    /// router (nginx on 80/443) and Mailpit. Each site's processes have
    /// ".../Local/run/<site id>/" in their arguments; the router has ".../Local/run/router/".
    ///
    /// This relies on Local's internal layout, which isn't a public interface.
    /// If it changes, this returns nil and the Local section simply disappears.
    static func scanLocal(listeners: [Int32: Listener]) -> LocalStatus? {
        guard let out = run("/bin/ps", ["-axo", "pid=,etime=,args="]) else { return nil }

        var siteElapsed: [String: [String]] = [:]
        var sitePids: [String: [Int32]] = [:]
        var routerPids: [Int32] = []
        var mailpitPids: [Int32] = []

        for line in out.split(separator: "\n") {
            guard line.contains("/Local/") else { continue }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]) else { continue }
            let args = parts[2]
            if args.contains("/Local/lightning-services/mailpit") { mailpitPids.append(pid); continue }
            guard let range = args.range(of: "/Local/run/") else { continue }
            let id = args[range.upperBound...].prefix { $0 != "/" }
            guard !id.isEmpty else { continue }
            if id == "router" {
                routerPids.append(pid)
            } else {
                siteElapsed[String(id), default: []].append(String(parts[1]))
                sitePids[String(id), default: []].append(pid)
            }
        }
        guard !siteElapsed.isEmpty || !routerPids.isEmpty || !mailpitPids.isEmpty else { return nil }

        var status = LocalStatus()
        let router = merged(routerPids, listeners)
        status.routerPorts = router.ports.sorted()
        status.routerExposed = router.exposed
        let usesRouter = router.ports.contains(80)

        let info = readSites()
        let mailpit = merged(mailpitPids, listeners)
        status.mailpitExposed = mailpit.exposed
        if let web = info.values.compactMap(\.mailpitWebPort).first(where: { mailpit.ports.contains($0) }) {
            status.mailpitURL = "http://localhost:\(web)"
        }

        status.sites = siteElapsed.keys.sorted().map { id in
            let site = info[id]
            let ownPort = merged(sitePids[id] ?? [], listeners).ports.sorted().first
            let domain = site?.domain ?? id
            let url: String
            if usesRouter, site?.domain != nil { url = "http://\(domain)" }
            else if let ownPort { url = "http://localhost:\(ownPort)" }
            else { url = "http://\(domain)" }
            // The site's processes start together; the longest-running one is its uptime.
            let longest = (siteElapsed[id] ?? []).max { elapsedSeconds($0) < elapsedSeconds($1) } ?? ""
            return LocalSite(id: id, name: site?.name ?? "Unknown site", domain: domain,
                             folder: site?.folder, php: site?.php,
                             uptime: formatElapsed(longest), url: url)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return status
    }

    private static func merged(_ pids: [Int32], _ listeners: [Int32: Listener]) -> Listener {
        var result = Listener(command: "")
        for pid in pids {
            guard let l = listeners[pid] else { continue }
            result.ports.formUnion(l.ports)
            result.hosts.formUnion(l.hosts)
        }
        return result
    }

    private struct SiteInfo {
        let name: String?
        let domain: String?
        let folder: String?
        let php: String?
        let mailpitWebPort: Int?
    }

    /// sites.json also holds each site's database credentials. Only the fields
    /// below are copied out; the parsed file is dropped as soon as this returns.
    private static func readSites() -> [String: SiteInfo] {
        let path = NSHomeDirectory() + "/Library/Application Support/Local/sites.json"
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var result: [String: SiteInfo] = [:]
        for (id, value) in json {
            guard let site = value as? [String: Any] else { continue }
            let services = site["services"] as? [String: Any]
            let php = (services?["php"] as? [String: Any])?["version"] as? String
            let mailpitPorts = ((services?["mailpit"] as? [String: Any])?["ports"] as? [String: Any])?["WEB"] as? [Int]
            let folder = (site["path"] as? String).map { ($0 as NSString).expandingTildeInPath }
            result[id] = SiteInfo(name: site["name"] as? String, domain: site["domain"] as? String,
                                  folder: folder, php: php, mailpitWebPort: mailpitPorts?.first)
        }
        return result
    }

    /// ps etime "[[dd-]hh:]mm:ss" in seconds, for comparing uptimes.
    static func elapsedSeconds(_ etime: String) -> Int {
        var days = 0
        var rest = Substring(etime)
        if let dash = rest.firstIndex(of: "-") {
            days = Int(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        let nums = rest.split(separator: ":").compactMap { Int($0) }
        let seconds = nums.reduce(0) { $0 * 60 + $1 }
        return days * 86_400 + seconds
    }
}
