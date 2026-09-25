import SwiftUI

@main
struct DSHRemoteApp: App {
    @StateObject private var store = ServerStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
