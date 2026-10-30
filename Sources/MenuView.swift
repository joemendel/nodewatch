import SwiftUI

struct MenuView: View {
    @Bindable var store: ServerStore
    /// A ScrollView has no height of its own, and a menu bar window sizes to fit
    /// its content, so the list collapses to zero unless it's given a measured height.
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.servers.isEmpty && store.local == nil {
                Text("No dev servers running")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.servers) { server in
                            ServerRow(server: server, store: store)
                            if server.id != store.servers.last?.id { Divider().padding(.leading, 12) }
                        }
                        if let local = store.local {
                            if !store.servers.isEmpty { Divider() }
                            LocalSection(local: local, store: store)
                        }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .frame(height: min(listHeight, 420))
            }
            Divider()
            footer
        }
        .frame(width: 400)
        .onAppear { store.refresh() }
    }

    private var header: some View {
        HStack {
            Text(store.totalCount == 1 ? "1 dev server" : "\(store.totalCount) dev servers")
                .font(.headline)
            Spacer()
            Button { store.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh")
        }
        .padding(12)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Include Python servers", isOn: $store.includePython)
            Toggle("Include Local (WordPress) sites", isOn: $store.includeLocal)
            Toggle("Notify when a new server starts", isOn: $store.notifyOnNew)
            if store.notifyOnNew { notificationStatus }
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.launchAtLogin = $0 }
            ))
            loginItemStatus
            HStack {
                Spacer()
                Button("Quit NodeWatch") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .padding(12)
        .onAppear { store.refreshPermissions() }
    }

    // Inline results, shown under the matching checkbox. macOS reports these
    // changes with banners that land underneath this menu, out of sight.

    @ViewBuilder
    private var notificationStatus: some View {
        switch store.notificationStatus {
        case .denied:
            StatusLine(text: "Blocked in System Settings", color: .orange,
                       action: ("Open Settings", store.openNotificationSettings))
        case .notDetermined:
            StatusLine(text: "Waiting for you to allow notifications", color: .secondary)
        default:
            StatusLine(text: "Allowed", color: .green)
        }
    }

    @ViewBuilder
    private var loginItemStatus: some View {
        if let error = store.loginItemError {
            StatusLine(text: "Couldn't change: \(error)", color: .orange)
        } else {
            switch store.loginItemStatus {
            case .enabled:
                StatusLine(text: "On: NodeWatch starts when you log in", color: .green)
            case .requiresApproval:
                StatusLine(text: "Needs your approval in System Settings", color: .orange,
                           action: ("Open Login Items", store.openLoginItemsSettings))
            default:
                EmptyView()
            }
        }
    }
}

/// A small caption under a checkbox, indented to line up with its label.
struct StatusLine: View {
    let text: String
    let color: Color
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).foregroundStyle(.secondary)
            if let action {
                Button(action.title, action: action.run)
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(.leading, 20)
    }
}

struct ServerRow: View {
    let server: DevServer
    let store: ServerStore
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(server.ports.map { ":\($0)" }.joined(separator: " "))
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                Text(server.projectName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if server.exposed { ExposedIcon() }
                Text(server.uptime)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(server.commandLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: icon)
                Text(server.launcher.label)
                Text("· \(server.runtime) · PID \(String(server.pid))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            HStack(spacing: 8) {
                if server.ports.count > 1 {
                    Menu("Open") {
                        ForEach(server.ports, id: \.self) { port in
                            Button("localhost:\(String(port))") { store.open(server, port: port) }
                        }
                    }
                    .fixedSize()
                } else {
                    Button("Open") { store.open(server) }
                }
                if server.folder != nil {
                    Button("Show Folder") { store.reveal(server) }
                }
                Spacer()
                stopButton
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var stopButton: some View {
        if store.stubborn.contains(server.key) {
            Button("Force Stop", role: .destructive) { store.forceStop(server) }
                .tint(.red)
                .help("It ignored the polite request. This kills it immediately.")
        } else if confirming {
            Button(server.launcher.isService ? "Stop service?" : "Confirm Stop", role: .destructive) {
                confirming = false
                store.stop(server)
            }
            .tint(.red)
            .buttonStyle(.borderedProminent)
            .task {
                // The confirmation quietly resets if you don't click it.
                try? await Task.sleep(for: .seconds(3))
                confirming = false
            }
        } else {
            Button("Stop") { confirming = true }
                .help(server.launcher.isService
                      ? "A background service: it stays stopped until it is next loaded (login), unless it is set to KeepAlive."
                      : "Ask the server to shut down")
        }
    }

    private var icon: String {
        switch server.launcher {
        case .agent: "sparkles"
        case .terminal: "terminal"
        case .service: "gearshape"
        case .orphaned: "questionmark.circle"
        case .unknown: "circle.dotted"
        }
    }
}

/// Sites running in Local (the WordPress app), plus its shared router and Mailpit.
/// There is no Stop here on purpose: Local starts and stops its own sites.
struct LocalSection: View {
    let local: LocalStatus
    let store: ServerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text("Local").font(.subheadline.weight(.semibold))
                if !local.routerPorts.isEmpty {
                    Text("router " + local.routerPorts.map { ":\($0)" }.joined(separator: " "))
                        .font(.caption).foregroundStyle(.secondary)
                    if local.routerExposed { ExposedIcon(what: "Local's router") }
                }
                Spacer()
                if let mail = local.mailpitURL {
                    Button("Mailpit") { store.open(urlString: mail) }
                        .help("Open Mailpit, which catches email your Local sites send")
                    if local.mailpitExposed { ExposedIcon(what: "Mailpit (it shows every email your sites sent)") }
                }
                Button("Open Local") { store.openLocalApp() }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if local.sites.isEmpty {
                Text("No sites running")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 8)
            }
            ForEach(local.sites) { site in
                Divider().padding(.leading, 12)
                LocalSiteRow(site: site, store: store)
            }
        }
    }
}

struct LocalSiteRow: View {
    let site: LocalSite
    let store: ServerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "w.circle")
                    .foregroundStyle(.secondary)
                Text(site.name).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Text(site.uptime).font(.caption).foregroundStyle(.secondary)
            }
            Text(site.domain + (site.php.map { " · PHP \($0)" } ?? ""))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            HStack(spacing: 8) {
                Button("Open") { store.open(urlString: site.url) }
                if let folder = site.folder {
                    Button("Show Folder") { store.reveal(folder: folder) }
                }
                Spacer()
                Button("Stop in Local") { store.openLocalApp() }
                    .help("Local starts and stops its own sites. Stopping them from here would confuse Local and could damage the site's database.")
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// The orange "reachable from your network" marker, shared by every row type.
struct ExposedIcon: View {
    var what: String = "This server"

    var body: some View {
        Image(systemName: "wifi.exclamationmark")
            .foregroundStyle(.orange)
            .help("\(what) is reachable from other devices on your network")
    }
}
