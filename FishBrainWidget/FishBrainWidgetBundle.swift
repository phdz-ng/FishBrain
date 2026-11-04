import AppIntents
import FishBrainIntents
import SwiftUI
import WidgetKit

/// Includes the deck choice from the FishBrainIntents framework, which the app shares (see there).
struct FishBrainWidgetPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [FishBrainIntentsPackage.self] }
}

@main
struct FishBrainWidgetBundle: WidgetBundle {
    init() {
        DeckEntitySource.install()
    }

    var body: some Widget {
        FishBrainWidget()
    }
}
