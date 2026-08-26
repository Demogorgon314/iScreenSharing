import Combine
import Foundation

@MainActor
final class AppleRemoteSystemCapabilities: ObservableObject {
    @Published private(set) var supportedCommands = Set<AppleRemoteSystemCommand>()

    func receive(keySymbols: Set<UInt32>) {
        supportedCommands = Set(keySymbols.compactMap(AppleRemoteSystemCommand.init(rawValue:)))
    }

    func supports(_ command: AppleRemoteSystemCommand) -> Bool {
        supportedCommands.contains(command)
    }
}

