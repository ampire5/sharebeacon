@preconcurrency import CoreServices
import Foundation

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

        var seed: UInt32 = 0
        guard let snapshot = LSSharedFileListCopySnapshot(list, &seed)?.takeUnretainedValue() else {
            logError("Could not read Finder \(label) list.")
            return false
        }
        let items = snapshot as! [Any]
        guard !items.isEmpty else {
            logError("Finder \(label) list has no valid insertion point.")
            return false
        }
        let lastItem = items.last as! LSSharedFileListItem

        var existing: LSSharedFileListItem?
        for item in items {
            let item = item as! LSSharedFileListItem
            var error: Unmanaged<CFError>?
            guard let resolved = LSSharedFileListItemCopyResolvedURL(item, 0, &error)?.takeUnretainedValue() else {
                continue
            }
            if (resolved as URL).standardizedFileURL.path == mountURL.standardizedFileURL.path {
                existing = item
                break
            }
        }

        if let existing {
            guard existing !== lastItem else {
                return true
            }
            let status = LSSharedFileListItemMove(list, existing, lastItem)
            if status != noErr {
                logError("Finder rejected moving the \(label) item to the end (OSStatus \(status)).")
            }
            return status == noErr
        }

        let inserted = LSSharedFileListInsertItemURL(
            list,
            lastItem,
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
