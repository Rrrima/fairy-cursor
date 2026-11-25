import FairyKit
import FairyNotes
import FairyRecording
import FairyScreenshots
import Foundation

/// The capabilities this build of the fairy has, and which of them are switched on. A
/// capability is switched on unless the user turned it off, so new ones arrive enabled.
@MainActor
final class CapabilityRegistry: ObservableObject {
    /// Every capability compiled into the app, in menu and Settings order. To add one, write a
    /// type conforming to `Capability` (see sources/kit) and list it here.
    nonisolated(unsafe) static let builtIn: [any Capability.Type] = [
        ScreenshotsCapability.self,
        NotesCapability.self,
        RecordingCapability.self,
    ]

    let all: [any Capability]
    @Published private(set) var disabledIDs: Set<String>
    private var active: Set<String> = []
    private weak var host: FairyHost?
    /// Called after a capability is deactivated, so the host can drop whatever it set up for it.
    var onDeactivated: (String) -> Void = { _ in }

    private let disabledKey = "capabilities.disabled"

    init(_ types: [any Capability.Type] = builtIn) {
        all = types.map { $0.init() }
        disabledIDs = Set(UserDefaults.standard.stringArray(forKey: disabledKey) ?? [])
    }

    static func manifest(of capability: any Capability) -> CapabilityManifest {
        type(of: capability).manifest
    }

    var enabled: [any Capability] { all.filter { isEnabled(Self.manifest(of: $0).id) } }

    func isEnabled(_ id: String) -> Bool { !disabledIDs.contains(id) }

    /// What the enabled capabilities need, plus Accessibility for the fairy itself (it reads what's
    /// under the cursor and pastes).
    var neededPermissions: Set<Permission> {
        enabled.reduce(into: [.accessibility]) { $0.formUnion(Self.manifest(of: $1).permissions) }
    }

    func start(host: FairyHost) {
        self.host = host
        for capability in enabled { activate(capability) }
    }

    func stopAll() {
        for capability in all where active.contains(Self.manifest(of: capability).id) { deactivate(capability) }
    }

    func setEnabled(_ id: String, _ on: Bool) {
        guard isEnabled(id) != on, let capability = all.first(where: { Self.manifest(of: $0).id == id }) else { return }
        if on { disabledIDs.remove(id) } else { disabledIDs.insert(id) }
        UserDefaults.standard.set(Array(disabledIDs).sorted(), forKey: disabledKey)
        if on {
            for permission in Self.manifest(of: capability).permissions where !permission.isGranted { Permissions.allow(permission) }
            activate(capability)
        } else {
            deactivate(capability)
        }
    }

    private func activate(_ capability: any Capability) {
        let id = Self.manifest(of: capability).id
        guard let host = host, !active.contains(id) else { return }
        active.insert(id)
        capability.activate(host: host)
        FairyLog.write("capability on: \(id)")
    }

    private func deactivate(_ capability: any Capability) {
        let id = Self.manifest(of: capability).id
        guard active.remove(id) != nil else { return }
        capability.deactivate()
        onDeactivated(id)
        FairyLog.write("capability off: \(id)")
    }
}
