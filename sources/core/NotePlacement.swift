import CoreGraphics

/// A new note's card in AppKit screen coordinates and its opening point in SwiftUI coordinates.
public struct NotePlacement {
    public let cardFrame: CGRect
    public let summonCenter: CGPoint

    public init(cursor: CGPoint, cardSize: CGSize, pillSize: CGSize, visibleFrame: CGRect?) {
        let halfPillWidth = pillSize.width / 2
        let halfPillHeight = pillSize.height / 2
        var card = CGRect(x: cursor.x - halfPillWidth, y: cursor.y + halfPillHeight - cardSize.height,
                          width: cardSize.width, height: cardSize.height)
        if let bounds = visibleFrame {
            let pillRight = cursor.x + halfPillWidth
            let pillBottom = cursor.y - halfPillHeight
            let roomRight = bounds.maxX - card.minX
            let roomDown = card.maxY - bounds.minY
            if roomRight < card.width, pillRight - bounds.minX > roomRight {
                card.origin.x = pillRight - card.width
            }
            if roomDown < card.height, bounds.maxY - pillBottom > roomDown {
                card.origin.y = pillBottom
            }
            card.origin.x = max(bounds.minX, min(card.minX, bounds.maxX - card.width))
            card.origin.y = max(bounds.minY, min(card.minY, bounds.maxY - card.height))
        }
        cardFrame = card
        // Keep the opening centered on the pill even when the card had to move.
        summonCenter = CGPoint(x: cursor.x - card.minX, y: card.maxY - cursor.y)
    }
}
