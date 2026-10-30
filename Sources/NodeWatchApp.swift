import SwiftUI

@main
struct NodeWatchApp: App {
    @State private var store = ServerStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            // Menu bar labels render as template images; a count next to the icon
            // is the cue that something is running.
            if store.servers.isEmpty {
                Image(systemName: "hexagon")
            } else {
                Image(systemName: store.exposedCount > 0 ? "exclamationmark.triangle" : "hexagon.fill")
                Text("\(store.servers.count)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
