import CopilotMicroCore
import SwiftUI

@MainActor
struct PadView: View {
    @ObservedObject var store: LiveDeviceStore

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 32) {
                dial
                joystick
            }
            .padding(.bottom, 4)

            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    key(.newSession)
                        .gridCellColumns(2)
                    key(.sessions)
                        .gridCellColumns(2)
                }
                GridRow {
                    key(.previous)
                    key(.next)
                    key(.archive)
                    key(.mode)
                }
                GridRow {
                    key(.model)
                    key(.effort)
                    key(.voice)
                    key(.cancel)
                }
                GridRow {
                    key(.submit)
                        .gridCellColumns(3)
                    key(.focus)
                }
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live Creator Micro 2 input display")
    }

    private func key(_ control: PhysicalControlID) -> some View {
        let pressed = store.pressedControls.contains(control)
        return VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 5)
                .fill(keyColor.opacity(store.lightingApplied ? store.brightness : 0))
                .frame(height: 8)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                }
            Text(control.displayName)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text(pressed ? "Pressed" : "Released")
                .font(.caption2)
                .foregroundStyle(pressed ? Color.accentColor : Color.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: control == .submit ? 68 : 62)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    pressed
                        ? Color.accentColor.opacity(0.22)
                        : Color(nsColor: .controlBackgroundColor)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    pressed ? Color.accentColor : Color.primary.opacity(0.15),
                    lineWidth: pressed ? 2 : 1
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(control.displayName), \(pressed ? "pressed" : "released")")
    }

    private var dial: some View {
        let active = store.dialDirection != nil
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(
                        active
                            ? Color.accentColor.opacity(0.22)
                            : Color(nsColor: .controlBackgroundColor)
                    )
                Circle()
                    .stroke(active ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: 2)
                Capsule()
                    .fill(Color.primary.opacity(0.65))
                    .frame(width: 3, height: 18)
                    .offset(y: -16)
                    .rotationEffect(
                        .degrees(store.dialDirection == .counterClockwise ? -25 : active ? 25 : 0)
                    )
            }
            .frame(width: 74, height: 74)
            Text(store.dialDirection?.displayName.capitalized ?? "Dial")
                .font(.caption)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            store.dialDirection.map { "Dial \($0.displayName)" } ?? "Dial idle"
        )
    }

    private var joystick: some View {
        let active = store.activeJoystick != nil
        return VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 78, height: 78)
                joystickDirection(.north, symbol: "arrow.up")
                    .offset(y: -24)
                joystickDirection(.south, symbol: "arrow.down")
                    .offset(y: 24)
                joystickDirection(.west, symbol: "arrow.left")
                    .offset(x: -24)
                joystickDirection(.east, symbol: "arrow.right")
                    .offset(x: 24)
                Circle()
                    .fill(active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.08))
                    .frame(width: 18, height: 18)
            }
            Text(store.activeJoystick?.rawValue.capitalized ?? "Joystick")
                .font(.caption)
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            store.activeJoystick.map { "Joystick \($0.rawValue)" } ?? "Joystick neutral"
        )
    }

    private func joystickDirection(
        _ direction: JoystickDirection,
        symbol: String
    ) -> some View {
        let active = store.activeJoystick == direction
        return Image(systemName: symbol)
            .font(.caption.bold())
            .foregroundStyle(active ? Color.primary : Color.secondary)
            .frame(width: 25, height: 25)
            .background(
                Circle()
                    .fill(active ? joystickHighlightColor.opacity(0.8) : Color.clear)
            )
            .overlay {
                Circle()
                    .stroke(active ? Color.accentColor : Color.clear, lineWidth: 2)
            }
    }

    private var joystickHighlightColor: Color {
        store.lightingColor == .off ? Color.accentColor : keyColor
    }

    private var keyColor: Color {
        switch store.lightingColor {
        case .off:
            .clear
        case .white:
            .white
        case .blue:
            .blue
        case .purple:
            .purple
        case .red:
            .red
        case .amber:
            .orange
        case .green:
            .green
        }
    }
}
