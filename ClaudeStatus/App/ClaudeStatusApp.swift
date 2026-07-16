import SwiftUI

@main
struct ClaudeStatusApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(store: store)
                .task {
                    await store.popoverOpened()
                }
        } label: {
            MenuBarLabel(store: store)
                .task {
                    await store.start()
                }
        }
        .menuBarExtraStyle(.window)
    }
}
