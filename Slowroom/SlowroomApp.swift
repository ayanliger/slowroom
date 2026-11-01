import SwiftUI

@main
struct SlowroomApp: App {
    @State private var model = DeckModel()

    var body: some Scene {
        WindowGroup {
            DeckView(model: model)
                .preferredColorScheme(.dark)
                .tint(DeckTheme.amber)
        }
    }
}
