import SwiftUI
#if os(macOS)
import AppKit
typealias PageTurnImage = NSImage
#else
import UIKit
typealias PageTurnImage = UIImage
#endif
#if canImport(BookSlideCore)
import BookSlideCore
#endif

struct ReaderPageTurn {
    let image: PageTurnImage
    let direction: PageDirection
    var angle: Double = 0
}

/// Animate a captured sheet, so EPUB contents stay script-isolated and the
/// incoming page can finish layout behind the outgoing one without flashing.
struct PageTurnSheet: View {
    let turn: ReaderPageTurn
    private var forward: Bool { turn.direction == .next }
    var body: some View {
        GeometryReader { geometry in
            image.resizable().frame(width:geometry.size.width,height:geometry.size.height)
                .overlay {
                    LinearGradient(colors:[.clear,.black.opacity(0.20 * abs(turn.angle)/90)],
                                   startPoint:forward ? .leading : .trailing,
                                   endPoint:forward ? .trailing : .leading)
                }
                .shadow(color:.black.opacity(0.16),radius:8,x:forward ? 6 : -6)
                .rotation3DEffect(.degrees(turn.angle),axis:(x:0,y:1,z:0),
                                  anchor:forward ? .leading : .trailing,perspective:0.3)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
    private var image: Image {
        #if os(macOS)
        Image(nsImage:turn.image)
        #else
        Image(uiImage:turn.image)
        #endif
    }
}
