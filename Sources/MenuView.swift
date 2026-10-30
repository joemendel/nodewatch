import SwiftUI

struct MenuView: View {
    @Bindable var store: ServerStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if store.servers.isEmpty {
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
                    }
                }
                .frame(maxHeight: 420)
            }
            Divider()
            footer
        }
        .frame(width: 400)
        .onAppear { store.refresh() }
    }

    private var header: some View {
        HStack {
            Text(store.servers.count == 1 ? "1 dev server" : "\(store.servers.count) dev servers")
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
            Toggle("Notify when a new server starts", isOn: $store.notifyOnNew)
            Toggle("Launch at login", isOn: Binding(
                get: { store.launchAtLogin },
                set: { store.launchAtLogin = $0 }
            ))
            HStack {
                Spacer()
                Button("Quit NodeWatch") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .toggleStyle(.checkbox)
        .font(.callout)
        .padding(12)
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
                if server.exposed {
                    Image(systemName: "wifi.exclamationmark")
                        .foregroundStyle(.orange)
                        .help("Listening on all interfaces: reachable from your network")
                }
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
        if store.stubborn.contains(server.pid) {
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
