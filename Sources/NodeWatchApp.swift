import SwiftUI

@main
struct NodeWatchApp: App {
    @State private var store = ServerStore()

    var body: some Scene {
        MenuBarExtra {
            MenuView(store: store)
        } label: {
            // Menu bar labels render as template images; a count next to the icon
            // is the cue that something is running. The network-exposure warning
            // lives on each row in the menu, so the menu bar stays calm.
            Image(systemName: "server.rack")
            if store.totalCount > 0 {
                Text("\(store.totalCount)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
