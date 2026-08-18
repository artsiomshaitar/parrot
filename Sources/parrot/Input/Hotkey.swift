import ArgumentParser
import CoreGraphics

/// The push-to-talk key.
enum Hotkey: Equatable {
    case fn
    case rightOption
    case leftOption
    case rightCommand
    case rightControl
    case rightShift
    /// Any non-modifier key, matched by keycode.
    case key(code: Int64, label: String)

    /// Modifier bit, or nil for regular keys.
    var mask: CGEventFlags? {
        switch self {
        case .fn: return .maskSecondaryFn
        case .rightOption, .leftOption: return .maskAlternate
        case .rightCommand: return .maskCommand
        case .rightControl: return .maskControl
        case .rightShift: return .maskShift
        case .key: return nil
        }
    }

    /// Physical keycode; nil means any key carrying `mask`.
    var keyCode: Int64? {
        switch self {
        case .fn: return nil
        case .rightCommand: return 54
        case .rightShift: return 60
        case .leftOption: return 58
        case .rightOption: return 61
        case .rightControl: return 62
        case .key(let code, _): return code
        }
    }

    var isModifier: Bool { mask != nil }

    var label: String {
        switch self {
        case .fn: return "fn"
        case .rightOption: return "right-option"
        case .leftOption: return "left-option"
        case .rightCommand: return "right-command"
        case .rightControl: return "right-control"
        case .rightShift: return "right-shift"
        case .key(_, let label): return label
        }
    }

    // MARK: - Parsing

    private static let modifiers: [String: Hotkey] = [
        "fn": .fn,
        "right-option": .rightOption,
        "left-option": .leftOption,
        "right-command": .rightCommand,
        "right-control": .rightControl,
        "right-shift": .rightShift,
    ]

    /// Standard Apple keycodes for the function row.
    private static let functionKeys: [String: Int64] = [
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79,
        "f19": 80, "f20": 90,
    ]

    init?(name: String) {
        let key = name.lowercased()
        if let modifier = Self.modifiers[key] {
            self = modifier
        } else if let code = Self.functionKeys[key] {
            self = .key(code: code, label: key)
        } else if key.hasPrefix("keycode:"), let code = Int64(key.dropFirst("keycode:".count)) {
            self = .key(code: code, label: key)
        } else {
            return nil
        }
    }
}

extension Hotkey: ExpressibleByArgument {
    init?(argument: String) { self.init(name: argument) }

    /// Shown in `--help`, with the function row collapsed to a range.
    static var allValueStrings: [String] {
        Array(modifiers.keys).sorted() + ["f1…f20", "keycode:N"]
    }
}
