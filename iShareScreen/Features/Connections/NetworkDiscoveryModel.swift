import Combine
import Foundation

@MainActor
final class NetworkDiscoveryModel: ObservableObject {
    enum State: Equatable {
        case searching
        case results([ConnectionEndpoint])
        case failed(String)
    }

    @Published private(set) var state: State = .searching

    private let browser: any BonjourBrowsing

    init(browser: any BonjourBrowsing = BonjourBrowser()) {
        self.browser = browser
    }

    func browse() async {
        state = .searching
        for await update in browser.updates() {
            guard !Task.isCancelled else { return }
            switch update {
            case .searching:
                state = .searching
            case .results(let endpoints):
                state = .results(endpoints)
            case .failed(let message):
                state = .failed(message)
            }
        }
    }
}
