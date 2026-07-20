import SwiftUI
import UIKit

/// Minimal settings sheet (gear button in the toolbar) — mirrors the sibling
/// apps' SettingsView. Everything persists via EmulatorController's
/// UserDefaults-backed @Published properties.
struct SettingsView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "computermouse")
                            .foregroundStyle(.secondary)
                        Slider(value: $emu.mouseSensitivity, in: 0.5...3.0, step: 0.1)
                        Text(String(format: "%.1f×", emu.mouseSensitivity))
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                } header: {
                    Text("Mouse Sensitivity")
                } footer: {
                    Text("How far the Amiga pointer moves per trackpad swipe.")
                }

                Section {
                    HStack(spacing: 12) {
                        Image(systemName: emu.audioVolume == 0 ? "speaker.slash" : "speaker.wave.2")
                            .foregroundStyle(.secondary)
                        Slider(value: Binding(get: { Double(emu.audioVolume) },
                                              set: { emu.audioVolume = Int($0) }),
                               in: 0...100, step: 5)
                        Text("\(emu.audioVolume)%")
                            .font(.caption.monospacedDigit())
                            .frame(width: 40, alignment: .trailing)
                    }
                } header: {
                    Text("Volume")
                } footer: {
                    Text("Paula master volume. Takes effect immediately.")
                }

                Section("Feedback") {
                    Toggle("Haptic Feedback", isOn: $emu.hapticsEnabled)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Light impact haptic for the virtual controls (d-pad, joystick, mouse
/// buttons, side-panel keys), gated by the Settings toggle (default ON).
enum Haptics {
    private static let light = UIImpactFeedbackGenerator(style: .light)

    static var isEnabled: Bool {
        (UserDefaults.standard.object(forKey: "HapticsEnabled") as? Bool) ?? true
    }

    static func tap() {
        guard isEnabled else { return }
        light.impactOccurred()
    }
}
