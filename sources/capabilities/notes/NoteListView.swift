import FairyKit
import SwiftUI

struct NoteListView: View {
    @ObservedObject var store: NoteStore
    var ownerID: UUID?
    let onSelect: (UUID) -> Void
    let onDelete: (UUID) -> Void
    let onClose: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: NoteLayout.radius, style: .continuous)
        VStack(spacing: 0) {
            HStack {
                Text("Notes")
                    .font(Theme.font(12.5, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                NoteHeaderButton(symbol: "xmark", help: "Close notes list", action: onClose)
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .frame(height: 32)
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.horizontal, 12)

            ScrollView {
                if store.notes.isEmpty {
                    Text("No notes yet")
                        .font(Theme.font(12))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(store.recent) { note in
                            NoteListRow(
                                note: note,
                                isCurrent: note.id == ownerID,
                                onOpen: { onSelect(note.id) },
                                onDelete: { onDelete(note.id) }
                            )
                        }
                    }
                    .padding(6)
                }
            }
        }
        .clipShape(shape)
        .background { NoteCardSurface(shape: shape) }
        .onExitCommand(perform: onClose)
    }
}

private struct NoteListRow: View {
    let note: Note
    let isCurrent: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.title)
                        .font(Theme.font(12, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    Text("\(note.origin.label) · \(note.updatedAt.formatted(.relative(presentation: .named)))")
                        .font(Theme.font(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isCurrent ? .isSelected : [])

            NoteHeaderButton(symbol: "trash", help: "Move \(note.title) to Trash", action: onDelete)
                .padding(.trailing, 6)
        }
        .background(Theme.slate.opacity(hovering || isCurrent ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: Theme.radiusSm))
        .onHover { hovering = $0 }
    }
}

enum NoteListLayout {
    static func frame(beside note: CGRect, within bounds: CGRect?) -> CGRect {
        let size = CGSize(width: 254, height: 248)
        let gap: CGFloat = 10
        let right = note.maxX + gap
        guard let bounds = bounds else {
            return CGRect(x: right, y: note.maxY - size.height, width: size.width, height: size.height)
        }

        let width = min(size.width, bounds.width)
        let height = min(size.height, bounds.height)
        let left = note.minX - gap - width
        let rightSpace = bounds.maxX - right
        let leftSpace = note.minX - gap - bounds.minX
        let x = rightSpace >= width || rightSpace >= leftSpace ? right : left
        return CGRect(
            x: min(max(x, bounds.minX), bounds.maxX - width),
            y: min(max(note.maxY - height, bounds.minY), bounds.maxY - height),
            width: width,
            height: height
        )
    }
}
