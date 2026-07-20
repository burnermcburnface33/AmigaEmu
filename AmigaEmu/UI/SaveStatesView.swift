import SwiftUI

/// Browsable list of named save states with screenshot thumbnails, a
/// "Save current" field, swipe-to-delete, and a Load button — mirrors the
/// AppleIIGS / dospad save-state UI.
struct SaveStatesView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("Save name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        emu.saveCurrentState(named: newName)
                        newName = ""
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()

                if emu.saveStates.isEmpty {
                    Spacer()
                    ContentUnavailableView("No Save States",
                                           systemImage: "tray",
                                           description: Text("Tap Save to snapshot the current machine."))
                    Spacer()
                } else {
                    List {
                        ForEach(emu.saveStates) { state in
                            SaveStateRow(state: state)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        emu.deleteSaveState(state)
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                        }
                        .onDelete { idx in
                            for i in idx { emu.deleteSaveState(emu.saveStates[i]) }
                        }
                    }
                }
            }
            .navigationTitle("Save States")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SaveStateRow: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    let state: EmulatorController.SaveState

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb = state.thumbnailURL,
                   let data = try? Data(contentsOf: thumb),
                   let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "tray").font(.system(size: 28)).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 84, height: 56)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 3) {
                Text(state.name).font(.headline).lineLimit(1)
                Text(state.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(spacing: 6) {
                Button("Load") {
                    emu.loadSaveState(state)
                    dismiss()
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) {
                    emu.deleteSaveState(state)
                } label: { Image(systemName: "trash").font(.system(size: 13)) }
                .buttonStyle(.bordered)
                .tint(.red)
            }
        }
        .padding(.vertical, 2)
    }
}
