import SwiftUI
import Combine

enum InputMode: Int, CaseIterable, Identifiable {
    case keyboard    = 0
    case joystick    = 1
    case mouse       = 2
    case directMouse = 5   // whole screen = trackpad, floating L/R buttons
    case dpad        = 3
    case panelKeys   = 4
    case customPanel = 6   // landscape customizable split panel (sibling of d-pad)
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .keyboard:    return "Keyboard"
        case .joystick:    return "Joystick"
        case .mouse:       return "Mouse"
        case .directMouse: return "Direct Mouse"
        case .dpad:        return "D-Pad"
        case .panelKeys:   return "Side Keys"
        case .customPanel: return "Custom Panel"
        }
    }
    var icon: String {
        switch self {
        case .keyboard:    return "keyboard"
        case .joystick:    return "gamecontroller"
        case .mouse:       return "computermouse"
        case .directMouse: return "hand.point.up.left"
        case .dpad:        return "dpad"
        case .panelKeys:   return "rectangle.split.3x1"
        case .customPanel: return "square.grid.2x2"
        }
    }
}

/// Live floppy-drive activity for the on-screen LED.
struct DiskActivity: Equatable {
    var drive: Int
    var writing: Bool
    var label: String { "DF\(drive) " + (writing ? "W" : "R") }
}

/// App-side state + thin wrapper over the Obj-C++ EmulatorBridge.
final class EmulatorController: NSObject, ObservableObject, EmulatorBridgeDelegate {
    static let shared = EmulatorController()
    let bridge = EmulatorBridge.shared()

    @Published var inputMode: InputMode = .keyboard {
        didSet { if inputMode != oldValue { releaseAllInputs() } }
    }
    @Published var booted = false
    @Published var mountedDiskName: String?
    @Published var hasSavedState = false
    /// Non-nil while a floppy drive's motor is spinning (drives the toolbar LED).
    @Published var diskActivity: DiskActivity?
    /// Which control port the joystick/d-pad/mouse drive (0 = port 1, 1 = port 2).
    @Published var controlPort: Int = 1
    /// True while the emulator is paused (app backgrounded). Drives the
    /// MTKView's `isPaused` so the 60Hz display link doesn't burn battery
    /// rendering a frozen frame.
    @Published var isEmulatorPaused = false
    /// Non-nil when a disk import/insert failed — MainView shows it as an alert.
    @Published var diskError: String?
    /// Whether the disk library is mirrored to iCloud Drive (nil = still probing).
    @Published var cloudBackupActive: Bool?

    // MARK: Settings (persisted in UserDefaults, exposed in SettingsView)

    /// Trackpad-to-Amiga mouse multiplier (0.5–3.0).
    @Published var mouseSensitivity: Double =
        (UserDefaults.standard.object(forKey: "MouseSensitivity") as? Double) ?? 1.6 {
        didSet { UserDefaults.standard.set(mouseSensitivity, forKey: "MouseSensitivity") }
    }
    /// Master audio volume 0–100 (Opt::AUD_VOLL/R). Applied at startup by the
    /// bridge (-start reads the same key); live changes go through setVolume.
    @Published var audioVolume: Int =
        (UserDefaults.standard.object(forKey: "AudioVolume") as? Int) ?? 100 {
        didSet {
            UserDefaults.standard.set(audioVolume, forKey: "AudioVolume")
            bridge.setVolume(audioVolume)
        }
    }
    /// Haptic feedback on the virtual controls (read by `Haptics.tap()`).
    @Published var hapticsEnabled: Bool =
        (UserDefaults.standard.object(forKey: "HapticsEnabled") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(hapticsEnabled, forKey: "HapticsEnabled") }
    }

    var metalRenderer: MetalRenderer?
    private var motorOffWork: DispatchWorkItem?
    private var writeRevertWork: DispatchWorkItem?

    private override init() {
        super.init()
        bridge.delegate = self   // receive DRIVE_MOTOR / DRIVE_WRITE / POWER messages
        loadDPadLayouts()
        loadPanelLayouts()
    }

    func bootstrap() {
        guard !booted else { return }
        bridge.start()          // restores the quick-save if one exists
        bridge.startAudio()
        booted = true
        if bridge.restoredFromSnapshot {
            // The restored state already has its disk + RAM + CPU; don't clobber it.
            mountedDiskName = "Restored session"
        } else {
            insertBundledDisk() // fresh boot → give the user something
        }
        hasSavedState = bridge.hasQuickState()
        refreshSaveStates()
        GamepadManager.shared.start()   // physical MFi/Bluetooth pads → joystick port
        HardwareKeyboardManager.shared.start()  // BT keyboards → real key-down/up

        // Disk library ⇄ iCloud Drive mirror: reconcile at launch (pushes
        // anything imported while iCloud was off, pulls disks imported on
        // another device), and surface availability for the Disk Manager.
        CloudDiskBackup.shared.checkAvailability { [weak self] ok in
            self?.cloudBackupActive = ok
        }
        CloudDiskBackup.shared.synchronize(localDirectory: Self.diskLibraryDirectory())
    }

    // MARK: Save state (instant restart)

    /// Save the complete machine (RAM + CPU + chipset + drives) to the quick-save.
    @discardableResult
    func saveState() -> Bool {
        let ok = bridge.saveQuickState()
        if ok { hasSavedState = true }
        return ok
    }

    /// Restore the quick-save into the running machine.
    @discardableResult
    func restoreState() -> Bool {
        bridge.loadQuickState()
    }

    /// App went to background: mute audio, persist state for instant restart,
    /// then park the emulation thread. Skipped entirely if the emulator was
    /// never started (no point auto-saving a machine that never powered on).
    func handleBackground() {
        guard booted else { return }
        bridge.pauseAudio(true)
        if saveState() { /* persisted */ }
        bridge.pause()
        isEmulatorPaused = true
    }

    /// App returned to foreground: resume emulation and unmute audio.
    func handleForeground() {
        bridge.resume()
        bridge.pauseAudio(false)
        isEmulatorPaused = false
    }

    // MARK: Named save states (browsable list)

    struct SaveState: Identifiable, Hashable {
        let id: UUID
        let name: String
        let date: Date
        let url: URL
        let thumbnailURL: URL?
    }

    @Published var saveStates: [SaveState] = []

    private var savesDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SaveStates", isDirectory: true)
    }

    /// Snapshot the full machine to a new named slot (with a screenshot thumb).
    func saveCurrentState(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let id = UUID()
        try? FileManager.default.createDirectory(at: savesDirectory, withIntermediateDirectories: true)
        let url = savesDirectory.appendingPathComponent("\(id.uuidString).vasnap")
        guard bridge.saveState(toPath: url.path) else { return }

        var thumbURL: URL? = nil
        if let img = bridge.framebufferThumbnail(), let png = img.pngData() {
            let t = savesDirectory.appendingPathComponent("\(id.uuidString).png")
            if (try? png.write(to: t)) != nil { thumbURL = t }
        }
        let st = SaveState(id: id, name: name.isEmpty ? Self.defaultSaveName() : name,
                           date: Date(), url: url, thumbnailURL: thumbURL)
        saveStates.insert(st, at: 0)
        persistSaveStates()
    }

    func loadSaveState(_ state: SaveState) {
        _ = bridge.loadState(fromPath: state.url.path)
        metalRenderer?.resetAutoCrop()   // restored content may have a different active area
    }

    func deleteSaveState(_ state: SaveState) {
        try? FileManager.default.removeItem(at: state.url)
        if let t = state.thumbnailURL { try? FileManager.default.removeItem(at: t) }
        saveStates.removeAll { $0.id == state.id }
        persistSaveStates()
    }

    static func defaultSaveName() -> String {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .medium
        return "State \(f.string(from: Date()))"
    }

    private func persistSaveStates() {
        let arr: [[String: Any]] = saveStates.map { s in
            ["id": s.id.uuidString, "name": s.name,
             "date": s.date.timeIntervalSince1970,
             "file": s.url.lastPathComponent,
             "thumb": s.thumbnailURL?.lastPathComponent ?? ""]
        }
        UserDefaults.standard.set(arr, forKey: "AmigaSaveStates")
    }

    /// Reload the save-state list from disk metadata (called at bootstrap).
    func refreshSaveStates() {
        guard let arr = UserDefaults.standard.array(forKey: "AmigaSaveStates") as? [[String: Any]] else { return }
        let dir = savesDirectory
        saveStates = arr.compactMap { d in
            guard let ids = d["id"] as? String, let id = UUID(uuidString: ids),
                  let name = d["name"] as? String,
                  let ts = d["date"] as? TimeInterval,
                  let file = d["file"] as? String else { return nil }
            let url = dir.appendingPathComponent(file)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let thumb = (d["thumb"] as? String).flatMap { $0.isEmpty ? nil : dir.appendingPathComponent($0) }
            return SaveState(id: id, name: name, date: Date(timeIntervalSince1970: ts), url: url, thumbnailURL: thumb)
        }
    }

    // MARK: D-pad custom layout

    @Published var dpadLayout: DPadLayout = .default
    @Published var savedDPadLayouts: [DPadLayout] = []

    private func loadDPadLayouts() {
        if let data = UserDefaults.standard.data(forKey: "AmigaDPadLayouts"),
           let layouts = try? JSONDecoder().decode([DPadLayout].self, from: data),
           !layouts.isEmpty {
            savedDPadLayouts = layouts
        } else {
            savedDPadLayouts = [.default]
        }
        let activeID = UserDefaults.standard.string(forKey: "AmigaDPadActiveID")
        dpadLayout = savedDPadLayouts.first { $0.id.uuidString == activeID } ?? savedDPadLayouts[0]
    }

    private func persistDPadLayouts() {
        if let data = try? JSONEncoder().encode(savedDPadLayouts) {
            UserDefaults.standard.set(data, forKey: "AmigaDPadLayouts")
        }
        UserDefaults.standard.set(dpadLayout.id.uuidString, forKey: "AmigaDPadActiveID")
    }

    /// Persist the active layout's edits back into the stored list.
    func upsertCurrentLayout() {
        if let i = savedDPadLayouts.firstIndex(where: { $0.id == dpadLayout.id }) {
            savedDPadLayouts[i] = dpadLayout
        } else {
            savedDPadLayouts.append(dpadLayout)
        }
        persistDPadLayouts()
    }

    func activateDPadLayout(_ layout: DPadLayout) {
        dpadLayout = layout
        persistDPadLayouts()
    }

    func newBlankDPadLayout() {
        let l = DPadLayout(name: "Layout \(savedDPadLayouts.count + 1)", buttons: [])
        savedDPadLayouts.append(l)
        dpadLayout = l
        persistDPadLayouts()
    }

    /// Explicit "save": snapshot the ACTIVE layout as an independent stored
    /// copy (fresh ids) without switching away from it — so the user can
    /// keep experimenting and load the snapshot back later.
    @discardableResult
    func saveCopyOfCurrentLayout() -> DPadLayout {
        let copy = DPadLayout(
            name: Self.uniqueLayoutName(dpadLayout.name, existing: savedDPadLayouts.map(\.name)),
            buttons: dpadLayout.buttons.map {
                DPadCustomButton(label: $0.label, keyCode: $0.keyCode,
                                 positionX: $0.positionX, positionY: $0.positionY,
                                 latching: $0.latching,
                                 landscapeX: $0.landscapeX, landscapeY: $0.landscapeY)
            })
        savedDPadLayouts.append(copy)
        persistDPadLayouts()
        return copy
    }

    /// Delete a stored layout. If it was the active one, fall back to the
    /// first remaining layout (or a fresh Default when none are left).
    func deleteStoredLayout(_ layout: DPadLayout) {
        savedDPadLayouts.removeAll { $0.id == layout.id }
        if savedDPadLayouts.isEmpty { savedDPadLayouts = [.default] }
        if dpadLayout.id == layout.id { dpadLayout = savedDPadLayouts[0] }
        persistDPadLayouts()
    }

    /// "Name copy", "Name copy 2", … — first variant not already stored.
    private static func uniqueLayoutName(_ base: String, existing: [String]) -> String {
        let stem = base.trimmingCharacters(in: .whitespaces).isEmpty ? "Layout" : base
        var candidate = "\(stem) copy"
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(stem) copy \(counter)"
            counter += 1
        }
        return candidate
    }

    func renameCurrentDPadLayout(_ name: String) {
        dpadLayout.name = name
        upsertCurrentLayout()
    }

    func appendDPadButton(label: String, keyCode: Int) {
        let n = dpadLayout.buttons.count
        let latch = [Int(AmigaKey.lshift), Int(AmigaKey.ctrl), Int(AmigaKey.lalt),
                     Int(AmigaKey.lAmiga), Int(AmigaKey.rAmiga)].contains(keyCode)
        dpadLayout.buttons.append(DPadCustomButton(
            label: label, keyCode: keyCode,
            positionX: min(0.55 + Double(n / 3) * 0.18, 0.95),
            positionY: min(0.25 + Double(n % 3) * 0.25, 0.85),
            latching: latch))
        upsertCurrentLayout()
    }

    func deleteDPadButton(_ btn: DPadCustomButton) {
        dpadLayout.buttons.removeAll { $0.id == btn.id }
        upsertCurrentLayout()
    }

    func deleteDPadButtons(at idx: IndexSet) {
        dpadLayout.buttons.remove(atOffsets: idx)
        upsertCurrentLayout()
    }

    func updateDPadButton(_ id: UUID, label: String, keyCode: Int, latching: Bool) {
        guard let i = dpadLayout.buttons.firstIndex(where: { $0.id == id }) else { return }
        dpadLayout.buttons[i].label = label
        dpadLayout.buttons[i].keyCode = keyCode
        dpadLayout.buttons[i].latching = latching
        upsertCurrentLayout()
    }

    /// Called by the overlay when a button drag ends — commits the new position.
    func moveDPadButton(_ id: UUID, toX x: Double, y: Double, landscape: Bool) {
        guard let i = dpadLayout.buttons.firstIndex(where: { $0.id == id }) else { return }
        let cx = min(max(x, 0), 1), cy = min(max(y, 0), 1)
        if landscape {
            dpadLayout.buttons[i].landscapeX = cx
            dpadLayout.buttons[i].landscapeY = cy
        } else {
            dpadLayout.buttons[i].positionX = cx
            dpadLayout.buttons[i].positionY = cy
        }
        upsertCurrentLayout()
    }

    func resetCurrentLayoutPositions() {
        for i in dpadLayout.buttons.indices {
            dpadLayout.buttons[i].landscapeX = nil
            dpadLayout.buttons[i].landscapeY = nil
            dpadLayout.buttons[i].positionX = 0.55 + Double(i / 3) * 0.18
            dpadLayout.buttons[i].positionY = 0.25 + Double(i % 3) * 0.25
        }
        upsertCurrentLayout()
    }

    // MARK: Custom landscape panel layout

    @Published var panelLayout: PanelLayout = .starter
    @Published var savedPanelLayouts: [PanelLayout] = []

    private func loadPanelLayouts() {
        if let data = UserDefaults.standard.data(forKey: "AmigaCustomPanelLayouts"),
           let layouts = try? JSONDecoder().decode([PanelLayout].self, from: data),
           !layouts.isEmpty {
            savedPanelLayouts = layouts
        } else {
            savedPanelLayouts = [.starter]
        }
        let activeID = UserDefaults.standard.string(forKey: "AmigaCustomPanelActiveID")
        panelLayout = savedPanelLayouts.first { $0.id.uuidString == activeID } ?? savedPanelLayouts[0]
    }

    private func persistPanelLayouts() {
        if let data = try? JSONEncoder().encode(savedPanelLayouts) {
            UserDefaults.standard.set(data, forKey: "AmigaCustomPanelLayouts")
        }
        UserDefaults.standard.set(panelLayout.id.uuidString, forKey: "AmigaCustomPanelActiveID")
    }

    /// Persist the active panel's edits back into the stored list.
    func upsertCurrentPanelLayout() {
        if let i = savedPanelLayouts.firstIndex(where: { $0.id == panelLayout.id }) {
            savedPanelLayouts[i] = panelLayout
        } else {
            savedPanelLayouts.append(panelLayout)
        }
        persistPanelLayouts()
    }

    func activatePanelLayout(_ layout: PanelLayout) {
        panelLayout = layout
        persistPanelLayouts()
    }

    func newBlankPanelLayout() {
        let l = PanelLayout(name: "Panel \(savedPanelLayouts.count + 1)", keys: [])
        savedPanelLayouts.append(l)
        panelLayout = l
        persistPanelLayouts()
    }

    /// Explicit "save": snapshot the ACTIVE panel as an independent stored copy
    /// (fresh ids) without switching away from it.
    @discardableResult
    func saveCopyOfCurrentPanelLayout() -> PanelLayout {
        let copy = PanelLayout(
            name: Self.uniquePanelName(panelLayout.name, existing: savedPanelLayouts.map(\.name)),
            showDPad: panelLayout.showDPad,
            keys: panelLayout.keys.map {
                PanelKeyItem(label: $0.label, keyCode: $0.keyCode, latching: $0.latching)
            })
        savedPanelLayouts.append(copy)
        persistPanelLayouts()
        return copy
    }

    /// Delete a stored panel. If it was the active one, fall back to the first
    /// remaining panel (or a fresh starter when none are left).
    func deleteStoredPanelLayout(_ layout: PanelLayout) {
        savedPanelLayouts.removeAll { $0.id == layout.id }
        if savedPanelLayouts.isEmpty { savedPanelLayouts = [.starter] }
        if panelLayout.id == layout.id { panelLayout = savedPanelLayouts[0] }
        persistPanelLayouts()
    }

    /// "Name copy", "Name copy 2", … — first variant not already stored.
    private static func uniquePanelName(_ base: String, existing: [String]) -> String {
        let stem = base.trimmingCharacters(in: .whitespaces).isEmpty ? "Panel" : base
        var candidate = "\(stem) copy"
        var counter = 2
        while existing.contains(candidate) {
            candidate = "\(stem) copy \(counter)"
            counter += 1
        }
        return candidate
    }

    func renamePanelLayout(_ name: String) {
        panelLayout.name = name
        upsertCurrentPanelLayout()
    }

    func setPanelShowDPad(_ on: Bool) {
        panelLayout.showDPad = on
        upsertCurrentPanelLayout()
    }

    func appendPanelKey(label: String, keyCode: Int) {
        let latch = [Int(AmigaKey.lshift), Int(AmigaKey.ctrl), Int(AmigaKey.lalt),
                     Int(AmigaKey.lAmiga), Int(AmigaKey.rAmiga)].contains(keyCode)
        panelLayout.keys.append(PanelKeyItem(label: label, keyCode: keyCode, latching: latch))
        upsertCurrentPanelLayout()
    }

    func deletePanelKey(_ item: PanelKeyItem) {
        panelLayout.keys.removeAll { $0.id == item.id }
        upsertCurrentPanelLayout()
    }

    func deletePanelKeys(at idx: IndexSet) {
        panelLayout.keys.remove(atOffsets: idx)
        upsertCurrentPanelLayout()
    }

    func updatePanelKey(_ id: UUID, label: String, keyCode: Int, latching: Bool) {
        guard let i = panelLayout.keys.firstIndex(where: { $0.id == id }) else { return }
        panelLayout.keys[i].label = label
        panelLayout.keys[i].keyCode = keyCode
        panelLayout.keys[i].latching = latching
        upsertCurrentPanelLayout()
    }

    func movePanelKey(from: IndexSet, to: Int) {
        panelLayout.keys.move(fromOffsets: from, toOffset: to)
        upsertCurrentPanelLayout()
    }

    // MARK: Disk

    func insertBundledDisk() {
        guard let url = Self.bundledDiskURL() else { return }
        if bridge.insertDisk(atPath: url.path, drive: 0) {
            mountedDiskName = url.lastPathComponent
        }
    }

    func insertDisk(at url: URL, drive: Int = 0) {
        // Copy the picked file into our local library FIRST, while we still
        // hold security-scoped access. The bridge insert is ENQUEUED onto the
        // emulator thread and runs LATER (`insertDiskAtPath` returns before the
        // actual `swapDisk`), by which point this function has already returned
        // and `stopAccessingSecurityScopedResource()` has fired — so a Files-app
        // picker URL (often a security-scoped / un-materialised temp) is no
        // longer readable and `FloppyFile::make(path)` throws, silently leaving
        // DF0 empty (the Amiga then shows Kickstart's "insert disk" screen even
        // though the UI says a disk is mounted). Inserting from a stable local
        // copy we own fixes it — and persists the disk for re-insertion. The
        // bundled disk worked only because its bundle path is always readable.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let dest = Self.diskLibraryDirectory().appendingPathComponent(url.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: url, to: dest)
        } catch {
            NSLog("[Amiga] import copy failed: %@", error.localizedDescription)
            diskError = "Couldn't import the disk image: \(error.localizedDescription)"
            return
        }

        if bridge.insertDisk(atPath: dest.path, drive: Int32(drive)) {
            if drive == 0 { mountedDiskName = dest.lastPathComponent }
        }
        CloudDiskBackup.shared.backup(fileAt: dest)   // mirror to iCloud Drive
    }

    /// Insert a disk that is already in the local library (no copy needed).
    func insertLibraryDisk(_ url: URL, drive: Int = 0) {
        if bridge.insertDisk(atPath: url.path, drive: Int32(drive)) {
            if drive == 0 { mountedDiskName = url.lastPathComponent }
        }
    }

    /// All images currently in the local library, newest first.
    func libraryDisks() -> [URL] {
        let dir = Self.diskLibraryDirectory()
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles])) ?? []
        return files
            .filter { ["adf", "adz", "dms", "img", "exe"].contains($0.pathExtension.lowercased()) }
            .sorted { (a, b) in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return da > db
            }
    }

    /// Delete a library disk — local file AND its iCloud mirror (otherwise the
    /// next launch-sync would pull it right back).
    func deleteLibraryDisk(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
        CloudDiskBackup.shared.deleteBackup(named: url.lastPathComponent)
    }

    /// Local disk library (`Documents/Disks`). Imported ADFs are copied here so
    /// they persist and stay readable from the emulator thread when the queued
    /// insert actually runs.
    static func diskLibraryDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Disks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func ejectDisk(drive: Int = 0) {
        bridge.ejectDisk(Int32(drive))
        if drive == 0 { mountedDiskName = nil }
    }

    static func bundledDiskURL() -> URL? {
        if let url = Bundle.main.url(forResource: "Battle_Chess_1988_Interplay_cr_QTX_a2",
                                     withExtension: "adf", subdirectory: "Disks") {
            return url
        }
        if let res = Bundle.main.resourceURL {
            let disks = res.appendingPathComponent("Disks")
            if let items = try? FileManager.default.contentsOfDirectory(
                at: disks, includingPropertiesForKeys: nil),
               let adf = items.first(where: { ["adf", "adz", "dms"].contains($0.pathExtension.lowercased()) }) {
                return adf
            }
        }
        return nil
    }

    // MARK: Input hygiene

    /// Sweep-release every held input. Called on input-mode changes: an overlay
    /// torn down mid-press never gets its gesture's `onEnded` (SwiftUI drag
    /// gestures have no cancel callback on removal) and latched modifiers die
    /// with their view — either would leave a key/direction/button stuck down
    /// in the core forever.
    func releaseAllInputs() {
        bridge.keyReleaseAll()
        for port: Int32 in 0...1 {
            bridge.joyPort(port, direction: 0, pressed: false)   // release Y axis
            bridge.joyPort(port, direction: 2, pressed: false)   // release X axis
            bridge.joyPort(port, fire: false)
            for button: Int32 in 1...3 {
                bridge.mousePort(port, button: button, pressed: false)
            }
        }
    }

    // MARK: Machine control

    func hardReset() { bridge.hardReset(); metalRenderer?.resetAutoCrop() }
    func softReset() { bridge.softReset(); metalRenderer?.resetAutoCrop() }

    /// Clean boot: forget the auto-restore quick-save, put the bundled disk
    /// back, and power-cycle the machine.
    func cleanBoot() {
        bridge.deleteQuickState()
        insertBundledDisk()
        bridge.hardReset()
        metalRenderer?.resetAutoCrop()
    }

    /// Resume the auto-saved session (the instant-restart snapshot), if any.
    @discardableResult
    func resumeSavedSession() -> Bool {
        let ok = bridge.loadQuickState()
        metalRenderer?.resetAutoCrop()   // restored content may have a different active area
        return ok
    }

    var canResume: Bool { bridge.hasQuickState() }

    // MARK: EmulatorBridgeDelegate (all calls arrive on the main thread)

    /// Drive motor on/off → the activity LED. A brief fade on motor-off keeps
    /// short accesses visible instead of flickering.
    func emulatorDriveLED(_ on: Bool, drive nr: Int) {
        motorOffWork?.cancel()
        if on {
            diskActivity = DiskActivity(drive: nr, writing: diskActivity?.writing ?? false)
        } else if diskActivity?.drive == nr {
            let work = DispatchWorkItem { [weak self] in
                if self?.diskActivity?.drive == nr { self?.diskActivity = nil }
            }
            motorOffWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// A write happened → flag the LED red briefly, then revert to read.
    func emulatorDriveDidWrite(_ nr: Int) {
        diskActivity = DiskActivity(drive: nr, writing: true)
        writeRevertWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            if var a = self?.diskActivity, a.drive == nr, a.writing {
                a.writing = false
                self?.diskActivity = a
            }
        }
        writeRevertWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func emulatorPowerDidChange(_ on: Bool) { /* reserved for a power indicator */ }

    /// A queued insert failed on the emu thread (after insertDisk already
    /// returned) — undo the optimistic mount label and surface an alert.
    func emulatorDiskInsertFailed(_ reason: String) {
        mountedDiskName = nil
        diskError = "Couldn't insert the disk image: \(reason)"
    }
}
