import SwiftUI

@main
struct StrideApp: App {
    // Created at launch: it registers the Watch mirroring handler, which must exist before the
    // system hands us a session from the Watch.
    @State private var run = RunModel()

    var body: some Scene {
        WindowGroup {
            ContentView().environment(run)
        }
    }
}
