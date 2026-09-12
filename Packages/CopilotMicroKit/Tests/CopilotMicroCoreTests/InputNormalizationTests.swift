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
    }

    @Test("The two wide-key contacts produce one press and one release")
    func wideKeyIsCoalesced() throws {
        var normalizer = KeyInputNormalizer()

        #expect(normalizer.process(contact: try contact(10), isPressed: true) == .pressed(.submit))
        #expect(normalizer.process(contact: try contact(11), isPressed: true) == nil)
        #expect(normalizer.process(contact: try contact(10), isPressed: false) == nil)
        #expect(normalizer.process(contact: try contact(11), isPressed: false) == .released(.submit))
    }

    @Test("Duplicate edges do not repeat one-shot controls")
    func duplicateEdgesAreIgnored() throws {
        var normalizer = KeyInputNormalizer()

        #expect(normalizer.process(contact: try contact(9), isPressed: true) == .pressed(.cancel))
        #expect(normalizer.process(contact: try contact(9), isPressed: true) == nil)
        #expect(normalizer.process(contact: try contact(9), isPressed: false) == .released(.cancel))
        #expect(normalizer.process(contact: try contact(9), isPressed: false) == nil)
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
}
