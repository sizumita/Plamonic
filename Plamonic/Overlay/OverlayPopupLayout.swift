import AppKit

// MARK: - Popups

enum PopupSide: Equatable {
    case below
    case above
    /// Neither side had room for even one line; the popup is pinned inside the screen and may cover the anchor.
    case overlapping
}

enum PopupPlacement {
    static let gap: CGFloat = 6
    static let screenMargin: CGFloat = 8

    /// Room below and above `anchor` inside `screen` (AX coordinates), after the gap and margins.
    static func availableHeights(anchor: CGRect, screen: CGRect) -> (below: CGFloat, above: CGFloat) {
        let below = (screen.maxY - screenMargin) - (anchor.maxY + gap)
        let above = (anchor.minY - gap) - (screen.minY + screenMargin)
        return (max(0, below), max(0, above))
    }

    /// Places a popup of `size` next to `anchor` without covering it: below when it fits, else above,
    /// else on the roomier side with the height reduced to the room there (callers re-fit the text).
    /// Only when neither side has `minimumHeight` of room is the popup pinned to the screen's bottom.
    static func place(size: CGSize, anchor: CGRect, screen: CGRect, minimumHeight: CGFloat) -> (
        frame: CGRect, side: PopupSide
    ) {
        let anchor = anchor.standardized
        let room = availableHeights(anchor: anchor, screen: screen)
        let width = min(size.width, max(1, screen.width - 2 * screenMargin))
        let x = clamp(anchor.minX, screen.minX + screenMargin, screen.maxX - screenMargin - width)

        if size.height <= room.below {
            return (CGRect(x: x, y: anchor.maxY + gap, width: width, height: size.height), .below)
        }
        if size.height <= room.above {
            return (CGRect(x: x, y: anchor.minY - gap - size.height, width: width, height: size.height), .above)
        }
        if max(room.below, room.above) >= minimumHeight {
            if room.below >= room.above {
                return (CGRect(x: x, y: anchor.maxY + gap, width: width, height: room.below), .below)
            }
            return (CGRect(x: x, y: anchor.minY - gap - room.above, width: width, height: room.above), .above)
        }
        let height = min(size.height, max(1, screen.height - 2 * screenMargin))
        return (
            CGRect(x: x, y: screen.maxY - screenMargin - height, width: width, height: height), .overlapping
        )
    }

    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard upper >= lower else { return lower }
        return min(max(value, lower), upper)
    }
}

/// Size and position of a translation popup.
struct OverlayPopupLayout: Equatable {
    /// Popup frame in AX coordinates.
    var frame: CGRect
    /// Text box inside the popup (popup-local, flipped).
    var textRect: CGRect
    var fontSize: CGFloat
    var side: PopupSide
}

extension OverlayLayout {
    static let popupPadding = CGSize(width: 10, height: 7)
    static let popupMinWidth: CGFloat = 60
    static let popupPreferredMinWidth: CGFloat = 240
    static let popupMaxWidth: CGFloat = 520
    static let popupCornerRadius: CGFloat = 8

    /// Preferred popup font size: 13pt, kept inside the user's min/max sizes.
    static func popupFontSize(_ appearance: OverlayAppearance) -> CGFloat {
        let lower = CGFloat(min(appearance.minFontSize, appearance.maxFontSize))
        let upper = CGFloat(max(appearance.minFontSize, appearance.maxFontSize))
        return PopupPlacement.clamp(13, lower, upper)
    }

    /// Lays out a popup for `text` next to `anchor` (AX) on `screen` (AX visible frame).
    static func popup(
        text: String, anchor: CGRect, screen: CGRect, appearance: OverlayAppearance, fitter: TextFitter
    ) -> OverlayPopupLayout {
        let pad = popupPadding
        let maxWidth = max(popupMinWidth, min(popupMaxWidth, screen.width - 2 * PopupPlacement.screenMargin))
        let targetWidth = min(maxWidth, max(popupPreferredMinWidth, anchor.width))
        let textWidth = max(1, targetWidth - 2 * pad.width)
        var fontSize = popupFontSize(appearance)
        var textSize = fitter.measure(text, fontSize: fontSize, maxWidth: textWidth)
        var size = CGSize(
            width: min(targetWidth, max(popupMinWidth, textSize.width + 2 * pad.width)),
            height: textSize.height + 2 * pad.height)

        let minFont = CGFloat(min(appearance.minFontSize, appearance.maxFontSize))
        let minimumHeight = fitter.lineHeight(fontSize: minFont) + 2 * pad.height
        let room = PopupPlacement.availableHeights(anchor: anchor, screen: screen)
        if size.height > room.below, size.height > room.above, max(room.below, room.above) >= minimumHeight {
            // Too tall for either side: shrink the text into the roomier side.
            let available = max(room.below, room.above) - 2 * pad.height
            let fit = fitter.fit(
                text, in: CGSize(width: textWidth, height: available), minFontSize: minFont, maxFontSize: fontSize)
            fontSize = fit.fontSize
            textSize = fit.textSize
            size = CGSize(
                width: min(targetWidth, max(popupMinWidth, textSize.width + 2 * pad.width)),
                height: textSize.height + 2 * pad.height)
        }

        let placed = PopupPlacement.place(size: size, anchor: anchor, screen: screen, minimumHeight: minimumHeight)
        let textRect = CGRect(
            x: pad.width, y: pad.height,
            width: max(1, placed.frame.width - 2 * pad.width), height: max(1, placed.frame.height - 2 * pad.height))
        return OverlayPopupLayout(frame: placed.frame, textRect: textRect, fontSize: fontSize, side: placed.side)
    }
}
