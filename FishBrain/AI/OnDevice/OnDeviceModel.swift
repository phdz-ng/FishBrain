import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Whether the model that comes with the Mac can make cards, and what it can do. It only exists on macOS 26 or
/// later with Apple Intelligence turned on, and FishBrain itself runs from macOS 14, so every use of it is behind
/// an availability check.
struct OnDeviceStatus: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// This Mac runs a system older than macOS 26.
        case needsNewerSystem
        /// This Mac can't run Apple Intelligence.
        case deviceNotEligible
        /// Apple Intelligence is switched off in System Settings.
        case appleIntelligenceOff
        /// It is on, but the model is still downloading or getting ready.
        case modelNotReady
        case unknown
    }

    var reason: Reason?
    /// How many tokens the model reads and writes in one go, the question and the answer together.
    var contextSize: Int
    /// Whether it can be given a picture (macOS 27 and later).
    var supportsImages: Bool
    /// Whether it can write in the language the Mac is set to.
    var supportsCurrentLanguage: Bool

    var isAvailable: Bool { reason == nil }

    /// The model's context when it can't be asked (the least any Mac with it has).
    static let defaultContextSize = 4096

    static func unavailable(_ reason: Reason) -> OnDeviceStatus {
        OnDeviceStatus(reason: reason, contextSize: defaultContextSize, supportsImages: false, supportsCurrentLanguage: false)
    }

    static func available(contextSize: Int = defaultContextSize, supportsImages: Bool = false, supportsCurrentLanguage: Bool = true) -> OnDeviceStatus {
        OnDeviceStatus(reason: nil, contextSize: contextSize, supportsImages: supportsImages, supportsCurrentLanguage: supportsCurrentLanguage)
    }

    /// What Settings says on the row: "Available", or "Not available on this Mac".
    var headline: String { isAvailable ? "Available" : "Not available on this Mac" }

    /// Why, and what to do about it.
    var detail: String? {
        switch reason {
        case nil: nil
        case .needsNewerSystem?: "Needs macOS 26 or later."
        case .deviceNotEligible?: "This Mac can't run Apple Intelligence."
        case .appleIntelligenceOff?: "Turn on Apple Intelligence in System Settings."
        case .modelNotReady?: "Apple Intelligence is still getting ready. Try again in a little while."
        case .unknown?: "Apple Intelligence isn't ready on this Mac."
        }
    }
}

/// Asks the system about the on-device model. Tests give their own.
protocol OnDeviceModelProviding: Sendable {
    func status() -> OnDeviceStatus
}

/// The real answer, from the Foundation Models framework.
struct SystemOnDeviceModel: OnDeviceModelProviding {
    func status() -> OnDeviceStatus {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return .unavailable(.needsNewerSystem) }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            var supportsImages = false
            #if compiler(>=6.4)
            if #available(macOS 27.0, *) { supportsImages = model.capabilities.contains(.vision) }
            #endif
            return .available(contextSize: model.contextSize, supportsImages: supportsImages, supportsCurrentLanguage: model.supportsLocale())
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceOff)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.unknown)
            }
        }
        #else
        return .unavailable(.needsNewerSystem)
        #endif
    }
}

/// A fixed answer, for tests and previews.
struct FixedOnDeviceModel: OnDeviceModelProviding {
    var value: OnDeviceStatus
    func status() -> OnDeviceStatus { value }
}
