import SwiftUI

struct MainView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.verticalSizeClass) private var vClass
    @State private var showDisks = false
    @State private var showResumePrompt = false

    var body: some View {
        GeometryReader { proxy in
            // Detect landscape by geometry, not verticalSizeClass — on iPad the
            // vertical size class is ALWAYS .regular (even in landscape), so the
            // landscape layouts must key off width > height to work on iPad.
            let isLandscape = proxy.size.width > proxy.size.height
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    TopToolbar(showDisks: $showDisks)
                        .frame(height: 44)
                        .background(Color(white: 0.07))

                    // The emulator screen keeps ONE structural identity across
                    // every input mode: only the flanking panels come and go.
                    // Putting EmulatorScreenView in per-mode if/else branches
                    // made SwiftUI destroy + recreate it (and its Metal
                    // renderer) on interface changes, so the auto-crop
                    // re-converged from its seed each time — a visible
                    // zoom-settle of the picture.
                    HStack(spacing: 0) {
                        if emu.inputMode == .panelKeys {
                            SidePanelKeyboard(side: .left)
                                .frame(width: panelWidth(isLandscape))
                        } else if emu.inputMode == .customPanel {
                            CustomPanelView(side: .left)
                                .frame(width: panelWidth(isLandscape))
                        } else if emu.inputMode == .mouse && isLandscape {
                            // Landscape mouse: split trackpad (left) + buttons
                            // (right) flank the full-size screen.
                            TrackpadSurface()
                                .frame(width: 200)
                        }

                        EmulatorScreenView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                            .clipped()
                            // Direct mouse: the screen itself is the trackpad,
                            // with floating semi-transparent L/R buttons. The
                            // overlay modifier is unconditional (only its
                            // content is mode-gated) so the screen view keeps
                            // its ONE structural identity — see comment above.
                            .overlay {
                                if emu.inputMode == .directMouse {
                                    DirectMouseOverlay()
                                } else if emu.inputMode == .joystick && isLandscape {
                                    // Landscape joystick floats translucent
                                    // controls over a full-size screen (same
                                    // real-estate treatment as direct mouse).
                                    JoystickOverlay().opacity(0.45)
                                }
                            }

                        if emu.inputMode == .panelKeys {
                            SidePanelKeyboard(side: .right)
                                .frame(width: panelWidth(isLandscape))
                        } else if emu.inputMode == .customPanel {
                            CustomPanelView(side: .right)
                                .frame(width: panelWidth(isLandscape))
                        } else if emu.inputMode == .mouse && isLandscape {
                            MouseButtonColumn()
                                .frame(width: 84)
                        }
                    }

                    if showsBottomInputArea(isLandscape) {
                        InputArea()
                            .frame(height: inputAreaHeight(proxy: proxy))
                            .background(Color(white: 0.04))
                    }
                }
            }
        }
        .sheet(isPresented: $showDisks) { DiskManagerView().environmentObject(emu) }
        .task {
            emu.bootstrap()
            // Cold launch: if an auto-save (quick-save) from the last session
            // exists, offer to restore it over the clean boot just started.
            if emu.canResume && !emu.bridge.restoredFromSnapshot {
                showResumePrompt = true
            }
        }
        .alert("Resume last session?", isPresented: $showResumePrompt) {
            Button("Resume") { emu.resumeSavedSession() }
            Button("Not Now", role: .cancel) { }
        } message: {
            Text("An auto-saved session from your last visit is available.")
        }
        .alert("Disk Error", isPresented: Binding(
            get: { emu.diskError != nil },
            set: { if !$0 { emu.diskError = nil } })) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(emu.diskError ?? "")
        }
    }

    /// The bottom input strip is hidden in the side-flank layouts
    /// (side keys, landscape mouse split) and in direct-mouse mode
    /// (whole-screen trackpad); every other mode shows it.
    private func showsBottomInputArea(_ isLandscape: Bool) -> Bool {
        if emu.inputMode == .panelKeys { return false }
        if emu.inputMode == .customPanel { return false }
        if emu.inputMode == .directMouse { return false }
        if emu.inputMode == .mouse && isLandscape { return false }
        if emu.inputMode == .joystick && isLandscape { return false }  // overlays the screen
        return true
    }

    private func panelWidth(_ landscape: Bool) -> CGFloat {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        // iPhone values are unchanged (landscape == old `vClass == .compact`);
        // iPad gets wider side panels to suit the larger screen.
        return isPad ? (landscape ? 200 : 150) : (landscape ? 128 : 96)
    }

    private func inputAreaHeight(proxy: GeometryProxy) -> CGFloat {
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        switch emu.inputMode {
        case .keyboard:        return 1     // accessory bar floats independently
        case .joystick, .dpad: return min(proxy.size.height * (isPad ? 0.30 : 0.42), 320)
        case .mouse:           return min(proxy.size.height * (isPad ? 0.28 : 0.40), 300)
        case .directMouse:     return 0     // screen-as-trackpad, no strip
        case .panelKeys:       return 0
        case .customPanel:     return 0     // panels live beside the screen
        }
    }
}

struct TopToolbar: View {
    @EnvironmentObject private var emu: EmulatorController
    @Binding var showDisks: Bool
    @State private var showSaveStates = false
    @State private var showSettings = false

    var body: some View {
        HStack(spacing: 8) {
            DiskActivityLED(activity: emu.diskActivity)

            Spacer(minLength: 4)

            Picker("Mode", selection: $emu.inputMode) {
                ForEach(InputMode.allCases) { mode in
                    Image(systemName: mode.icon).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)   // 7 icon-only segments (kept tight so the toolbar buttons stay on-screen)

            Spacer(minLength: 4)

            Menu {
                if emu.canResume {
                    Button {
                        emu.resumeSavedSession()
                    } label: { Label("Resume Saved Session", systemImage: "arrow.uturn.backward") }
                }
                Button {
                    emu.hardReset()
                } label: { Label("Reboot", systemImage: "arrow.clockwise") }
                Button(role: .destructive) {
                    emu.cleanBoot()
                } label: { Label("Clean Boot", systemImage: "power") }
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 15, weight: .semibold))
            }

            Button { showSaveStates = true } label: {
                Image(systemName: "tray.full")
                    .font(.system(size: 15, weight: .semibold))
            }

            Button { showDisks.toggle() } label: {
                Image(systemName: "opticaldiscdrive")
                    .font(.system(size: 15, weight: .semibold))
            }

            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .semibold))
            }
        }
        .padding(.horizontal, 8)
        .foregroundStyle(.white)
        .sheet(isPresented: $showSaveStates) {
            SaveStatesView().environmentObject(emu)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(emu)
        }
    }
}

/// Toolbar floppy LED: green pulse while a drive reads, amber while it writes,
/// dim gray when idle. Fixed width so the toolbar doesn't reflow on each access.
struct DiskActivityLED: View {
    let activity: DiskActivity?

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(ledColor)
                .frame(width: 9, height: 9)
                .shadow(color: ledColor.opacity(activity != nil ? 0.9 : 0), radius: 3)
                .animation(.easeOut(duration: 0.12), value: activity)
            Text(activity?.label ?? "—")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(activity == nil ? 0.30 : 0.85))
                .lineLimit(1)
        }
        .frame(width: 52, alignment: .leading)
    }

    private var ledColor: Color {
        guard let a = activity else { return .white.opacity(0.16) }
        return a.writing ? Color(red: 1.0, green: 0.55, blue: 0.20)   // amber = write
                         : Color(red: 0.40, green: 1.0, blue: 0.40)   // green = read
    }
}

struct InputArea: View {
    @EnvironmentObject private var emu: EmulatorController

    var body: some View {
        Group {
            switch emu.inputMode {
            case .keyboard:    KeyboardInputArea()
            case .joystick:    JoystickOverlay()
            case .mouse:       MouseOverlay()
            case .directMouse: Color.clear   // screen overlay, no bottom area
            case .dpad:        DPadOverlay()
            case .panelKeys:   Color.clear   // panels live beside the screen
            case .customPanel: Color.clear   // custom panels live beside the screen
            }
        }
    }
}
