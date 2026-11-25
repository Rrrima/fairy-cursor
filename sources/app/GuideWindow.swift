import AppKit
import FairyKit
import SwiftUI

// The welcome guide: what a new user sees the first time the fairy runs. One white card, the
// same quiet look as the website: first what macOS has to allow, then one small looping picture
// per gesture with its keys. Reopened any time from the menu bar.

private typealias Ink = SettingsInk

/// One page of the guide: a gesture, its keys, and a line about it.
struct GuideStep: Identifiable {
    let id: String
    let name: String
    let keys: [String]
    let line: String
    let scene: GuideScene
    /// More keys that belong to this page (what you can do while recording).
    var more: [(keys: [String], does: String)] = []

    /// The pages for what this build of the fairy can do right now: a capability that is
    /// switched off (or not compiled in) doesn't get a page.
    static func steps(enabled: Set<String>) -> [GuideStep] {
        var steps: [GuideStep] = []
        let screenshots = enabled.contains("fairy.screenshots"), recording = enabled.contains("fairy.screen-recording")
        if screenshots {
            steps.append(GuideStep(id: "screenshot", name: "Screenshot", keys: ["⌘", "⇧", "4"],
                                   line: "take a screenshot. your cursor picks it up and carries it.", scene: .screenshot))
        }
        // Dropping and shaking are the fairy's own; they need something to carry.
        if screenshots || recording {
            steps.append(GuideStep(id: "drop", name: "Double-click to drop", keys: ["double-click"],
                                   line: "a text box pastes it. the desktop or a finder window saves it.", scene: .drop))
            steps.append(GuideStep(id: "shake", name: "Shake to let go", keys: ["shake"],
                                   line: "shake the cursor to drop the top one. keep shaking to drop them all.", scene: .shake))
        }
        if enabled.contains("fairy.notes") {
            steps.append(GuideStep(id: "note", name: "Note", keys: ["⌥", "click"],
                                   line: "hold ⌥ on empty space, then click. the note remembers where it was made.", scene: .note))
        }
        if recording {
            steps.append(GuideStep(id: "record", name: "Record", keys: ["⌘", "⇧", "6"],
                                   line: "records the screen your cursor is on. press it again to stop, and your cursor carries the video.",
                                   scene: .record,
                                   more: [(["⌥", "scroll"], "zoom"), (["⌥", "⌥"], "whole screen"),
                                          (["⌘", "⇧", "7"], "pen"), (["⌘", "⇧", "8"], "highlighter")]))
        }
        return steps
    }
}

/// What the guide needs to know that changes while it's open: which permissions are granted.
@MainActor
final class GuideModel: ObservableObject {
    let capabilities: CapabilityRegistry
    @Published var granted: Set<Permission> = []
    @Published var page = 0

    init(capabilities: CapabilityRegistry) {
        self.capabilities = capabilities
        refresh()
    }

    var needed: [Permission] { Permission.allCases.filter { capabilities.neededPermissions.contains($0) } }
    var steps: [GuideStep] { GuideStep.steps(enabled: Set(capabilities.enabled.map { CapabilityRegistry.manifest(of: $0).id })) }

    func refresh() {
        let now = Set(Permission.allCases.filter(\.isGranted))
        if now != granted { granted = now }
    }
}

/// Shows the guide in a borderless window like Settings': the white card is the whole window.
@MainActor
final class GuideWindowController {
    private var window: SettingsPanel?
    private let model: GuideModel
    private static let seenKey = "guide.seen"

    init(capabilities: CapabilityRegistry) {
        model = GuideModel(capabilities: capabilities)
    }

    /// Open by itself until the tour has been seen with everything allowed: a new user sees it
    /// first to allow things, then again (after the restart macOS asks for) to learn the gestures.
    func showOnLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        let allowed = model.needed.allSatisfy(\.isGranted)
        guard !allowed || !defaults.bool(forKey: Self.seenKey) else { return }
        if allowed { defaults.set(true, forKey: Self.seenKey) }
        show()
    }

    func show() {
        model.refresh()
        model.page = 0
        if window == nil {
            let window = SettingsPanel()
            window.title = "Welcome to Fairy Cursor"
            let hosting = NSHostingView(rootView: GuideView(model: model, close: { [weak window] in window?.orderOut(nil) }))
            hosting.wantsLayer = true
            hosting.layer?.backgroundColor = .clear
            window.contentView = hosting
            let pad = GuideView.shadowInset * 2
            window.setContentSize(NSSize(width: GuideView.cardSize.width + pad, height: GuideView.cardSize.height + pad))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct GuideView: View {
    @ObservedObject var model: GuideModel
    let close: () -> Void
    /// Draw every picture at this moment instead of playing it (for previews).
    var pinned: Double? = nil

    static let shadowInset: CGFloat = 28
    static let cardSize = CGSize(width: 520, height: 500)
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
    /// Permissions are granted in System Settings, behind our back: look again while we're open.
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var steps: [GuideStep] { model.steps }
    private var pages: Int { steps.count + 1 }
    private var page: Int { min(model.page, pages - 1) }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                PaperCloseButton(action: close)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)

            Group {
                if page == 0 {
                    welcome
                } else {
                    stepPage(steps[page - 1])
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(page)
            .transition(.opacity)

            footer
                .padding(.horizontal, 26)
                .padding(.bottom, 22)
        }
        .frame(width: Self.cardSize.width, height: Self.cardSize.height)
        .background(PaperCard(shape: shape))
        .clipShape(shape)
        .padding(Self.shadowInset)
        .onReceive(tick) { _ in model.refresh() }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { go(1); return .handled }
        .onKeyPress(.leftArrow) { go(-1); return .handled }
        .onKeyPress(.return) { page == pages - 1 ? close() : go(1); return .handled }
    }

    private func go(_ by: Int) {
        let next = min(pages - 1, max(0, page + by))
        guard next != page else { return }
        withAnimation(.easeOut(duration: 0.2)) { model.page = next }
    }

    // MARK: Pages

    /// Who the fairy is, and what macOS has to allow before it can do anything.
    private var welcome: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            Text("Fairy Cursor")
                .font(.system(size: 24, weight: .semibold))
                .tracking(-0.4)
                .foregroundStyle(Ink.primary)
                .padding(.top, 12)
            Text("a cursor that helps with little things:\nscreenshots, notes and recordings.")
                .font(.system(size: 14))
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Ink.secondary)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 14) {
                Text("First, let it see and reach your screen")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Ink.faint)
                ForEach(model.needed, id: \.self) { permission in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title).font(.system(size: 13.5, weight: .medium)).foregroundStyle(Ink.primary)
                            Text(Self.why(permission)).font(.system(size: 12)).foregroundStyle(Ink.secondary)
                        }
                        Spacer(minLength: 8)
                        PermissionState(granted: model.granted.contains(permission), open: { Permissions.allow(permission) })
                    }
                }
                // macOS only hands a running app its new permissions after a restart.
                Text(model.needed.allSatisfy(model.granted.contains)
                     ? "all set. it lives in the menu bar; there's no dock icon."
                     : "after allowing, quit Fairy Cursor from the menu bar and open it again.")
                    .font(.system(size: 12))
                    .foregroundStyle(Ink.faint)
            }
            .frame(width: 340, alignment: .leading)
            .padding(.top, 30)
        }
        .padding(.bottom, 6)
    }

    private static func why(_ permission: Permission) -> String {
        switch permission {
        case .accessibility: return "follow the cursor, see what's under it, paste"
        case .screenRecording: return "capture screenshots and recordings"
        }
    }

    private func stepPage(_ step: GuideStep) -> some View {
        VStack(spacing: 0) {
            GuideSceneView(scene: step.scene, pinned: pinned)
            HStack(spacing: 10) {
                Text(step.name)
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.25)
                    .foregroundStyle(Ink.primary)
                KeyChips(keys: step.keys)
            }
            .padding(.top, 14)
            Text(step.line)
                .font(.system(size: 13.5))
                .lineSpacing(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: 360)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if !step.more.isEmpty {
                // Two to a row: four across is wider than the card.
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    ForEach(Array(stride(from: 0, to: step.more.count, by: 2)), id: \.self) { row in
                        GridRow {
                            ForEach(row..<min(row + 2, step.more.count), id: \.self) { i in
                                HStack(spacing: 7) {
                                    KeyChips(keys: step.more[i].keys)
                                    Text(step.more[i].does).font(.system(size: 12)).foregroundStyle(Ink.secondary).fixedSize()
                                }
                            }
                        }
                    }
                }
                .padding(.top, 16)
            }
            Spacer(minLength: 0)
        }
    }

    /// Back, where you are, and the one dark button: next, or done on the last page.
    private var footer: some View {
        ZStack {
            HStack(spacing: 6) {
                ForEach(0..<pages, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? Ink.primary : Color(white: 0.83))
                        .frame(width: i == page ? 18 : 5, height: 5)
                        .contentShape(Rectangle().inset(by: -5))
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { model.page = i } }
                }
            }
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: page)
            HStack {
                if page > 0 { QuietButton(title: "Back") { go(-1) } }
                Spacer()
                InkButton(title: page == 0 ? "Show me" : (page == pages - 1 ? "Done" : "Next")) {
                    page == pages - 1 ? close() : go(1)
                }
            }
        }
    }
}
