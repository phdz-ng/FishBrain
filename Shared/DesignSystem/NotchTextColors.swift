import Foundation

extension Theme {
    /// Text in the resting Card notch. The notch is black in every theme, so these are fixed values
    /// and never follow the app's appearance.
    enum NotchText {
        /// The front of the card.
        static let front = Token(0xFFFFFF)
        /// The answer: the dark theme's orange text.
        static let answer = Token(0xFFA36B)
        /// "Picture", for a side that is only a picture.
        static let secondary = Token(0x8D8D93)
    }
}
