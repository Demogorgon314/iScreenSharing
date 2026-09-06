import Foundation
import OSLog

struct AppleKeyboardKey: Sendable {
    let keyCode: UInt16
    let keyboardType: UInt16
    let symbols: [UInt32]
}

enum AppleKeyboardModifier: CaseIterable, Sendable {
    case shift, control, option, command, capsLock
}

enum AppleKeyboardInputEvent: Sendable {
    case modifiersChanged(AppleKeyboardKey, AppleKeyboardModifier, pressed: Set<AppleKeyboardModifier>)
    case keyDown(AppleKeyboardKey, releaseImmediately: Bool)
    case keyUp(keyCode: UInt16)
}

struct AppleKeyboardStroke: Sendable {
    let key: AppleKeyboardKey
    let isDown: Bool
}

struct AppleKeyboardState {
    private struct Identity: Hashable {
        let source: UUID
        let keyCode: UInt16
    }

    private struct PressedKey {
        let key: AppleKeyboardKey
        let modifier: AppleKeyboardModifier?
    }

    private static let logger = Logger(subsystem: "com.wangkai.iShareScreen", category: "KeyboardInput")
    private var pressedKeys = [Identity: PressedKey]()

    mutating func receive(_ event: AppleKeyboardInputEvent, from source: UUID) -> [AppleKeyboardStroke] {
        switch event {
        case let .modifiersChanged(key, modifier, pressed):
            let missing = pressedKeys.keys.filter { identity in
                guard identity.source == source, identity.keyCode != key.keyCode,
                      let other = pressedKeys[identity]?.modifier else { return false }
                return !pressed.contains(other)
            }
            if !missing.isEmpty {
                Self.logger.notice(
                    "Queueing missing modifier releases: keyCodes=\(missing.map(\.keyCode).sorted().description, privacy: .public) flagsChangedKeyCode=\(key.keyCode)"
                )
            }
            var strokes = release(missing)
            let identity = Identity(source: source, keyCode: key.keyCode)
            if let held = pressedKeys.removeValue(forKey: identity) {
                strokes.append(AppleKeyboardStroke(key: held.key, isDown: false))
            } else if pressed.contains(modifier) {
                pressedKeys[identity] = PressedKey(key: key, modifier: modifier)
                strokes.append(AppleKeyboardStroke(key: key, isDown: true))
            }
            return strokes

        case let .keyDown(key, releaseImmediately):
            let identity = Identity(source: source, keyCode: key.keyCode)
            if let held = pressedKeys[identity] {
                // A modifier change during auto-repeat does not start a new press.
                return [AppleKeyboardStroke(key: held.key, isDown: true)]
            }
            if releaseImmediately {
                // Text input emits one down/up pair per scalar, in order.
                return key.symbols.flatMap { symbol in
                    let scalar = AppleKeyboardKey(
                        keyCode: key.keyCode, keyboardType: key.keyboardType, symbols: [symbol]
                    )
                    return [AppleKeyboardStroke(key: scalar, isDown: true),
                            AppleKeyboardStroke(key: scalar, isDown: false)]
                }
            }
            pressedKeys[identity] = PressedKey(key: key, modifier: nil)
            return [AppleKeyboardStroke(key: key, isDown: true)]

        case let .keyUp(keyCode):
            return release([Identity(source: source, keyCode: keyCode)])
        }
    }

    mutating func release(from source: UUID) -> [AppleKeyboardStroke] {
        let identities = pressedKeys.keys.filter { $0.source == source }
        return release(identities)
    }

    private mutating func release(_ identities: [Identity]) -> [AppleKeyboardStroke] {
        // Release ordinary held keys before their modifiers. Source ownership
        // prevents a late cleanup from releasing another canvas's newer press.
        let ordered = identities.sorted {
            let lhsIsModifier = pressedKeys[$0]?.modifier != nil
            let rhsIsModifier = pressedKeys[$1]?.modifier != nil
            if lhsIsModifier != rhsIsModifier { return !lhsIsModifier }
            return $0.keyCode < $1.keyCode
        }
        return ordered.compactMap { identity in
            pressedKeys.removeValue(forKey: identity).map {
                AppleKeyboardStroke(key: $0.key, isDown: false)
            }
        }
    }
}
