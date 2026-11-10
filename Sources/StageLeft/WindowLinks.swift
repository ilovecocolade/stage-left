import AppKit

/// Windows the user has linked, so they go on and off stage together.
///
/// A group is a set of window numbers. Linking two windows from different
/// groups merges them; a group shrunk to one window is dropped. Window numbers
/// last as long as the window, so groups are kept across Stage Left restarts
/// and pruned once their windows close.
final class WindowLinks {
    private static let key = "linkedWindowGroups"
    private var groups: [Set<CGWindowID>]

    init() {
        let stored = UserDefaults.standard.array(forKey: Self.key) as? [[Int]] ?? []
        groups = stored.map { Set($0.map { CGWindowID($0) }) }.filter { $0.count > 1 }
    }

    var isEmpty: Bool { groups.isEmpty }

    /// Every window linked to this one, including itself; just itself if unlinked.
    func group(of id: CGWindowID) -> Set<CGWindowID> {
        groups.first { $0.contains(id) } ?? [id]
    }

    func isLinked(_ id: CGWindowID) -> Bool { groups.contains { $0.contains(id) } }

    /// The same for every window in a group, to keep their strip tiles together.
    func groupKey(of id: CGWindowID) -> CGWindowID? { groups.first { $0.contains(id) }?.min() }

    /// Links `other` into `window`'s group, or takes it out if already there.
    func toggle(_ other: CGWindowID, with window: CGWindowID) {
        if group(of: window).contains(other) {
            remove(other)
        } else {
            let merged = group(of: window).union(group(of: other))
            groups.removeAll { !$0.isDisjoint(with: merged) }
            groups.append(merged)
        }
        save()
    }

    /// Takes a window out of its group.
    func remove(_ id: CGWindowID) {
        groups = groups.map { $0.subtracting([id]) }.filter { $0.count > 1 }
        save()
    }

    /// Drops windows that no longer exist. Asks the window server about every
    /// window on every Space, including hidden and minimised ones.
    func prune() {
        guard !groups.isEmpty else { return }
        let listed = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let alive = Set(listed.compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        let pruned = groups.map { $0.intersection(alive) }.filter { $0.count > 1 }
        guard pruned != groups else { return }
        groups = pruned
        save()
    }

    private func save() {
        UserDefaults.standard.set(groups.map { $0.map { Int($0) } }, forKey: Self.key)
    }
}
