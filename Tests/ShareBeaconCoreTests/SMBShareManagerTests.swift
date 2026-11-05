import Foundation
import Synchronization
import Testing
@testable import ShareBeaconCore

private struct ManagerCredentials: CredentialStoring {
    func save(password: String, for share: ShareConfiguration) throws {}
    func password(for share: ShareConfiguration) throws -> String? { "test-placeholder" }
    func hasPassword(for share: ShareConfiguration) -> Bool { true }
    func deletePassword(for share: ShareConfiguration) throws {}
    func sharedCredentials(forHost host: String) -> [SharedCredential] { [] }
    func saveSharedCredential(_ credential: SharedCredential, password: String) throws {}
    func deleteSharedCredential(_ credential: SharedCredential) throws {}
}

private actor PendingEndpoint: EndpointChecking {
    private var pending: [Int: CheckedContinuation<Bool, Never>] = [:]
    private(set) var count = 0
    func isReachable(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation {
            pending[count] = $0
            count += 1
        }
    }
    func finish(_ index: Int = 0) { pending.removeValue(forKey: index)?.resume(returning: true) }
    func finishAll() {
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(returning: true) }
    }
}

private final class RecordingMounter: ShareMounting {
    let mounts = Mutex<[ShareConfiguration]>([])
    let unmounts = Mutex<[Bool]>([])
    let unmountPaths = Mutex<[String]>([])
    let busy: Mutex<Bool>
    let didUnmount: @Sendable () -> Void
    init(busy: Bool = false, didUnmount: @escaping @Sendable () -> Void = {}) {
        self.busy = Mutex(busy)
        self.didUnmount = didUnmount
    }
    func mount(_ share: ShareConfiguration, password: String) throws {
        mounts.withLock { $0.append(share) }
        throw ShareBeaconError.credentialMissing
    }
    func unmount(_ share: ShareConfiguration, at mountPoint: String, forcing: Bool) throws {
        unmountPaths.withLock { $0.append(mountPoint) }
        unmounts.withLock { $0.append(forcing) }
        if busy.withLock({ $0 }) { throw ShareBeaconError.unmountFailed(1) }
        didUnmount()
    }
}

private final class BlockingMounter: ShareMounting {
    let entered = Mutex(false)
    let release = DispatchSemaphore(value: 0)
    let table = Mutex("")
    let unmounts = Mutex<[Bool]>([])
    let busy: Bool
    init(busy: Bool) { self.busy = busy }
    func mount(_ share: ShareConfiguration, password: String) throws {
        entered.withLock { $0 = true }
        release.wait()
        table.withLock { $0 = "//tester@\(share.host)/\(share.shareName) on \(share.normalizedMountPoint) (smbfs, nodev)" }
    }
    func unmount(_ share: ShareConfiguration, at mountPoint: String, forcing: Bool) throws {
        unmounts.withLock { $0.append(forcing) }
        if busy { throw ShareBeaconError.credentialMissing }
        table.withLock { $0 = "" }
    }
}

private struct NoFavorites: FinderSidebarRepairing {
    func restoreFavorite(for share: ShareConfiguration, at mountPoint: String?) -> Bool { false }
}
private struct NoLinks: NetworkLinkResolving {
    func link(toHost host: String) -> NetworkLink? { nil }
    func link(forInterface name: String) -> NetworkLink? { nil }
}

@Suite("Share manager operation ownership", .serialized)
@MainActor struct SMBShareManagerTests {
    private func share() -> ShareConfiguration {
        ShareConfiguration(name: "Data", host: "192.0.2.11", shareName: "Data", username: "tester",
                           mountPoint: "/Users/tester/Volumes/Data", isEnabled: true)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        try #require(await condition(), "Timed out waiting for test operation")
    }

    @Test("disabling during endpoint wait cannot mount or restore mounted state")
    func disableDuringEndpoint() async throws {
        let suite = "ShareBeaconTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = PendingEndpoint(), mounter = RecordingMounter()
        defer { Task { await endpoint.finishAll() } }
        let manager = SMBShareManager(credentialStore: ManagerCredentials(), endpointChecker: endpoint,
            mounter: mounter, finderSidebarRepairer: NoFavorites(), linkResolver: NoLinks(), defaults: defaults,
            mountTable: { MountTable(output: "") }, monitoringEnabled: false, log: { _, _ in })
        let configured = share()
        try manager.saveShare(configured, password: nil)
        try await waitUntil { await endpoint.count == 1 }
        manager.setEnabled(false, for: configured)
        await endpoint.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(manager.state(for: configured) == .disabled)
        #expect(mounter.mounts.withLock { $0.isEmpty })
    }

    @Test("editing an endpoint starts a new operation and ignores the old result")
    func editDuringEndpoint() async throws {
        let suite = "ShareBeaconTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = PendingEndpoint(), mounter = RecordingMounter()
        defer { Task { await endpoint.finishAll() } }
        let manager = SMBShareManager(credentialStore: ManagerCredentials(), endpointChecker: endpoint,
            mounter: mounter, finderSidebarRepairer: NoFavorites(), linkResolver: NoLinks(), defaults: defaults,
            mountTable: { MountTable(output: "") }, monitoringEnabled: false, log: { _, _ in })
        var configured = share()
        try manager.saveShare(configured, password: nil)
        try await waitUntil { await endpoint.count == 1 }
        configured.host = "192.0.2.12"
        try manager.saveShare(configured, password: nil)
        try await waitUntil { await endpoint.count == 2 }
        await endpoint.finish(0)
        try await Task.sleep(for: .milliseconds(30))
        #expect(manager.state(for: configured) == .waitingForNetwork)
        #expect(mounter.mounts.withLock { $0.isEmpty })
        // The old completion must not remove the new operation's ownership.
        manager.mount(configured)
        try await Task.sleep(for: .milliseconds(10))
        #expect(await endpoint.count == 2)
        await endpoint.finish(1)
        try await waitUntil { mounter.mounts.withLock { !$0.isEmpty } }
        #expect(mounter.mounts.withLock { $0.map(\.host) } == ["192.0.2.12"])
    }

    @Test("mount failure never adopts another server's same-named share")
    func failureOnOtherServer() async throws {
        let suite = "ShareBeaconTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = PendingEndpoint(), mounter = RecordingMounter()
        defer { Task { await endpoint.finishAll() } }
        let manager = SMBShareManager(credentialStore: ManagerCredentials(), endpointChecker: endpoint,
            mounter: mounter, finderSidebarRepairer: NoFavorites(), linkResolver: NoLinks(), defaults: defaults,
            mountTable: { MountTable(output: "//tester@192.0.2.22/Data on /other/Data (smbfs, nodev)") },
            monitoringEnabled: false, log: { _, _ in })
        let configured = share()
        try manager.saveShare(configured, password: nil)
        try await waitUntil { await endpoint.count == 1 }
        await endpoint.finish()
        try await waitUntil { manager.state(for: configured) != .waitingForNetwork && manager.state(for: configured) != .mounting }
        if case .failed = manager.state(for: configured) {} else { Issue.record("Wrong host was adopted as mounted") }
        #expect(manager.mountPath(for: configured) == "/Users/tester/Volumes/Data")
    }

    @Test("explicit endpoint result cannot survive disable, removal or sleep", arguments: ["disable", "remove", "sleep"])
    func invalidateExplicitMount(action: String) async throws {
        let suite = "ShareBeaconTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = PendingEndpoint(), mounter = RecordingMounter()
        defer { Task { await endpoint.finishAll() } }
        let manager = SMBShareManager(credentialStore: ManagerCredentials(), endpointChecker: endpoint,
            mounter: mounter, finderSidebarRepairer: NoFavorites(), linkResolver: NoLinks(), defaults: defaults,
            mountTable: { MountTable(output: "") }, monitoringEnabled: false, log: { _, _ in })
        var configured = share()
        configured.autoMount = false
        try manager.saveShare(configured, password: nil)
        manager.mount(configured, explicit: true)
        try await waitUntil { await endpoint.count == 1 }
        switch action {
        case "disable": manager.setEnabled(false, for: configured)
        case "remove": manager.removeShare(configured)
        default: manager.didSleep()
        }
        await endpoint.finish()
        try await Task.sleep(for: .milliseconds(30))
        #expect(mounter.mounts.withLock { $0.isEmpty })
        #expect(manager.state(for: configured) != .mounted)
        if action == "remove" { #expect(manager.states[configured.id] == nil) }
        if action == "disable" { #expect(manager.state(for: configured) == .disabled) }
    }

    @Test("late blocking mounts are retired without force, with busy volumes left intact", arguments: [false, true])
    func blockedMountAfterDisable(busy: Bool) async throws {
        let suite = "ShareBeaconTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let endpoint = PendingEndpoint(), mounter = BlockingMounter(busy: busy)
        defer { mounter.release.signal(); Task { await endpoint.finishAll() } }
        let manager = SMBShareManager(credentialStore: ManagerCredentials(), endpointChecker: endpoint,
            mounter: mounter, finderSidebarRepairer: NoFavorites(), linkResolver: NoLinks(), defaults: defaults,
            mountTable: { MountTable(output: mounter.table.withLock { $0 }) }, monitoringEnabled: false, log: { _, _ in })
        let configured = share()
        try manager.saveShare(configured, password: nil)
        try await waitUntil { await endpoint.count == 1 }
        await endpoint.finish()
        try await waitUntil { mounter.entered.withLock { $0 } }
        manager.setEnabled(false, for: configured)
        mounter.release.signal()
        try await waitUntil { mounter.unmounts.withLock { !$0.isEmpty } }
        try await Task.sleep(for: .milliseconds(10))
        #expect(mounter.unmounts.withLock { $0 } == [false])
        #expect(manager.state(for: configured) == .disabled)
        #expect(mounter.table.withLock { $0.isEmpty } == !busy)
    }


    @Test("removal uses the adopted mount path without forcing a busy volume", arguments: [false, true])
    func removingAdoptedMount(busy: Bool) async throws {
        let suite = "ShareBeaconTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let mounter = RecordingMounter(busy: busy)
        let manager = SMBShareManager(credentialStore: ManagerCredentials(), endpointChecker: PendingEndpoint(),
            mounter: mounter, finderSidebarRepairer: NoFavorites(), linkResolver: NoLinks(), defaults: defaults,
            mountTable: { MountTable(output: "//tester@192.0.2.11/Data on /Volumes/Data-1 (smbfs, nodev)") },
            monitoringEnabled: false, log: { _, _ in })
        let configured = share()
        try manager.saveShare(configured, password: nil)
        #expect(manager.mountPath(for: configured) == "/Volumes/Data-1")
        manager.removeShare(configured)
        try await waitUntil { mounter.unmounts.withLock { !$0.isEmpty } }
        try await Task.sleep(for: .milliseconds(10))
        #expect(mounter.unmountPaths.withLock { $0 } == ["/Volumes/Data-1"])
        #expect(mounter.unmounts.withLock { $0 } == [false])
        #expect(manager.states[configured.id] == nil)
    }

    @Test("busy reconciliation stays failed until the previous mount can be retired", arguments: ["credential", "host"])
    func busyReconciliationIsNotReplaced(change: String) async throws {
        let suite = "ShareBeaconTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let table = Mutex("//tester@192.0.2.11/Data on /Volumes/Data-1 (smbfs, nodev)")
        let mounter = RecordingMounter(busy: true, didUnmount: { table.withLock { $0 = "" } })
        let endpoint = PendingEndpoint()
        defer { Task { await endpoint.finishAll() } }
        let manager = SMBShareManager(credentialStore: ManagerCredentials(), endpointChecker: endpoint,
            mounter: mounter, finderSidebarRepairer: NoFavorites(), linkResolver: NoLinks(), defaults: defaults,
            mountTable: { MountTable(output: table.withLock { $0 }) },
            monitoringEnabled: false, log: { _, _ in })
        var configured = share()
        try manager.saveShare(configured, password: nil)
        if change == "credential" { configured.username = "other" } else { configured.host = "192.0.2.12" }
        try manager.saveShare(configured, password: nil)
        try await waitUntil { mounter.unmounts.withLock { !$0.isEmpty } }
        try await Task.sleep(for: .milliseconds(10))
        manager.refreshMountStates()
        manager.mount(configured) // A normal reconnect must not adopt the connection using the old configuration.
        try await Task.sleep(for: .milliseconds(10))
        if case .failed = manager.state(for: configured) {} else { Issue.record("Busy reconciliation was masked") }
        #expect(await endpoint.count == 0)
        manager.mount(configured, explicit: true) // A user retry first attempts a non-forcing retirement again.
        try await waitUntil { mounter.unmounts.withLock { $0.count >= 2 } }
        #expect(mounter.unmountPaths.withLock { $0 } == ["/Volumes/Data-1", "/Volumes/Data-1"])
        #expect(mounter.unmounts.withLock { $0 } == [false, false])
        try await waitUntil { if case .failed = manager.state(for: configured) { true } else { false } }
        mounter.busy.withLock { $0 = false }
        manager.mount(configured, explicit: true)
        try await waitUntil { await endpoint.count == 1 }
        await endpoint.finish()
        try await waitUntil { mounter.mounts.withLock { $0.count == 1 } }
        #expect(mounter.mounts.withLock { $0.first?.host } == configured.host)
        #expect(mounter.mounts.withLock { $0.first?.username } == configured.username)
        #expect(mounter.unmounts.withLock { $0 } == [false, false, false])
    }

}
