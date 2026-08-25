import Foundation

struct SessionFeaturePreferences {
    static let sharesKeyboardInputSourceKey = "sharesKeyboardInputSource"
    static let usesDynamicResolutionKey = "usesDynamicResolution"
    static let mutesAudioKey = "mutesSessionAudio"
    static let fixedDisplayScaleKey = "sessionFixedDisplayScale"
    static let synchronizesVideoPresentationKey = "synchronizesVideoPresentation"
    static let showsVideoPerformanceOverlayKey = "showsVideoPerformanceOverlay"
    static let showsDetailedVideoMetricsKey = "showsDetailedVideoMetrics"
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

    var mutesAudio: Bool {
        storedBool(forKey: Self.mutesAudioKey, defaultValue: false)
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

    var showsDetailedVideoMetrics: Bool {
        storedBool(forKey: Self.showsDetailedVideoMetricsKey, defaultValue: false)
    }

    var showsMetalPerformanceHUD: Bool {
        storedBool(forKey: Self.showsMetalPerformanceHUDKey, defaultValue: false)
    }

    func setSharesKeyboardInputSource(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.sharesKeyboardInputSourceKey)
    }

    func setUsesDynamicResolution(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.usesDynamicResolutionKey)
    }

    func setMutesAudio(_ muted: Bool) {
        defaults.set(muted, forKey: Self.mutesAudioKey)
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

    func setShowsDetailedVideoMetrics(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.showsDetailedVideoMetricsKey)
    }

    func setShowsMetalPerformanceHUD(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.showsMetalPerformanceHUDKey)
    }

    private func storedBool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
