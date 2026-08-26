import AppKit
import Combine
import Foundation

@MainActor
final class SessionCommandState: ObservableObject {
    let endpoint: ConnectionEndpoint

    @Published private(set) var displayScale: AppleVideoDisplayScale
    @Published private(set) var synchronizesVideoPresentation: Bool
    @Published private(set) var showsVideoPerformanceOverlay: Bool
    @Published private(set) var videoPerformanceLevel: VideoPerformanceLevel
    @Published private(set) var showsMetalPerformanceHUD: Bool
    @Published private(set) var usesDynamicResolution: Bool
    @Published private(set) var canUseDynamicResolution: Bool
    @Published private(set) var isObserving: Bool
    @Published private(set) var isChangingMode: Bool
    @Published private(set) var sharesKeyboardInputSource: Bool
    @Published private(set) var supportsKeyboardInputSource: Bool
    @Published private(set) var usesSharedClipboard: Bool
    @Published private(set) var isAudioMuted: Bool
    @Published private(set) var supportedRemoteCommands: Set<AppleRemoteSystemCommand>

    private weak var session: RFBAuthenticatedSession?
    private let preferences: SessionFeaturePreferences
    private let displayLayout: AppleDisplayLayoutModel?
    private let dynamicResolution: AppleDynamicResolutionModel?
    private let controlState: AppleSessionControlState?
    private let keyboardInputSource: AppleKeyboardInputSourceService?
    private let clipboardService: AppleClipboardService?
    private let audioStream: AppleAudioStream?
    private let supportsCopyPaste: Bool
    private let supportsSharedClipboard: Bool
    private var subscriptions = Set<AnyCancellable>()

    init(
        endpoint: ConnectionEndpoint,
        session: RFBAuthenticatedSession? = nil,
        displayLayout: AppleDisplayLayoutModel? = nil,
        dynamicResolution: AppleDynamicResolutionModel? = nil,
        controlState: AppleSessionControlState? = nil,
        preferences: SessionFeaturePreferences = SessionFeaturePreferences()
    ) {
        self.endpoint = endpoint
        self.session = session
        self.preferences = preferences
        self.displayLayout = displayLayout
        self.dynamicResolution = dynamicResolution
        self.controlState = controlState
        keyboardInputSource = session?.keyboardInputSourceService
        clipboardService = session?.clipboardService
        audioStream = session?.audioStream
        supportsCopyPaste = session?.serverInfo.supportsCopyPaste ?? false
        supportsSharedClipboard = session?.serverInfo.supportsSharedPasteboard ?? false

        displayScale = AppleVideoDisplayScale(
            fixedScale: preferences.fixedDisplayScale.map { CGFloat($0) }
        )
        synchronizesVideoPresentation = preferences.synchronizesVideoPresentation
        showsVideoPerformanceOverlay = preferences.showsVideoPerformanceOverlay
        videoPerformanceLevel = preferences.videoPerformanceLevel
        showsMetalPerformanceHUD = preferences.showsMetalPerformanceHUD
        usesDynamicResolution = dynamicResolution?.isEnabled ?? false
        canUseDynamicResolution = displayLayout?.supportsDynamicResolution == true
            && session?.dynamicResolutionController != nil
        isObserving = controlState?.isObserving ?? false
        isChangingMode = controlState?.isChangingMode ?? false
        sharesKeyboardInputSource = keyboardInputSource?.isSharingEnabled ?? false
        supportsKeyboardInputSource = keyboardInputSource?.isSupported ?? false
        usesSharedClipboard = clipboardService?.isSharingEnabled ?? false
        isAudioMuted = audioStream?.isMuted ?? false
        supportedRemoteCommands = session?.remoteSystemCapabilities?.supportedCommands ?? []

        observeSessionModels()
    }

    var canUseClipboard: Bool {
        !isObserving
            && !isChangingMode
            && session?.inputController != nil
            && clipboardService != nil
            && supportsCopyPaste
    }

    var canToggleSharedClipboard: Bool { canUseClipboard && supportsSharedClipboard }

    var canGetOrSendClipboard: Bool { canUseClipboard && !usesSharedClipboard }

    var canToggleObservationMode: Bool {
        session != nil && !isChangingMode
    }

    var canShareKeyboardInputSource: Bool {
        !isObserving && !isChangingMode && supportsKeyboardInputSource
    }

    var hasAudio: Bool { audioStream != nil }

    func setDisplayScale(_ scale: AppleVideoDisplayScale) {
        guard scale != displayScale else { return }
        displayScale = scale
        preferences.setFixedDisplayScale(scale.fixedScale.map(Double.init))
    }

    func setScalesToFit(_ scalesToFit: Bool) {
        var scale = displayScale
        scale.setScalesToFit(scalesToFit)
        setDisplayScale(scale)
    }

    func actualSize() {
        var scale = displayScale
        scale.actualSize()
        setDisplayScale(scale)
    }

    func zoomIn() {
        var scale = displayScale
        scale.zoomIn()
        setDisplayScale(scale)
    }

    func zoomOut() {
        var scale = displayScale
        scale.zoomOut()
        setDisplayScale(scale)
    }

    func setSynchronizesVideoPresentation(_ enabled: Bool) {
        guard enabled != synchronizesVideoPresentation else { return }
        synchronizesVideoPresentation = enabled
        preferences.setSynchronizesVideoPresentation(enabled)
    }

    func setShowsVideoPerformanceOverlay(_ enabled: Bool) {
        guard enabled != showsVideoPerformanceOverlay else { return }
        showsVideoPerformanceOverlay = enabled
        preferences.setShowsVideoPerformanceOverlay(enabled)
    }

    func setVideoPerformanceLevel(_ level: VideoPerformanceLevel) {
        guard level != videoPerformanceLevel else { return }
        videoPerformanceLevel = level
        preferences.setVideoPerformanceLevel(level)
    }

    func setShowsMetalPerformanceHUD(_ enabled: Bool) {
        guard enabled != showsMetalPerformanceHUD else { return }
        showsMetalPerformanceHUD = enabled
        preferences.setShowsMetalPerformanceHUD(enabled)
    }

    func setUsesDynamicResolution(_ enabled: Bool) {
        guard canUseDynamicResolution,
              enabled != usesDynamicResolution,
              let dynamicResolution else { return }
        dynamicResolution.isEnabled = enabled
    }

    func setObserving(_ observing: Bool) {
        guard canToggleObservationMode,
              observing != isObserving else { return }
        controlState?.toggleMode()
    }

    func setSharesKeyboardInputSource(_ enabled: Bool) {
        guard canShareKeyboardInputSource,
              enabled != sharesKeyboardInputSource else { return }
        keyboardInputSource?.setSharingEnabled(enabled)
    }

    func setUsesSharedClipboard(_ enabled: Bool) {
        guard canToggleSharedClipboard,
              enabled != usesSharedClipboard else { return }
        clipboardService?.setSharingEnabled(enabled)
    }

    func setAudioMuted(_ muted: Bool) {
        guard let audioStream, muted != isAudioMuted else { return }
        audioStream.toggleMute()
    }

    func getClipboard() {
        guard canGetOrSendClipboard,
              let controlMessages = session?.controlMessageService else { return }
        Task { try? await controlMessages.requestRemoteClipboard() }
    }

    func sendClipboard() {
        let archive = clipboardService?.localArchive()
        guard canGetOrSendClipboard,
              let input = session?.inputController,
              let archive else { return }
        Task { try? await input.sendClipboard(archive) }
    }

    func canPerform(_ command: AppleRemoteSystemCommand) -> Bool {
        !isObserving
            && !isChangingMode
            && session?.inputController != nil
            && supportedRemoteCommands.contains(command)
    }

    func perform(_ command: AppleRemoteSystemCommand) {
        guard canPerform(command), let input = session?.inputController else { return }
        Task { await input.perform(command) }
    }

    private func observeSessionModels() {
        dynamicResolution?.$isEnabled
            .removeDuplicates()
            .sink { [weak self] in self?.usesDynamicResolution = $0 }
            .store(in: &subscriptions)

        displayLayout?.$layout
            .sink { [weak self] _ in self?.refreshDynamicResolutionAvailability() }
            .store(in: &subscriptions)

        controlState?.$isObserving
            .removeDuplicates()
            .sink { [weak self] in self?.isObserving = $0 }
            .store(in: &subscriptions)
        controlState?.$isChangingMode
            .removeDuplicates()
            .sink { [weak self] in self?.isChangingMode = $0 }
            .store(in: &subscriptions)

        keyboardInputSource?.$isSharingEnabled
            .removeDuplicates()
            .sink { [weak self] in self?.sharesKeyboardInputSource = $0 }
            .store(in: &subscriptions)
        keyboardInputSource?.$isSupported
            .removeDuplicates()
            .sink { [weak self] in self?.supportsKeyboardInputSource = $0 }
            .store(in: &subscriptions)

        clipboardService?.$isSharingEnabled
            .removeDuplicates()
            .sink { [weak self] in self?.usesSharedClipboard = $0 }
            .store(in: &subscriptions)

        audioStream?.$isMuted
            .removeDuplicates()
            .sink { [weak self] in self?.isAudioMuted = $0 }
            .store(in: &subscriptions)

        session?.remoteSystemCapabilities?.$supportedCommands
            .removeDuplicates()
            .sink { [weak self] in self?.supportedRemoteCommands = $0 }
            .store(in: &subscriptions)
    }

    private func refreshDynamicResolutionAvailability() {
        canUseDynamicResolution = displayLayout?.supportsDynamicResolution == true
            && session?.dynamicResolutionController != nil
    }
}

@MainActor
final class ActiveSessionCommandRouter: ObservableObject {
    @Published private(set) var active: SessionCommandState?

    private var activeWindowID: ObjectIdentifier?
    private var activeSubscription: AnyCancellable?

    func activate(_ state: SessionCommandState, for window: NSWindow) {
        let windowID = ObjectIdentifier(window)
        guard activeWindowID != windowID || active !== state else { return }
        activeWindowID = windowID
        activeSubscription = state.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
        active = state
    }

    func deactivate(window: NSWindow) {
        guard activeWindowID == ObjectIdentifier(window) else { return }
        activeWindowID = nil
        activeSubscription = nil
        active = nil
    }
}
