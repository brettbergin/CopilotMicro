public enum PhysicalControlID: String, Codable, CaseIterable, Hashable, Sendable {
    case sessions = "key.sessions"
    case newSession = "key.new"
    case previous = "key.previous"
    case next = "key.next"
    case archive = "key.archive"
    case mode = "key.mode"
    case model = "key.model"
    case effort = "key.effort"
    case voice = "key.voice"
    case cancel = "key.cancel"
    case submit = "key.submit"
    case focus = "key.focus"
}

public struct MatrixContactID: Codable, Hashable, Sendable {
    public enum ValidationError: Error, Equatable, Sendable {
        case outOfRange
    }

    public let rawValue: Int

    public init(rawValue: Int) throws {
        guard (0...12).contains(rawValue) else {
            throw ValidationError.outOfRange
        }
        self.rawValue = rawValue
    }

    fileprivate init(validatedRawValue: Int) {
        rawValue = validatedRawValue
    }

    public init(from decoder: Decoder) throws {
        try self.init(rawValue: decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct PhysicalControlDescriptor: Equatable, Sendable {
    public let id: PhysicalControlID
    public let visualPosition: String
    public let contacts: Set<MatrixContactID>
    public let defaultAction: ActionID
    public let oneShot: Bool

    public init(
        id: PhysicalControlID,
        visualPosition: String,
        contacts: Set<MatrixContactID>,
        defaultAction: ActionID,
        oneShot: Bool = true
    ) {
        self.id = id
        self.visualPosition = visualPosition
        self.contacts = contacts
        self.defaultAction = defaultAction
        self.oneShot = oneShot
    }
}

public enum PhysicalLayout {
    public static let creatorMicro2Pro: [PhysicalControlDescriptor] = [
        descriptor(.sessions, "top-right", [1], .openSessionList),
        descriptor(.newSession, "top-left", [0], .createSession),
        descriptor(.previous, "second-row-first", [2], .previousSession),
        descriptor(.next, "second-row-second", [3], .nextSession),
        descriptor(.archive, "second-row-third", [4], .archiveSession),
        descriptor(.mode, "second-row-fourth", [5], .cycleMode),
        descriptor(.model, "third-row-first", [6], .selectModel),
        descriptor(.effort, "third-row-second", [7], .selectEffort),
        descriptor(.voice, "third-row-third", [8], .voice),
        descriptor(.cancel, "third-row-fourth", [9], .cancelForeground),
        descriptor(.submit, "bottom-wide", [10, 11], .submitComposer),
        descriptor(.focus, "bottom-right", [12], .focusComposer),
    ]

    public static let contactToControl: [MatrixContactID: PhysicalControlID] = {
        Dictionary(
            uniqueKeysWithValues: creatorMicro2Pro.flatMap { descriptor in
                descriptor.contacts.map { ($0, descriptor.id) }
            })
    }()

    private static func descriptor(
        _ id: PhysicalControlID,
        _ visualPosition: String,
        _ contacts: [Int],
        _ action: ActionID
    ) -> PhysicalControlDescriptor {
        PhysicalControlDescriptor(
            id: id,
            visualPosition: visualPosition,
            contacts: Set(contacts.map(MatrixContactID.init(validatedRawValue:))),
            defaultAction: action
        )
    }
}

public enum ControlTransition: Equatable, Sendable {
    case pressed(PhysicalControlID)
    case released(PhysicalControlID)
}

public struct KeyInputNormalizer: Sendable {
    private let wideKeyCoalescingMilliseconds: UInt64
    private var pressedContacts: Set<MatrixContactID> = []
    private var pressedControls: Set<PhysicalControlID> = []
    private var suppressedControls: Set<PhysicalControlID> = []
    private var wideKeyCooldownUntil: UInt64?

    public init(wideKeyCoalescingMilliseconds: UInt64) {
        self.wideKeyCoalescingMilliseconds = wideKeyCoalescingMilliseconds
    }

    public mutating func process(
        contact: MatrixContactID,
        isPressed: Bool,
        atMilliseconds milliseconds: UInt64
    ) -> ControlTransition? {
        guard let control = PhysicalLayout.contactToControl[contact] else {
            return nil
        }

        if isPressed {
            guard pressedContacts.insert(contact).inserted else {
                return nil
            }
            if control == .submit,
                let cooldown = wideKeyCooldownUntil,
                milliseconds < cooldown
            {
                suppressedControls.insert(control)
            }
            guard !suppressedControls.contains(control) else {
                return nil
            }
            guard pressedControls.insert(control).inserted else {
                return nil
            }
            return .pressed(control)
        }

        guard pressedContacts.remove(contact) != nil else {
            return nil
        }
        let stillPressed =
            PhysicalLayout.creatorMicro2Pro
            .first(where: { $0.id == control })?
            .contacts
            .contains(where: pressedContacts.contains) ?? false
        guard !stillPressed else {
            return nil
        }
        if suppressedControls.remove(control) != nil {
            return nil
        }
        guard pressedControls.remove(control) != nil else {
            return nil
        }
        if control == .submit {
            let (cooldown, overflow) = milliseconds.addingReportingOverflow(
                wideKeyCoalescingMilliseconds
            )
            wideKeyCooldownUntil = overflow ? UInt64.max : cooldown
        }
        return .released(control)
    }

    public mutating func reset(suppressing currentlyPressedContacts: Set<MatrixContactID> = []) {
        let contactsToSuppress = pressedContacts.union(currentlyPressedContacts)
        suppressedControls = Set(contactsToSuppress.compactMap { PhysicalLayout.contactToControl[$0] })
        pressedContacts = currentlyPressedContacts
        pressedControls.removeAll()
        wideKeyCooldownUntil = nil
    }
}

public enum JoystickPosition: String, Codable, Sendable {
    case neutral
    case north
    case south
    case east
    case west
    case northeast
    case northwest
    case southeast
    case southwest

    fileprivate var cardinalDirection: JoystickDirection? {
        switch self {
        case .north:
            .north
        case .south:
            .south
        case .east:
            .east
        case .west:
            .west
        default:
            nil
        }
    }
}

public enum JoystickDirection: String, Codable, Sendable {
    case north
    case south
    case east
    case west
}

public struct JoystickNormalizer: Sendable {
    private var armed = true

    public init() {}

    public mutating func process(_ position: JoystickPosition) -> JoystickDirection? {
        if position == .neutral {
            armed = true
            return nil
        }
        guard armed, let direction = position.cardinalDirection else {
            return nil
        }
        armed = false
        return direction
    }

    public mutating func reset() {
        armed = false
    }
}
