import CopilotMicroCore
import SwiftUI

@MainActor
struct PadView: View {
    @ObservedObject var store: EmulatorStore
    let editingEnabled: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let milliseconds = UInt64(max(0, timeline.date.timeIntervalSinceReferenceDate * 1_000))
            let intensity = store.lighting.intensity(atMilliseconds: milliseconds)

            VStack(spacing: 14) {
                HStack(spacing: 32) {
                    DialView()
                    JoystickView()
                }
                .padding(.bottom, 4)

                Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                    GridRow {
                        key(.sessions, intensity: intensity)
                            .gridCellColumns(2)
                        key(.newSession, intensity: intensity)
                            .gridCellColumns(2)
                    }
                    GridRow {
                        key(.previous, intensity: intensity)
                        key(.next, intensity: intensity)
                        key(.archive, intensity: intensity)
                        key(.mode, intensity: intensity)
                    }
                    GridRow {
                        key(.model, intensity: intensity)
                        key(.effort, intensity: intensity)
                        key(.voice, intensity: intensity)
                        key(.cancel, intensity: intensity)
                    }
                    GridRow {
                        key(.submit, intensity: intensity)
                            .gridCellColumns(3)
                        key(.focus, intensity: intensity)
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
            .accessibilityLabel("Creator Micro 2 Pro demo pad")
        }
    }

    @ViewBuilder
    private func key(_ control: PhysicalControlID, intensity: Double) -> some View {
        let selected = editingEnabled && store.selectedControl == control
        let action = store.assignments[control] ?? .focusComposer
        if editingEnabled {
            Button {
                store.selectControl(control)
            } label: {
                KeyFace(
                    control: control,
                    action: action,
                    color: swiftUIColor(store.lighting.color),
                    intensity: intensity,
                    selected: selected
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "Select \(control.displayName) for editing. Assigned to \(action.displayName). Does not execute."
            )
        } else {
            KeyFace(
                control: control,
                action: action,
                color: swiftUIColor(store.lighting.color),
                intensity: intensity,
                selected: false
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(control.displayName), assigned to \(action.displayName)")
        }
    }

    private func swiftUIColor(_ color: LightingColor) -> Color {
        switch color {
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

    private struct KeyFace: View {
        let control: PhysicalControlID
        let action: ActionID
        let color: Color
        let intensity: Double
        let selected: Bool

        var body: some View {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(color.opacity(intensity))
                    .frame(height: 8)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.primary.opacity(0.18), lineWidth: 1)
                    }
                Text(control.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(action.displayName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: control == .submit ? 68 : 62)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.15), lineWidth: selected ? 2 : 1)
            }
        }
    }
}

private struct DialView: View {
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(Color(nsColor: .controlBackgroundColor))
                Circle()
                    .stroke(Color.primary.opacity(0.2), lineWidth: 2)
                Capsule()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 3, height: 18)
                    .offset(y: -16)
            }
            .frame(width: 74, height: 74)
            Text("Dial")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dial illustration")
    }
}

private struct JoystickView: View {
    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .frame(width: 78, height: 78)
                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            Text("Joystick")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Joystick illustration")
    }
}
