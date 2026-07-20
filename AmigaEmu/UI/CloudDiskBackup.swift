import Foundation

/// Mirrors the local disk library (`Documents/Disks`) into the app's iCloud
/// Drive folder (`iCloud Drive > Amiga > Disks`), so imported disks are backed
/// up to the *app's own cloud documents* — not just the device backup — and
/// come back on a fresh install / second device.
///
/// Model: the LOCAL folder stays the emulator's source of truth (fast, works
/// offline; the bridge always inserts from the local path). The cloud folder
/// is a mirror:
///   • every import is pushed up immediately (`backup(fileAt:)`)
///   • at launch, `synchronize` pushes local files that are missing/newer in
///     the cloud and pulls cloud files that are missing locally
///   • deleting a library disk deletes both copies (otherwise the next
///     launch's pull would resurrect it)
///
/// When iCloud is unavailable (signed out, iCloud Drive off for the app, or an
/// unsigned simulator build where the entitlement doesn't apply) every call is
/// a silent no-op — the emulator keeps working from the local library.
final class CloudDiskBackup {
    static let shared = CloudDiskBackup()

    private let fm = FileManager.default
    /// All container access happens here — `url(forUbiquityContainerIdentifier:)`
    /// can do I/O and must stay off the main thread.
    private let queue = DispatchQueue(label: "com.boris.amiga.cloud-disk-backup", qos: .utility)

    private init() {}

    // MARK: Container

    /// `<container>/Documents/Disks` (created on demand), or nil without iCloud.
    private func cloudDisksDirectory() -> URL? {
        guard let container = fm.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let dir = container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Disks", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Async availability check for UI (Disk Manager footer).
    func checkAvailability(_ completion: @escaping (Bool) -> Void) {
        queue.async {
            let available = self.cloudDisksDirectory() != nil
            DispatchQueue.main.async { completion(available) }
        }
    }

    // MARK: Operations

    /// Push one just-imported disk up to the cloud mirror (fire-and-forget).
    func backup(fileAt localURL: URL) {
        queue.async {
            guard let cloudDir = self.cloudDisksDirectory() else { return }
            self.copyReplacing(localURL,
                               to: cloudDir.appendingPathComponent(localURL.lastPathComponent))
        }
    }

    /// Remove a disk's cloud copy (call when the user deletes it locally).
    func deleteBackup(named name: String) {
        queue.async {
            guard let cloudDir = self.cloudDisksDirectory() else { return }
            try? self.fm.removeItem(at: cloudDir.appendingPathComponent(name))
        }
    }

    /// Launch-time reconcile of the two folders. Push: local files missing
    /// from the cloud, or with a newer modification date. Pull: materialized
    /// cloud files missing locally; undownloaded placeholders are asked to
    /// download so a later sync can pick them up.
    func synchronize(localDirectory: URL, completion: ((_ pushed: Int, _ pulled: Int) -> Void)? = nil) {
        queue.async {
            guard let cloudDir = self.cloudDisksDirectory() else { return }
            var pushed = 0, pulled = 0
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]

            let localFiles = (try? self.fm.contentsOfDirectory(
                at: localDirectory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])) ?? []
            let cloudItems = (try? self.fm.contentsOfDirectory(
                at: cloudDir, includingPropertiesForKeys: keys, options: [])) ?? []

            // Cloud names, with undownloaded placeholders (".<name>.icloud")
            // mapped back to their logical file names.
            var cloudNames: Set<String> = []
            for item in cloudItems {
                let raw = item.lastPathComponent
                if raw.hasSuffix(".icloud") {
                    cloudNames.insert(String(raw.dropFirst().dropLast(".icloud".count)))
                } else if raw.first != "." {
                    cloudNames.insert(raw)
                }
            }

            // PUSH — local → cloud.
            for local in localFiles where !self.isDirectory(local) {
                let name = local.lastPathComponent
                let cloudURL = cloudDir.appendingPathComponent(name)
                if !cloudNames.contains(name) {
                    if self.copyReplacing(local, to: cloudURL) { pushed += 1 }
                } else if let lm = self.modificationDate(of: local),
                          let cm = self.modificationDate(of: cloudURL),
                          lm.timeIntervalSince(cm) > 1.0 {
                    if self.copyReplacing(local, to: cloudURL) { pushed += 1 }
                }
            }

            // PULL — cloud → local (fresh install / imported on another device).
            for name in cloudNames {
                let localURL = localDirectory.appendingPathComponent(name)
                guard !self.fm.fileExists(atPath: localURL.path) else { continue }
                let cloudURL = cloudDir.appendingPathComponent(name)
                if self.fm.fileExists(atPath: cloudURL.path) {
                    if (try? self.fm.copyItem(at: cloudURL, to: localURL)) != nil { pulled += 1 }
                } else {
                    // Placeholder — request the download; a later launch (or the
                    // next sync) copies it down once materialized.
                    try? self.fm.startDownloadingUbiquitousItem(at: cloudURL)
                }
            }

            if let completion {
                let p = pushed, q = pulled
                DispatchQueue.main.async { completion(p, q) }
            }
        }
    }

    // MARK: Helpers

    @discardableResult
    private func copyReplacing(_ src: URL, to dst: URL) -> Bool {
        do {
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.copyItem(at: src, to: dst)
            return true
        } catch {
            NSLog("[Amiga] iCloud backup copy failed (%@): %@",
                  dst.lastPathComponent, error.localizedDescription)
            return false
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }

    private func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
