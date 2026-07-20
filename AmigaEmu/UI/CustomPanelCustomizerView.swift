import SwiftUI

/// Sheet for editing the active custom landscape panel — mirrors
/// `DPadCustomizerView`, retargeted to the panel state. Keys added here are
/// split in order across the two flanks; drag to reorder which side a key lands
/// on. Reuses the D-pad key catalog + picker (`DPadKeyPickerView`).
struct CustomPanelCustomizerView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    @State private var showingPicker = false
    @State private var editingKey: PanelKeyItem?

    var body: some View {
        NavigationStack {
            List {
                Section("Panel name") {
                    TextField("Panel name", text: panelNameBinding())
                        .textInputAutocapitalization(.words)
                }

                Section("Directional pad") {
                    Toggle("Show arrow pad", isOn: showDPadBinding())
                }

                Section {
                    ForEach(emu.panelLayout.keys) { key in
                        Button { editingKey = key } label: {
                            HStack {
                                Text(key.label)
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 54, height: 34)
                                    .background(key.isFire ? Color.orange.opacity(0.7) : Color.red.opacity(0.65))
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(key.isFire ? "Joystick fire" : AmigaKeyItem.name(for: key.keyCode))
                                        .font(.callout)
                                    Text(key.latching ? "Latches (toggle)" : "Momentary")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { emu.deletePanelKeys(at: $0) }
                    .onMove { emu.movePanelKey(from: $0, to: $1) }

                    Button { showingPicker = true } label: {
                        Label("Add key", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text("Keys in this panel")
                } footer: {
                    Text("Keys fill the flanks in order — the first half go to the left panel (below the arrow pad), the rest to the right. Drag to reorder which side a key lands on.")
                        .font(.caption2)
                }

                Section {
                    ForEach(emu.savedPanelLayouts) { layout in
                        HStack {
                            Image(systemName: layout.id == emu.panelLayout.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(layout.id == emu.panelLayout.id ? Color.accentColor : Color.secondary)
                            Text(layout.name)
                            Spacer()
                            Text("\(layout.keys.count) keys")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { emu.activatePanelLayout(layout) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                emu.deleteStoredPanelLayout(layout)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    Button { emu.saveCopyOfCurrentPanelLayout() } label: {
                        Label("Save a copy of current panel",
                              systemImage: "square.and.arrow.down.on.square")
                    }
                    Button { emu.newBlankPanelLayout() } label: {
                        Label("New blank panel", systemImage: "doc.badge.plus")
                    }
                } header: {
                    Text("Stored panels")
                } footer: {
                    Text("Edits to the active panel save automatically. “Save a copy” snapshots the current configuration so you can experiment and load it back later. Tap a panel to load it; swipe left to delete.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Customize Panel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) { EditButton() }
            }
            .sheet(isPresented: $showingPicker) {
                DPadKeyPickerView { key in
                    emu.appendPanelKey(label: key.symbol, keyCode: key.code)
                }
            }
            .sheet(item: $editingKey) { key in
                PanelKeyEditorView(original: key)
            }
        }
    }

    private func panelNameBinding() -> Binding<String> {
        Binding(get: { emu.panelLayout.name },
                set: { emu.renamePanelLayout($0) })
    }
    private func showDPadBinding() -> Binding<Bool> {
        Binding(get: { emu.panelLayout.showDPad },
                set: { emu.setPanelShowDPad($0) })
    }
}

/// Edit an existing panel key — change key, rename, set latching, or delete.
/// Mirrors `DPadButtonEditorView`.
struct PanelKeyEditorView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    let original: PanelKeyItem
    @State private var label = ""
    @State private var latching = false
    @State private var keyCode = 0
    @State private var showingPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Label on key face") {
                    TextField("Label", text: $label)
                        .font(.system(.body, design: .monospaced))
                }
                Section("Key sent when pressed") {
                    Button { showingPicker = true } label: {
                        HStack {
                            Text(keyCode == DPadCustomButton.fireCode ? "Joystick fire"
                                 : AmigaKeyItem.name(for: keyCode))
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                Section {
                    Toggle("Latching (tap to toggle on/off)", isOn: $latching)
                } footer: {
                    Text("Latching is useful for modifier keys (shift, ctrl, ◆) held while another key is pressed. Off = momentary press.")
                        .font(.caption2)
                }
                Section {
                    Button(role: .destructive) {
                        emu.deletePanelKey(original); dismiss()
                    } label: { Label("Delete key", systemImage: "trash") }
                }
            }
            .navigationTitle("Edit key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        emu.updatePanelKey(original.id, label: label, keyCode: keyCode, latching: latching)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingPicker) {
                DPadKeyPickerView { key in
                    keyCode = key.code
                    if label.isEmpty { label = key.symbol }
                }
            }
        }
        .onAppear {
            label = original.label
            latching = original.latching
            keyCode = original.keyCode
        }
    }
}
