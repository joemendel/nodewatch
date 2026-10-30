import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

@MainActor
@Observable
final class ServerStore {
    private(set) var servers: [DevServer] = []
    private(set) var local: LocalStatus?
    private(set) var lastScan: Date?

    /// What the menu bar count shows: dev servers plus running Local sites.
    var totalCount: Int { servers.count + (local?.sites.count ?? 0) }
    /// Processes that were asked to stop but are still running: offer a force stop.
    private(set) var stubborn: Set<ProcessKey> = []

    var includePython: Bool {
        didSet {
            UserDefaults.standard.set(includePython, forKey: "includePython")
            // Servers that appear only because of this toggle aren't "new".
            suppressNextNotifications = true
            refresh()
        }
    }
    var includeLocal: Bool {
        didSet {
            UserDefaults.standard.set(includeLocal, forKey: "includeLocal")
            refresh()
        }
    }
    var notifyOnNew: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnNew, forKey: "notifyOnNew")
            if notifyOnNew { requestNotificationPermission() }
        }
    }

    /// Servers already seen, as port + folder rather than PID: watch-mode tools
    /// (node --watch, nodemon, tsx watch) restart under a new PID on every save,
    /// and that shouldn't count as a new server.
    private var knownEndpoints: Set<String> = []
    private var suppressNextNotifications = true
    private var scanning = false
    private var rescanPending = false
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["includePython": false, "includeLocal": false, "notifyOnNew": true])
        includePython = defaults.bool(forKey: "includePython")
        includeLocal = defaults.bool(forKey: "includeLocal")
        notifyOnNew = defaults.bool(forKey: "notifyOnNew")
        if notifyOnNew { requestNotificationPermission() }
        refresh()
        // Background polling keeps the menu bar count honest. A scan is ~250 ms of
        // mostly waiting; the tolerance lets macOS batch these wake-ups with others.
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 1
        self.timer = timer
    }

    func refresh() {
        // A refresh requested mid-scan (say, a toggle change) runs right after it,
        // so the result never reflects stale settings.
        guard !scanning else { rescanPending = true; return }
        scanning = true
        let python = includePython
        let withLocal = includeLocal
        var knownLaunchers: [ProcessKey: Launcher] = [:]
        for server in servers { knownLaunchers[server.key] = server.launcher }
        Task.detached(priority: .utility) {
            let result = await Scanner.scan(includePython: python, includeLocal: withLocal, knownLaunchers: knownLaunchers)
            await MainActor.run { self.apply(result) }
        }
    }

    private func apply(_ result: ScanResult?) {
        scanning = false
        defer {
            if rescanPending { rescanPending = false; refresh() }
        }
        // nil means the scan itself failed. Keep the last good list rather than
        // reporting "nothing running" and re-notifying everything next time.
        guard let result else { return }
        let found = result.servers
        local = result.local

        let endpoints = Set(found.map(endpoint))
        if !suppressNextNotifications, notifyOnNew {
            for server in found where !knownEndpoints.contains(endpoint(server)) { notify(server) }
        }
        knownEndpoints = endpoints
        suppressNextNotifications = false
        stubborn = stubborn.intersection(Set(found.map(\.key)))
        servers = found
        lastScan = Date()
    }

    private func endpoint(_ server: DevServer) -> String {
        "\(server.primaryPort)|\(server.folder ?? server.commandLine)"
    }

    // MARK: - Actions

    func open(_ server: DevServer, port: Int? = nil) {
        guard let url = URL(string: "http://\(server.openHost):\(port ?? server.primaryPort)") else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ server: DevServer) {
        guard let folder = server.folder else { return }
        reveal(folder: folder)
    }

    func reveal(folder: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    func open(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Local sites are started and stopped in Local itself. Stopping their
    /// processes from here would leave Local showing them as running, and a
    /// forced stop risks corrupting the site's MySQL database.
    func openLocalApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Scanner.localBundleID) else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// SIGTERM lets the server shut down cleanly. If it is still alive 2 s later,
    /// the row offers a force stop (SIGKILL).
    ///
    /// The row's PID can be up to 5 s old. If that server exited on its own and
    /// macOS gave the PID to another process, signalling it would hit the wrong
    /// thing, so every signal first checks the start time still matches.
    func stop(_ server: DevServer) {
        guard server.key.isAlive else { refresh(); return }
        kill(server.pid, SIGTERM)
        Task {
            try? await Task.sleep(for: .seconds(2))
            if server.key.isAlive { stubborn.insert(server.key) }
            refresh()
        }
    }

    func forceStop(_ server: DevServer) {
        stubborn.remove(server.key)
        guard server.key.isAlive else { refresh(); return }
        kill(server.pid, SIGKILL)
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            refresh()
        }
    }

    // MARK: - Launch at login

    /// macOS confirms login-item changes with its own banner, which slides in
    /// under this menu. The menu shows the result inline so the banner isn't needed.
    private(set) var loginItemStatus: SMAppService.Status = SMAppService.mainApp.status
    private(set) var loginItemError: String?

    var launchAtLogin: Bool {
        get { loginItemStatus == .enabled || loginItemStatus == .requiresApproval }
        set {
            loginItemError = nil
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                loginItemError = error.localizedDescription
            }
            loginItemStatus = SMAppService.mainApp.status
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Notifications

    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined

    /// Called when the menu opens: either setting can change in System Settings
    /// while NodeWatch is running.
    func refreshPermissions() {
        loginItemStatus = SMAppService.mainApp.status
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self.notificationStatus = status }
        }
    }

    func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.joemendel.nodewatch") else { return }
        NSWorkspace.shared.open(url)
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            Task { @MainActor in self.refreshPermissions() }
        }
    }

    private func notify(_ server: DevServer) {
        let content = UNMutableNotificationContent()
        content.title = "New \(server.runtime) server on :\(server.primaryPort)"
        content.body = "\(server.projectName) · started by \(server.launcher.label)"
            + (server.exposed ? "\nReachable from your network" : "")
        let request = UNNotificationRequest(identifier: "server-\(server.pid)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
