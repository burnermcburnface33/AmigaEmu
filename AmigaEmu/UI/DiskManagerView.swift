import SwiftUI
import UniformTypeIdentifiers

struct DiskManagerView: View {
    @EnvironmentObject private var emu: EmulatorController
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var importError: String?
    @State private var libraryDisks: [URL] = []

    /// What the bridge's floppy insert path (FloppyFile::make) actually
    /// accepts: ADF, ADZ (gzipped ADF), DMS, IMG (PC disks), EXE.
    private static let supportedExtensions: Set<String> = ["adf", "adz", "dms", "img", "exe"]

    var body: some View {
        NavigationStack {
            List {
                Section("Drive DF0") {
                    if let name = emu.mountedDiskName {
                        Label(name, systemImage: "opticaldiscdrive.fill")
                            .lineLimit(2)
                        Button("Eject", role: .destructive) { emu.ejectDisk() }
                    } else {
                        Text("Empty").foregroundStyle(.secondary)
                    }
                }
                Section("Insert") {
                    Button {
                        emu.insertBundledDisk()
                    } label: {
                        Label("Battle Chess (bundled)", systemImage: "tray.and.arrow.down")
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import disk image…", systemImage: "square.and.arrow.down")
                    }
                }
                if !libraryDisks.isEmpty {
                    Section {
                        ForEach(libraryDisks, id: \.self) { url in
                            Button {
                                emu.insertLibraryDisk(url)
                                dismiss()
                            } label: {
                                HStack {
                                    Label(url.lastPathComponent, systemImage: "opticaldisc")
                                        .lineLimit(2)
                                    Spacer()
                                    if emu.mountedDiskName == url.lastPathComponent {
                                        Text("DF0")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.green)
                                    }
                                }
                            }
                            .tint(.primary)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    emu.deleteLibraryDisk(url)
                                    refreshLibrary()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        Text("Imported disks")
                    } footer: {
                        Text(cloudFooter)
                    }
                }
                Section("Machine") {
                    Button {
                        emu.softReset()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                }
            }
            .navigationTitle("Disks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { refreshLibrary() }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    let ext = url.pathExtension.lowercased()
                    if Self.supportedExtensions.contains(ext) {
                        emu.insertDisk(at: url)
                        refreshLibrary()
                        dismiss()
                    } else {
                        importError = "“.\(ext)” is not a supported floppy image. "
                                    + "Supported formats: ADF, ADZ, DMS, IMG, EXE."
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                }
            }
            .alert("Can't Import Disk", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private var cloudFooter: String {
        switch emu.cloudBackupActive {
        case .some(true):  return "Imported disks are backed up to iCloud Drive › Amiga › Disks and sync across your devices."
        case .some(false): return "iCloud Drive is unavailable — disks are stored locally on this device only."
        case .none:        return "Stored in this app's Documents › Disks folder."
        }
    }

    private func refreshLibrary() {
        libraryDisks = emu.libraryDisks()
    }
}
