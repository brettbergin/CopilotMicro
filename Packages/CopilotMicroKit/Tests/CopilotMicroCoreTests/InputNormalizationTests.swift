import CopilotMicroCore
import Testing

@Suite("Creator Micro 2 Pro input normalization")
struct InputNormalizationTests {
    @Test("The documented layout has twelve controls and thirteen unique contacts")
    func physicalLayoutIsComplete() throws {
        let layout = PhysicalLayout.creatorMicro2Pro
        #expect(layout.count == 12)
        #expect(Set(layout.map(\.id)).count == 12)
        #expect(Set(layout.flatMap(\.contacts)).count == 13)
        #expect(PhysicalLayout.contactToControl.count == 13)
        #expect(PhysicalLayout.contactToControl[try contact(1)] == .sessions)
        #expect(PhysicalLayout.contactToControl[try contact(0)] == .newSession)
        #expect(layout.first(where: { $0.id == .newSession })?.visualPosition == "top-left")
        #expect(layout.first(where: { $0.id == .sessions })?.visualPosition == "top-right")
    }

    @Test("The two wide-key contacts produce one press and one release")
    func wideKeyIsCoalesced() throws {
        var normalizer = makeKeyNormalizer()

        #expect(
            normalizer.process(contact: try contact(10), isPressed: true, atMilliseconds: 0) == .pressed(.submit)
        )
        #expect(normalizer.process(contact: try contact(11), isPressed: true, atMilliseconds: 1) == nil)
        #expect(normalizer.process(contact: try contact(10), isPressed: false, atMilliseconds: 2) == nil)
        #expect(
            normalizer.process(contact: try contact(11), isPressed: false, atMilliseconds: 3) == .released(.submit)
        )
    }

    @Test("Duplicate edges do not repeat one-shot controls")
    func duplicateEdgesAreIgnored() throws {
        var normalizer = makeKeyNormalizer()

        #expect(
            normalizer.process(contact: try contact(9), isPressed: true, atMilliseconds: 0) == .pressed(.cancel)
        )
        #expect(normalizer.process(contact: try contact(9), isPressed: true, atMilliseconds: 1) == nil)
        #expect(
            normalizer.process(contact: try contact(9), isPressed: false, atMilliseconds: 2) == .released(.cancel)
        )
        #expect(normalizer.process(contact: try contact(9), isPressed: false, atMilliseconds: 3) == nil)
    }

    @Test("Reset suppresses a held one-shot key until release")
    func resetDoesNotReplayHeldInput() throws {
        var normalizer = makeKeyNormalizer()
        let cancel = try contact(9)

        #expect(normalizer.process(contact: cancel, isPressed: true, atMilliseconds: 0) == .pressed(.cancel))
        normalizer.reset()
        #expect(normalizer.process(contact: cancel, isPressed: true, atMilliseconds: 1) == nil)
        #expect(normalizer.process(contact: cancel, isPressed: false, atMilliseconds: 2) == nil)
        #expect(normalizer.process(contact: cancel, isPressed: true, atMilliseconds: 3) == .pressed(.cancel))
    }

    @Test("Staggered wide-key contacts within the debounce window cannot submit twice")
    func staggeredWideContactsAreCoalesced() throws {
        var normalizer = makeKeyNormalizer()
        let left = try contact(10)
        let right = try contact(11)

        #expect(normalizer.process(contact: left, isPressed: true, atMilliseconds: 0) == .pressed(.submit))
        #expect(normalizer.process(contact: left, isPressed: false, atMilliseconds: 10) == .released(.submit))
        #expect(normalizer.process(contact: right, isPressed: true, atMilliseconds: 20) == nil)
        #expect(normalizer.process(contact: right, isPressed: false, atMilliseconds: 30) == nil)
        #expect(normalizer.process(contact: right, isPressed: true, atMilliseconds: 60) == .pressed(.submit))
    }

    @Test("A reconnect snapshot can suppress contacts already held by the device")
    func synchronizationSuppressesReportedHeldContacts() throws {
        var normalizer = makeKeyNormalizer()
        let submit = try contact(10)
        normalizer.reset(suppressing: [submit])

        #expect(normalizer.process(contact: submit, isPressed: true, atMilliseconds: 0) == nil)
        #expect(normalizer.process(contact: submit, isPressed: false, atMilliseconds: 1) == nil)
        #expect(normalizer.process(contact: submit, isPressed: true, atMilliseconds: 100) == .pressed(.submit))
    }

    @Test("Joystick confirmation requires a neutral transition")
    func joystickRequiresNeutral() {
        var normalizer = JoystickNormalizer()

        #expect(normalizer.process(.east) == .east)
        #expect(normalizer.process(.east) == nil)
        #expect(normalizer.process(.northeast) == nil)
        #expect(normalizer.process(.west) == nil)
        #expect(normalizer.process(.neutral) == nil)
        #expect(normalizer.process(.west) == .west)
    }

    @Test("Reset input cannot synthesize a confirmation")
    func resetRequiresNeutral() {
        var normalizer = JoystickNormalizer()
        normalizer.reset()

        #expect(normalizer.process(.east) == nil)
        #expect(normalizer.process(.neutral) == nil)
        #expect(normalizer.process(.east) == .east)
    }

    private func contact(_ value: Int) throws -> MatrixContactID {
        try MatrixContactID(rawValue: value)
    }

    private func makeKeyNormalizer() -> KeyInputNormalizer {
        KeyInputNormalizer(wideKeyCoalescingMilliseconds: 50)
    }
}
