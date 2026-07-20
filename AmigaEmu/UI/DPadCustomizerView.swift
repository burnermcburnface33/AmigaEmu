import SwiftUI

/// Sheet for editing the active D-pad layout — mirrors the AppleIIGS/dospad
/// customizer. Buttons added here appear in the d-pad's right zone; long-press
/// + drag in the overlay to reposition them.
struct DPadCustomizerView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    @State private var showingPicker = false
    @State private var editingButton: DPadCustomButton?

    var body: some View {
        NavigationStack {
            List {
                Section("Layout name") {
                    TextField("Layout name", text: layoutNameBinding())
                        .textInputAutocapitalization(.words)
                }

                Section {
                    ForEach(emu.dpadLayout.buttons) { btn in
                        Button { editingButton = btn } label: {
                            HStack {
                                Text(btn.label)
                                    .font(.system(size: 16, weight: .semibold))
                                    .frame(width: 54, height: 34)
                                    .background(btn.isFire ? Color.orange.opacity(0.7) : Color.red.opacity(0.65))
                                    .foregroundStyle(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(btn.isFire ? "Joystick fire" : AmigaKeyItem.name(for: btn.keyCode))
                                        .font(.callout)
                                    Text(btn.latching ? "Latches (toggle)" : "Momentary")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { idx in emu.deleteDPadButtons(at: idx) }

                    Button { showingPicker = true } label: {
                        Label("Add button", systemImage: "plus.circle.fill")
                    }
                    Button { emu.resetCurrentLayoutPositions() } label: {
                        Label("Reset positions to default spacing",
                              systemImage: "arrow.up.and.down.text.horizontal")
                    }
                } header: {
                    Text("Buttons in this layout")
                } footer: {
                    Text("Long-press a button in the d-pad overlay to drag it to a new position.")
                        .font(.caption2)
                }

                Section {
                    ForEach(emu.savedDPadLayouts) { layout in
                        HStack {
                            Image(systemName: layout.id == emu.dpadLayout.id ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(layout.id == emu.dpadLayout.id ? Color.accentColor : Color.secondary)
                            Text(layout.name)
                            Spacer()
                            Text("\(layout.buttons.count) keys")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { emu.activateDPadLayout(layout) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                emu.deleteStoredLayout(layout)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    Button { emu.saveCopyOfCurrentLayout() } label: {
                        Label("Save a copy of current layout",
                              systemImage: "square.and.arrow.down.on.square")
                    }
                    Button { emu.newBlankDPadLayout() } label: {
                        Label("New blank layout", systemImage: "doc.badge.plus")
                    }
                } header: {
                    Text("Stored layouts")
                } footer: {
                    Text("Edits to the active layout save automatically. “Save a copy” snapshots the current configuration so you can experiment and load it back later. Tap a layout to load it; swipe left to delete.")
                        .font(.caption2)
                }
            }
            .navigationTitle("Customize D-Pad")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingPicker) {
                DPadKeyPickerView { key in
                    emu.appendDPadButton(label: key.symbol, keyCode: key.code)
                }
            }
            .sheet(item: $editingButton) { btn in
                DPadButtonEditorView(original: btn)
            }
        }
    }

    private func layoutNameBinding() -> Binding<String> {
        Binding(get: { emu.dpadLayout.name },
                set: { emu.renameCurrentDPadLayout($0) })
    }
}

/// Modal — pick a key/action by category. Searchable.
struct DPadKeyPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (AmigaKeyItem) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(AmigaKeyItem.Category.allCases) { cat in
                    let keys = AmigaKeyItem.all.filter {
                        $0.category == cat &&
                        (query.isEmpty || $0.symbol.localizedCaseInsensitiveContains(query))
                    }
                    if !keys.isEmpty {
                        Section(cat.rawValue) {
                            ForEach(keys) { k in
                                Button {
                                    onPick(k); dismiss()
                                } label: {
                                    HStack {
                                        Text(k.symbol)
                                            .font(.system(.body, design: .monospaced))
                                            .frame(width: 64, alignment: .leading)
                                        Text(k.code < 0 ? "joystick" : String(format: "$%02X", k.code))
                                            .font(.caption).foregroundStyle(.tertiary)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Search keys")
            .navigationTitle("Pick a key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

/// Edit an existing button — change key, rename, set latching, or delete.
struct DPadButtonEditorView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    let original: DPadCustomButton
    @State private var label = ""
    @State private var latching = false
    @State private var keyCode = 0
    @State private var showingPicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Label on button face") {
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
                        emu.deleteDPadButton(original); dismiss()
                    } label: { Label("Delete button", systemImage: "trash") }
                }
            }
            .navigationTitle("Edit button")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        emu.updateDPadButton(original.id, label: label, keyCode: keyCode, latching: latching)
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
