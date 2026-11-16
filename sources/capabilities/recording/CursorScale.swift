import Foundation

/// Makes the system cursor bigger while recording, so it reads clearly in the video, and puts it
/// back afterwards. Uses SkyLight's cursor scale (the same one the accessibility "pointer size"
/// slider drives), loaded at run time; if it can't be found, nothing happens.
///
/// The original size is written down before changing it, so if the app dies mid-recording the
/// next launch restores it (`restoreIfLeftEnlarged`).
@MainActor
enum CursorScale {
    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias GetFn = @convention(c) (Int32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (Int32, Float) -> Int32

    private static let savedKey = "recording.originalCursorScale"

    private static let api: (connection: ConnectionFn, get: GetFn, set: SetFn)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let c = dlsym(handle, "CGSMainConnectionID"),
              let g = dlsym(handle, "CGSGetCursorScale"),
              let s = dlsym(handle, "CGSSetCursorScale") else { return nil }
        return (unsafeBitCast(c, to: ConnectionFn.self), unsafeBitCast(g, to: GetFn.self), unsafeBitCast(s, to: SetFn.self))
    }()

    static var current: Float? {
        guard let api = api else { return nil }
        var scale: Float = 0
        return api.get(api.connection(), &scale) == 0 && scale > 0 ? scale : nil
    }

    private static func set(_ scale: Float) {
        guard let api = api else { return }
        _ = api.set(api.connection(), scale)
    }

    /// Scale the cursor up by `factor` (capped at the system's maximum of 4).
    static func enlarge(by factor: Float = 1.75) {
        guard let original = current else { return }
        if UserDefaults.standard.object(forKey: savedKey) == nil {
            UserDefaults.standard.set(original, forKey: savedKey)
        }
        set(min(4, max(original * factor, 2)))
    }

    /// Put the cursor back to the size it had before `enlarge`.
    static func restore() {
        guard let original = UserDefaults.standard.object(forKey: savedKey) as? Float else { return }
        set(original)
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    /// At launch: a previous run enlarged the cursor and never got to put it back.
    static func restoreIfLeftEnlarged() { restore() }
}
