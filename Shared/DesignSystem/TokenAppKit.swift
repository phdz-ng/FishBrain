import AppKit
import SwiftUI

extension Token {
    /// The token as an AppKit color, for an AppKit view hosted in SwiftUI (the editing field on the Now
    /// showing card). Resolved in that view's environment, so it follows the appearance like the token.
    func nsColor(in environment: EnvironmentValues) -> NSColor {
        NSColor(resolve(in: environment))
    }
}
