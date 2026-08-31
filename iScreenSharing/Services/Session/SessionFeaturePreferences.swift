import Foundation

enum VideoPerformanceLevel: String, CaseIterable, Identifiable {
    case compact
    case standard
    case detailed

    var id: Self { self }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .detailed: "Detailed"
        }
    }
}

struct SessionFeaturePreferences {
    static let sharesKeyboardInputSourceKey = "sharesKeyboardInputSource"
    static let usesDynamicResolutionKey = "usesDynamicResolution"
    static let fixedDisplayScaleKey = "sessionFixedDisplayScale"
    static let synchronizesVideoPresentationKey = "synchronizesVideoPresentation"
    static let showsVideoPerformanceOverlayKey = "showsVideoPerformanceOverlay"
    static let showsDetailedVideoMetricsKey = "showsDetailedVideoMetrics"
    static let showsMoonlightStyleMetricsKey = "showsMoonlightStyleMetrics"
    static let videoPerformanceLevelKey = "videoPerformanceLevel"
    static let videoDecoderModeKey = "videoDecoderMode"
    static let showsMetalPerformanceHUDKey = "showsMetalPerformanceHUD"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var sharesKeyboardInputSource: Bool {
        storedBool(forKey: Self.sharesKeyboardInputSourceKey, defaultValue: false)
    }

    var usesDynamicResolution: Bool {
        storedBool(forKey: Self.usesDynamicResolutionKey, defaultValue: true)
    }

    var fixedDisplayScale: Double? {
        guard defaults.object(forKey: Self.fixedDisplayScaleKey) != nil else { return nil }
        let scale = defaults.double(forKey: Self.fixedDisplayScaleKey)
        return scale >= 0 ? scale : nil
    }

    var synchronizesVideoPresentation: Bool {
        storedBool(forKey: Self.synchronizesVideoPresentationKey, defaultValue: true)
    }

    var showsVideoPerformanceOverlay: Bool {
        storedBool(forKey: Self.showsVideoPerformanceOverlayKey, defaultValue: false)
    }

    var videoPerformanceLevel: VideoPerformanceLevel {
        if let storedValue = defaults.string(forKey: Self.videoPerformanceLevelKey),
           let level = VideoPerformanceLevel(rawValue: storedValue) {
            return level
        }
        if defaults.bool(forKey: Self.showsMoonlightStyleMetricsKey) {
            return .compact
        }
        if defaults.bool(forKey: Self.showsDetailedVideoMetricsKey) {
            return .detailed
        }
        return .compact
    }

    var showsMetalPerformanceHUD: Bool {
        storedBool(forKey: Self.showsMetalPerformanceHUDKey, defaultValue: false)
    }

    var videoDecoderMode: AppleVideoDecoderMode {
        guard let rawValue = defaults.string(forKey: Self.videoDecoderModeKey),
              let mode = AppleVideoDecoderMode(rawValue: rawValue) else {
            return .videoProcessing
        }
        // Automatic was exposed by earlier builds. The product choice is now
        // explicit, while VCP still degrades safely when it is unavailable.
        return mode == .automatic ? .videoProcessing : mode
    }

    func setSharesKeyboardInputSource(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.sharesKeyboardInputSourceKey)
    }

    func setUsesDynamicResolution(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.usesDynamicResolutionKey)
    }

    func setFixedDisplayScale(_ scale: Double?) {
        if let scale {
            defaults.set(scale, forKey: Self.fixedDisplayScaleKey)
        } else {
            defaults.removeObject(forKey: Self.fixedDisplayScaleKey)
        }
    }

    func setSynchronizesVideoPresentation(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.synchronizesVideoPresentationKey)
    }

    func setShowsVideoPerformanceOverlay(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.showsVideoPerformanceOverlayKey)
    }

    func setVideoPerformanceLevel(_ level: VideoPerformanceLevel) {
        defaults.set(level.rawValue, forKey: Self.videoPerformanceLevelKey)
        defaults.removeObject(forKey: Self.showsDetailedVideoMetricsKey)
        defaults.removeObject(forKey: Self.showsMoonlightStyleMetricsKey)
    }

    func setShowsMetalPerformanceHUD(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.showsMetalPerformanceHUDKey)
    }

    func setVideoDecoderMode(_ mode: AppleVideoDecoderMode) {
        defaults.set(mode.rawValue, forKey: Self.videoDecoderModeKey)
    }

    private func storedBool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
