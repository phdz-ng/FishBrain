import SwiftUI

extension EnvironmentValues {
    /// The user's accent. Every component reads it from here, so setting it once on a root view
    /// (app window, widget, notch) recolors everything beneath.
    @Entry var accentChoice: AccentChoice = .default
}
