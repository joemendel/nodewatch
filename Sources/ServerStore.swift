import AppKit
import Foundation
import Observation
import ServiceManagement
import UserNotifications

@MainActor
@Observable
final class ServerStore {
    private(set) var servers: [DevServer] = []
    private(set) var lastScan: Date?
    /// PIDs that were asked to stop but are still running: offer a force stop.
    private(set) var stubborn: Set<Int32> = []

    var includePython: Bool {
        didSet { UserDefaults.standard.set(includePython, forKey: "includePython"); refresh() }
    }
    var notifyOnNew: Bool {
        didSet {
            UserDefaults.standard.set(notifyOnNew, forKey: "notifyOnNew")
            if notifyOnNew { requestNotificationPermission() }
        }
    }

    private var known: Set<Int32> = []
    private var firstScanDone = false
    private var scanning = false
    private var timer: Timer?

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["includePython": false, "notifyOnNew": true])
        includePython = defaults.bool(forKey: "includePython")
        notifyOnNew = defaults.bool(forKey: "notifyOnNew")
        if notifyOnNew { requestNotificationPermission() }
        refresh()
        // Background polling keeps the menu bar count honest. A scan is ~50 ms.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let python = includePython
        Task.detached(priority: .utility) {
            let found = Scanner.scan(includePython: python)
            await MainActor.run { self.apply(found) }
        }
    }

    private func apply(_ found: [DevServer]) {
        scanning = false
        let pids = Set(found.map(\.pid))
        if firstScanDone, notifyOnNew {
            for server in found where !known.contains(server.pid) { notify(server) }
        }
        known = pids
        firstScanDone = true
        stubborn = stubborn.intersection(pids)
        servers = found
        lastScan = Date()
    }

    // MARK: - Actions

    func open(_ server: DevServer, port: Int? = nil) {
        guard let url = URL(string: "http://localhost:\(port ?? server.primaryPort)") else { return }
        NSWorkspace.shared.open(url)
    }

    func reveal(_ server: DevServer) {
        guard let folder = server.folder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)])
    }

    /// SIGTERM lets the server shut down cleanly. If it is still alive 2 s later,
    /// the row offers a force stop (SIGKILL).
    func stop(_ server: DevServer) {
        kill(server.pid, SIGTERM)
        Task {
            try? await Task.sleep(for: .seconds(2))
            if kill(server.pid, 0) == 0 { stubborn.insert(server.pid) }
            refresh()
        }
    }

    func forceStop(_ server: DevServer) {
        kill(server.pid, SIGKILL)
        stubborn.remove(server.pid)
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
