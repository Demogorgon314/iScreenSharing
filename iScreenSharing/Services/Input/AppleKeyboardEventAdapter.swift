import AppKit

extension AppleKeyboardInputEvent {
    @MainActor
    init?(_ event: NSEvent) {
        let keyboardType = UInt16(clamping:
            event.cgEvent?.getIntegerValueField(.keyboardEventKeyboardType) ?? 0
        )
        switch event.type {
        case .flagsChanged:
            guard let modifier = AppleKeySymbol.modifier(for: event.keyCode) else { return nil }
            let pressed = Set(AppleKeyboardModifier.allCases.filter {
                event.modifierFlags.contains($0.eventFlag)
            })
            self = .modifiersChanged(
                AppleKeyboardKey(keyCode: event.keyCode, keyboardType: keyboardType, symbols: [modifier.symbol]),
                modifier.kind, pressed: pressed
            )
        case .keyDown:
            if let symbol = AppleKeySymbol.special[event.keyCode] {
                self = .keyDown(
                    AppleKeyboardKey(keyCode: event.keyCode, keyboardType: keyboardType, symbols: [symbol]),
                    releaseImmediately: false
                )
                return
            }
            let hasCommandModifier = !event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            let characters = hasCommandModifier ? event.charactersIgnoringModifiers : event.characters
            guard let symbols = characters?.unicodeScalars.map(\.value), !symbols.isEmpty else { return nil }
            self = .keyDown(
                AppleKeyboardKey(keyCode: event.keyCode, keyboardType: keyboardType, symbols: symbols),
                releaseImmediately: !hasCommandModifier
            )
        case .keyUp:
            self = .keyUp(keyCode: event.keyCode)
        default:
            return nil
        }
    }
}

private extension AppleKeyboardModifier {
    var eventFlag: NSEvent.ModifierFlags {
        switch self {
        case .shift: .shift
        case .control: .control
        case .option: .option
        case .command: .command
        case .capsLock: .capsLock
        }
    }
}

private enum AppleKeySymbol {
    static let special: [UInt16: UInt32] = [
        53: 0xff1b, 48: 0xff09, 51: 0xff08, 36: 0xff0d, 117: 0xffff,
        114: 0xff63, 115: 0xff50, 119: 0xff57, 116: 0xff55, 121: 0xff56,
        123: 0xff51, 126: 0xff52, 124: 0xff53, 125: 0xff54,
        122: 0xffbe, 120: 0xffbf, 99: 0xffc0, 118: 0xffc1,
        96: 0xffc2, 97: 0xffc3, 98: 0xffc4, 100: 0xffc5,
        101: 0xffc6, 109: 0xffc7, 103: 0xffc8, 111: 0xffc9,
    ]

    static func modifier(for keyCode: UInt16) -> (kind: AppleKeyboardModifier, symbol: UInt32)? {
        switch keyCode {
        case 56: (.shift, 0xffe1)
        case 60: (.shift, 0xffe2)
        case 59: (.control, 0xffe3)
        case 62: (.control, 0xffe4)
        case 58: (.option, 0xffe9)
        case 61: (.option, 0xffea)
        case 55: (.command, 0xffeb)
        case 54: (.command, 0xffec)
        case 57: (.capsLock, 0xffe5)
        default: nil
        }
    }
}
