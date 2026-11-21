import SwiftUI

/// Place the strip against a visible edge of the card and keep it inside the canvas.
struct NodeMenuPlacement: Layout {
    let anchor: CGRect
    let hasTopToolbar: Bool
    func sizeThatFits(proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect,proposal: ProposedViewSize,subviews: Subviews,cache: inout ()) {
        guard let strip = subviews.first else { return }
        let inset: CGFloat = 8
        let available = bounds.inset(by:UIEdgeInsets(top:hasTopToolbar ? 60 : inset,left:inset,bottom:60,right:inset))
        let fit = ProposedViewSize(width:max(0,available.width),height:nil)
        let size = strip.sizeThatFits(fit)
        let card = anchor.offsetBy(dx:bounds.minX,dy:bounds.minY)
        var point = CGPoint(x:card.midX-size.width/2,y:card.minY-inset-size.height)
        if point.y < available.minY {
            point.y = card.maxY+inset
            if point.y+size.height > available.maxY {
                point.x = card.minX-available.minX > available.maxX-card.maxX ? card.minX-inset-size.width : card.maxX+inset
                point.y = card.minY
            }
        }
        point.x = max(available.minX,min(point.x,available.maxX-size.width))
        point.y = max(available.minY,min(point.y,available.maxY-size.height))
        strip.place(at:point,anchor:.topLeading,proposal:fit)
    }
}

struct CanvasNodeActions: View {
    let topic: MindMapTopic
    let palette: BookGraphPalette
    let perform: (String) -> Void
    private var kind: String { topic.metadata?.kind ?? "note" }
    private var structural: Bool { kind == "book" || kind == "chapter" }

    var body: some View {
        ViewThatFits(in:.horizontal) {
            strip.fixedSize()
            ScrollView(.horizontal) { strip }.scrollIndicators(.visible)
        }
        .padding(.horizontal,4)
        .background(palette.paper,in:Capsule())
        .overlay { Capsule().strokeBorder(palette.canvasAccent.opacity(0.24),lineWidth:1) }
        .shadow(color:.black.opacity(0.09),radius:5,y:2)
        .accessibilityElement(children:.contain)
        .accessibilityIdentifier("canvas-node-actions")
    }
    private var strip: some View {
        HStack(spacing:0) {
            choice("添加","添加子节点","add")
            separator
            choice("连线","连接节点","connect")
                .accessibilityHint("从这个节点连到另一个节点")
            if kind == "ink" {
                separator
                choice("合并","合并标记","mergeInk")
                if (topic.metadata?.inkParts?.count ?? 0) > 1 {
                    separator
                    choice("拆分","拆分标记","splitInk")
                }
            } else if !structural {
                separator
                choice("编辑","编辑节点文字","edit")
            }
            if structural { separator; choice("写笔记","写笔记","content") }
            separator
            choice("问 AI","AI 对话","ai")
            if !structural {
                separator
                choice("删除","删除节点","remove").foregroundStyle(.red)
            }
        }.buttonStyle(NodeCommandStyle()).font(.subheadline.weight(.medium))
            .foregroundStyle(palette.canvasAccent)
    }
    private var separator: some View { Rectangle().fill(palette.line).frame(width:1,height:14) }
    private func choice(_ text: String,_ label: String,_ command: String) -> some View {
        Button(text) { perform(command) }.accessibilityLabel(label)
    }
}
private struct NodeCommandStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.lineLimit(1).fixedSize().padding(.horizontal,8)
            .frame(minWidth:44,minHeight:44).contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}
