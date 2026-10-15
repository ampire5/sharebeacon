@preconcurrency import CoreServices
import Foundation

enum SnapshotFailure: Error {
    case unreadable
}

@MainActor
protocol FinderSidebarRepairing: Sendable {
    func restoreFavorite(for share: ShareConfiguration, at mountPoint: String?) -> Bool
}
@MainActor
struct FinderSidebarRepairer: FinderSidebarRepairing {
    func restoreFavorite(for share: ShareConfiguration, at mountPoint: String? = nil) -> Bool {
        let path = mountPoint ?? share.normalizedMountPoint
        let mountURL = URL(fileURLWithPath: path, isDirectory: true)
        return restoreFinderFavorite { target in
            restore(
                mountURL: mountURL,
                name: share.name,
                target: target
            )
        }
    }

    private func restore(
        mountURL: URL,
        name: String,
        target: FinderFavoriteTarget
    ) -> Bool {
        let listType: CFString
        let label: String
        switch target {
        case .volumes:
            listType = kLSSharedFileListFavoriteVolumes.takeUnretainedValue()
            label = "Favorite Volumes"
        case .items:
            listType = kLSSharedFileListFavoriteItems.takeUnretainedValue()
            label = "Favorites"
        }
        return restore(mountURL: mountURL, name: name, listType: listType, label: label)
    }

    private func restore(
        mountURL: URL,
        name: String,
        listType: CFString,
        label: String
    ) -> Bool {
        guard let list = LSSharedFileListCreate(nil, listType, nil)?.takeUnretainedValue() else {
            logError("Could not open Finder \(label) list.")
            return false
        }

        let mountPath = mountURL.standardizedFileURL.path
        guard case .success(let items) = snapshot(of: list, label: label) else {
            return false
        }

        let candidates = items.map { candidate(for: $0) }
        let plan = finderFavoritePlan(candidates: candidates, mountPath: mountPath)

        if case .collapseDuplicates(_, let drop) = plan {
            for index in drop {
                let status = LSSharedFileListItemRemove(list, items[index])
                if status != noErr {
                    logError("Finder rejected removing a duplicate \(label) item (OSStatus \(status)).")
                }
            }
        }

        switch plan {
        case .collapseDuplicates:
            // The removals invalidated the snapshot, so read the list again
            // before moving the surviving entry.
            return moveToEnd(of: list, mountPath: mountPath, label: label)

        case .insertNew:
            let inserted = LSSharedFileListInsertItemURL(
                list,
                kLSSharedFileListItemLast.takeUnretainedValue(),
                name as CFString,
                nil,
                mountURL as CFURL,
                nil,
                nil
            ) != nil
            if !inserted {
                logError("Finder rejected the \(label) insertion.")
            }
            return inserted
        }
    }

    /// Moves the entry for the mount point to the end of the list so the most
    /// recently restored share sits last in the sidebar.
    ///
    /// The third argument of `LSSharedFileListItemMove` is the entry to move
    /// after, and `kLSSharedFileListItemLast` means the end of the list. Passing
    /// the last real entry instead made Finder reject the move with a parameter
    /// error, so the entry never reached the end.
    private func moveToEnd(of list: LSSharedFileList, mountPath: String, label: String) -> Bool {
        guard case .success(let items) = snapshot(of: list, label: label) else {
            return false
        }
        guard let survivor = items.first(where: { resolvedPath(of: $0) == mountPath }) else {
            return true
        }
        let status = LSSharedFileListItemMove(
            list,
            survivor,
            kLSSharedFileListItemLast.takeUnretainedValue()
        )
        if status != noErr {
            logError("Finder rejected moving the \(label) item to the end (OSStatus \(status)).")
        }
        return status == noErr
    }

    private func snapshot(of list: LSSharedFileList, label: String) -> Result<[LSSharedFileListItem], SnapshotFailure> {
        var seed: UInt32 = 0
        guard let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeUnretainedValue() else {
            logError("Could not read Finder \(label) list.")
            return .failure(.unreadable)
        }
        return .success(snapshot as! [Any] as! [LSSharedFileListItem])
    }

    private func candidate(for item: LSSharedFileListItem) -> FinderFavoriteCandidate {
        FinderFavoriteCandidate(resolvedPath: resolvedPath(of: item))
    }

    private func resolvedPath(of item: LSSharedFileListItem) -> String? {
        var error: Unmanaged<CFError>?
        let resolved = LSSharedFileListItemCopyResolvedURL(item, 0, &error)?
            .takeUnretainedValue() as URL?
        return resolved?.standardizedFileURL.path
    }
}
