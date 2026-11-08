import AppKit
import ApplicationServices
import CursorMonitorKit
import FairyCore

/// Turns a double-click (with its accessibility context) into one of the fairy's deliveries.
/// The decision rules live in `DropPolicy` (FairyCore); this does the live lookups and acting.
@MainActor
final class DropRouter {
    private let state: FairyState
    /// A delivery is in progress (double-clicks and hover lookups wait).
    private(set) var busy = false
    private let axQueue = DispatchQueue(label: "fairy.drop-router.ax", qos: .userInitiated)

    init(state: FairyState) {
        self.state = state
    }

    /// A double-click delivers the whole pile (it's a cart: you dump it), top card first.
    func handleDoubleClick(event: CursorEvent, context: CursorContext?) {
        let point = CGPoint(x: event.x ?? 0, y: event.y ?? 0)
        let pid = pidForEvent(context: context)
        let isFinder = event.bundleId == FinderTarget.finderBundleID
        let finderSpot = isFinder && FinderTarget.isDropSpot(role: event.uiElementRole, element: context?.element)
        let editable = event.uiElementIsEditableText == true && event.uiElementSubrole != (kAXSecureTextFieldSubrole as String)
        let facts = DropPolicy.DoubleClick(
            isHolding: state.isHolding, hiddenForCapture: state.hiddenForCapture, busy: busy,
            clickCount: event.clickCount ?? 0, targetIsOwnProcess: pid == getpid(),
            isFinder: isFinder, finderDropSpot: finderSpot, editableUnderCursor: editable
        )
        let action = DropPolicy.decide(facts)
        NSLog("[FairyCursor] double-click → %@ (pid %d role %@)", String(describing: action), pid ?? -1, event.uiElementRole ?? "-")
        switch action {
        case .ignore:
            return
        case .saveToFinder:
            saveToFinder(element: context?.element)
        case .paste:
            deliverPaste(to: pid, element: context?.element)
        case .checkFocusAfterMouseUp:
            checkFocusAfterMouseUp(pid: pid, point: point)
        }
    }

    // MARK: - Finder

    private func saveToFinder(element: AXUIElement?) {
        guard let folder = FinderTarget.folder(for: element) else {
            state.reject(hint: "couldn't find that folder")
            return
        }
        let pile = state.deliverable
        let saved = pile.filter { shot in
            guard let url = FinderTarget.save(shot, into: folder) else { return false }
            NSLog("[FairyCursor] saved \(url.path)")
            return true
        }
        if saved.isEmpty {
            state.reject(hint: "couldn't save there")
            return
        }
        let what = saved.count == 1 ? "saved" : "saved \(saved.count)"
        // Only what was written leaves the fairy's hands; a failed save stays held.
        state.deliver(ids: saved.map { $0.id }, hint: "\(what) to \(folder.lastPathComponent)")
        if saved.count < pile.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4 * Double(saved.count)) { [weak self] in
                self?.state.reject(hint: "couldn't save \(pile.count - saved.count)")
            }
        }
    }

    // MARK: - Text inputs

    /// Nothing recognisable was under the cursor at mouse-down. After the release, look again:
    /// web inputs appear late, and native composers often hide under a placeholder label or
    /// expose only their focused text view.
    private func checkFocusAfterMouseUp(pid: pid_t?, point: CGPoint) {
        busy = true
        if let pid = pid { prepare(pid: pid) }
        let start = CACurrentMediaTime()
        func poll() {
            let step = PastePolicy.mouseUpStep(elapsed: CACurrentMediaTime() - start, buttonsDown: NSEvent.pressedMouseButtons != 0)
            if step == .wait {
                DispatchQueue.main.asyncAfter(deadline: .now() + PastePolicy.mouseUpPollInterval) { poll() }
                return
            }
            // Chromium needs a moment after the switch is flipped; focus needs a moment after the release.
            let settle = pid.map { isChromiumLike(pid: $0) } == true ? 0.2 : 0.1
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in self?.resolveAfterMouseUp(pid: pid, point: point) }
        }
        poll()
    }

    private func resolveAfterMouseUp(pid: pid_t?, point: CGPoint) {
        axQueue.async {
            let spot = DropSpotInfo.resolve(at: point)
            var focusedElement: AXUIElement?
            var focusedEditable = false
            var focusedFrame: CGRect?
            if let pid = pid, let focused = AXNode.focused(in: pid), let editable = EditableResolver.editableSelfOrAncestor(focused) {
                focusedEditable = true
                focusedFrame = editable.frame ?? focused.frame
                focusedElement = editable.element
            }
            let samePID = spot.pid == nil || pid == nil || spot.pid == pid
            let ok = DropPolicy.confirmAfterMouseUp(point: point, hitEditable: spot.editable != nil && samePID,
                                                    focusedEditable: focusedEditable, focusedFrame: focusedFrame,
                                                    nearbyEditable: false)
            let target = (samePID ? spot.editable : nil) ?? focusedElement
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.busy = false
                    NSLog("[FairyCursor] after mouse-up: editable=%@ focused=%@ → %@",
                          spot.editable != nil ? "yes" : "no", focusedEditable ? "yes" : "no", ok ? "paste" : "ignore")
                    guard ok, self.state.isHolding, !self.state.hiddenForCapture else { return }
                    self.deliverPaste(to: pid, element: target)
                }
            }
        }
    }

    /// Paste the top card and, once the field has taken it, the rest of the pile after it.
    private func deliverPaste(to pid: pid_t?, element: AXUIElement?) {
        let ids = state.deliverable.map(\.id)
        guard let first = ids.first, let top = state.card(first) else { return }
        busy = true
        let clipboard = PasteboardSnapshot(NSPasteboard.general)
        let count = ids.count
        PasteTarget.paste(top, to: pid, element: element, clipboard: clipboard) { [weak self] outcome in
            guard let self = self else { return }
            switch outcome {
            case .accepted(let delivery):
                let hint = count == 1 ? (delivery.isPath ? "pasted path" : "pasted") : "pasted \(count)"
                self.state.deliver(ids: [first], hint: hint)
                self.pasteRest(Array(ids.dropFirst()), to: pid, clipboard: clipboard, hint: hint)
            case .rejected:
                self.busy = false
                self.state.reject(hint: "this field doesn't take images")
            case .failed:
                self.busy = false
                self.state.reject(hint: "couldn't paste · still holding it")
            }
        }
    }

    private func pasteRest(_ remaining: [UUID], to pid: pid_t?, clipboard: PasteboardSnapshot, hint: String) {
        // Let the delivered card leave first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self = self else { return }
            // Cards shaken off (or otherwise gone) meanwhile are skipped; new captures are not taken.
            var rest = remaining
            while let id = rest.first, self.state.card(id) == nil { rest.removeFirst() }
            guard let id = rest.first, let next = self.state.card(id) else {
                self.busy = false
                return
            }
            PasteTarget.paste(next, to: pid, element: nil, collapseSelection: false, verify: false, clipboard: clipboard) { [weak self] outcome in
                guard let self = self else { return }
                if case .accepted = outcome {
                    self.state.deliver(ids: [id], hint: hint)
                    self.pasteRest(Array(rest.dropFirst()), to: pid, clipboard: clipboard, hint: hint)
                } else {
                    self.busy = false
                    self.state.reject(hint: "couldn't paste the rest")
                }
            }
        }
    }

    private func pidForEvent(context: CursorContext?) -> pid_t? {
        if let element = context?.element {
            var pid: pid_t = 0
            if AXUIElementGetPid(element, &pid) == .success, pid > 0 { return pid }
        }
        if let pid = context?.window?.pid, pid > 0 { return pid }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    /// Chromium/Electron apps take ~2 s to expose their web inputs after the switch is flipped, so
    /// the hover path calls this ahead of any double-click.
    func prepare(pid: pid_t) {
        if isChromiumLike(pid: pid) { PasteTarget.enableWebAccessibilityIfNeeded(pid: pid) }
    }

    private func isChromiumLike(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return PasteTarget.isChromiumLike(app)
    }
}
