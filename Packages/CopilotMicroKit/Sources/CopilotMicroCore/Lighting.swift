import Foundation

public enum LightingColor: String, Codable, CaseIterable, Sendable {
    case off
    case white
    case blue
    case purple
    case red
    case amber
    case green
}

public enum LightingAnimation: String, Codable, CaseIterable, Sendable {
    case off
    case steady
    case blink
    case pulse
}

public enum LightingSemanticState: String, Codable, CaseIterable, Sendable {
    case paused
    case disconnected
    case unknown
    case error
    case attention
    case working
    case completed
    case idle
}

public struct Brightness: Equatable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case nonFinite
    }

    public static let defaultValue = Brightness(unchecked: 0.65)
    public let value: Double

    public init(clamping value: Double) throws {
        guard value.isFinite else {
            throw ValidationError.nonFinite
        }
        self.value = min(max(value, 0), 1)
    }

    private init(unchecked value: Double) {
        self.value = value
    }
}

public struct LightingPreferences: Equatable, Sendable {
    public let brightness: Brightness
    public let reducedMotion: Bool

    public init(brightness: Brightness = .defaultValue, reducedMotion: Bool = false) {
        self.brightness = brightness
        self.reducedMotion = reducedMotion
    }
}

public struct LightingProjection: Equatable, Sendable {
    public let semanticState: LightingSemanticState
    public let color: LightingColor
    public let animation: LightingAnimation
    public let textualState: String
    public let brightness: Brightness
    public let appliesToAllKeys: Bool

    public init(
        semanticState: LightingSemanticState,
        color: LightingColor,
        animation: LightingAnimation,
        textualState: String,
        brightness: Brightness,
        appliesToAllKeys: Bool
    ) {
        self.semanticState = semanticState
        self.color = color
        self.animation = animation
        self.textualState = textualState
        self.brightness = brightness
        self.appliesToAllKeys = appliesToAllKeys
    }

    public func intensity(atMilliseconds milliseconds: UInt64) -> Double {
        let phase: Double
        switch animation {
        case .off:
            phase = 0
        case .steady:
            phase = 1
        case .blink:
            phase = milliseconds % 500 < 250 ? 1 : 0
        case .pulse:
            let cycle = Double(milliseconds % 1_000) / 1_000
            phase = 0.25 + (0.75 * (1 - cos(2 * .pi * cycle)) / 2)
        }
        return brightness.value * phase
    }
}

public enum LightingProjector {
    public static func project(
        _ state: SessionRuntimeState,
        preferences: LightingPreferences = LightingPreferences()
    ) -> LightingProjection {
        if state.isPaused {
            return projection(.paused, .off, .off, "Paused", preferences)
        }
        guard state.binding != nil, state.connection != .disconnected else {
            return projection(.disconnected, .off, .off, "Disconnected", preferences)
        }
        guard state.connection == .ready, case .known(let mode) = state.mode, state.work.isKnown,
            state.attention.isKnown
        else {
            return projection(.unknown, .off, .off, "State unknown", preferences)
        }
        if state.failure != nil {
            return projection(.error, .red, .steady, "Error", preferences)
        }
        if !state.pendingAttention.isEmpty || state.attention.requiresAttention {
            let text =
                state.pendingAttention.contains(where: { $0.kind == .permission })
                    || state.attention.permissionCount > 0
                ? "Needs permission" : "Needs input"
            return projection(
                .attention,
                .amber,
                preferences.reducedMotion ? .steady : .pulse,
                text,
                preferences
            )
        }
        let modeColor = color(for: mode)
        if state.work.hasActiveWork {
            return projection(
                .working,
                modeColor,
                preferences.reducedMotion ? .steady : .blink,
                "Working",
                preferences
            )
        }
        if state.unacknowledgedCompletion != nil {
            return projection(.completed, .green, .steady, "Completed", preferences)
        }
        return projection(.idle, modeColor, .steady, text(for: mode), preferences)
    }

    private static func projection(
        _ state: LightingSemanticState,
        _ color: LightingColor,
        _ animation: LightingAnimation,
        _ text: String,
        _ preferences: LightingPreferences
    ) -> LightingProjection {
        LightingProjection(
            semanticState: state,
            color: color,
            animation: animation,
            textualState: text,
            brightness: preferences.brightness,
            appliesToAllKeys: true
        )
    }

    private static func color(for mode: SessionMode) -> LightingColor {
        switch mode {
        case .standard:
            .white
        case .plan:
            .blue
        case .autopilot:
            .purple
        }
    }

    private static func text(for mode: SessionMode) -> String {
        switch mode {
        case .standard:
            "Default"
        case .plan:
            "Plan"
        case .autopilot:
            "Autopilot"
        }
    }
}
