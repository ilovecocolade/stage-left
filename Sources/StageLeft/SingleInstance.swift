import Foundation

/// Makes sure only one Stage Left menu bar app runs at a time.
///
/// Two copies, even from different folders, share the same preferences and
/// fight over the same windows: each hides what the other restores, each keeps
/// its own ledger of hidden apps, and each draws its own strip on top of the
/// other's. An exclusive lock held for the app's lifetime rules that out. The
/// kernel drops the lock the instant the process dies, so a crash never leaves
/// a stale one behind. Command-line invocations do not take it.
enum SingleInstance {
    private static var descriptor: Int32 = -1

    /// True if this process is now the one Stage Left.
    static func claim() -> Bool {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stage Left", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        descriptor = open(folder.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        // If the lock file cannot be opened at all, starting is better than not.
        guard descriptor >= 0 else { return true }
        return flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }
}
