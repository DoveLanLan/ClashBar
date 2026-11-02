import AppKit
import SwiftUI

private typealias FS = MenuBarLayoutTokens.FontSize

extension Font {
    static func app(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font(NSFont.monospacedSystemFont(ofSize: size, weight: weight.nsFontWeight))
    }
}

/// Pre-built fonts for view bodies that are re-evaluated for large lists.
/// `Font.app(size:weight:)` builds a new `NSFont` on every call, which adds up quickly when a
/// proxy group with ~1000 nodes is laid out and refreshed at the same time.
enum AppFont {
    static let caption = Font.app(size: FS.caption, weight: .regular)
    static let captionMedium = Font.app(size: FS.caption, weight: .medium)
    static let captionSemibold = Font.app(size: FS.caption, weight: .semibold)
    static let bodyMedium = Font.app(size: FS.body, weight: .medium)
    static let bodySemibold = Font.app(size: FS.body, weight: .semibold)
    static let delayMetric = Font.system(size: FS.caption, weight: .medium, design: .monospaced)
}

extension Font.Weight {
    fileprivate var nsFontWeight: NSFont.Weight {
        switch self {
        case .ultraLight:
            .ultraLight
        case .thin:
            .thin
        case .light:
            .light
        case .regular:
            .regular
        case .medium:
            .medium
        case .semibold:
            .semibold
        case .bold:
            .bold
        case .heavy:
            .heavy
        case .black:
            .black
        default:
            .regular
        }
    }
}
