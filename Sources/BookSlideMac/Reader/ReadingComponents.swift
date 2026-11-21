import SwiftUI

/// Blend scrolling text into the page instead of cutting it off at an inset
/// rectangle. The overlay never participates in text selection or gestures.
struct ReaderEdgeFade: View {
    let background: Color
    let top: CGFloat
    let bottom: CGFloat
    var body: some View {
        VStack(spacing:0) {
            LinearGradient(colors:[background,background.opacity(0)],startPoint:.top,endPoint:.bottom)
                .frame(height:top)
            Spacer(minLength:0)
            LinearGradient(colors:[background.opacity(0),background],startPoint:.top,endPoint:.bottom)
                .frame(height:bottom)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}
#if canImport(BookSlideCore)
import BookSlideCore
#endif

#if os(iOS)
let readingAccent = Color(uiColor:.systemOrange)
#else
let readingAccent = Color(red:0.29,green:0.38,blue:0.32)
#endif

struct BookJacket: View {
    enum Style: Equatable { case standard, plain }
    @ObservedObject var reader: ReaderModel
    let book: LibraryBook
    var style: Style = .standard
    private var tone: Color {
        if style == .plain {
            let palette = [Color(red:0.24,green:0.30,blue:0.27),Color(red:0.48,green:0.42,blue:0.34),
                           Color(red:0.30,green:0.36,blue:0.40),Color(red:0.45,green:0.35,blue:0.34),
                           Color(red:0.32,green:0.31,blue:0.38),Color(red:0.45,green:0.45,blue:0.37)]
            return palette[book.title.utf8.reduce(0) { ($0 + Int($1)) % palette.count }]
        }
        #if os(iOS)
        let palette = [Color(red:0.17,green:0.25,blue:0.36), Color(red:0.58,green:0.23,blue:0.18),
                       Color(red:0.25,green:0.35,blue:0.31), Color(red:0.39,green:0.29,blue:0.43),
                       Color(red:0.67,green:0.45,blue:0.25), Color(red:0.24,green:0.38,blue:0.44)]
        return palette[book.title.utf8.reduce(0) { ($0 + Int($1)) % palette.count }]
        #else
        let palette = [Color(red:0.25,green:0.33,blue:0.29), Color(red:0.43,green:0.31,blue:0.25), Color(red:0.28,green:0.34,blue:0.43)]
        return palette[book.title.utf8.reduce(0) { ($0 + Int($1)) % 3 }]
        #endif
    }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment:.leading) {
                if let image = reader.cover(book) {
                    #if os(macOS)
                    Image(nsImage:image).resizable().scaledToFill().frame(width:geometry.size.width,height:geometry.size.height).clipped()
                    #else
                    Image(uiImage:image).resizable().scaledToFill().frame(width:geometry.size.width,height:geometry.size.height).clipped()
                    #endif
                } else {
                    Rectangle().fill(style == .plain ? AnyShapeStyle(tone) : AnyShapeStyle(tone.gradient))
                    VStack(alignment:.leading,spacing:12) {
                        if style == .standard { Rectangle().fill(.white.opacity(0.45)).frame(width:22,height:1) }
                        Text(book.title).font(.system(size:max(style == .plain ? 10 : 13,geometry.size.width * (style == .plain ? 0.10 : 0.12)),weight:.medium,design:.serif))
                            .lineLimit(5).minimumScaleFactor(0.7)
                        Spacer(minLength:0)
                        Text(book.displayAuthor).font(.system(size:max(8,geometry.size.width * 0.052))).lineLimit(2).opacity(0.65)
                    }.padding(geometry.size.width * (style == .plain ? 0.12 : 0.14)).foregroundStyle(.white.opacity(0.92))
                }
                if style == .plain { Rectangle().fill(.black.opacity(0.08)).frame(width:3) }
                else { LinearGradient(colors:[.black.opacity(0.22),.white.opacity(0.12),.clear],startPoint:.leading,endPoint:.trailing).frame(width:9) }
            }
            .clipShape(RoundedRectangle(cornerRadius:3))
            .overlay(RoundedRectangle(cornerRadius:3).strokeBorder(.black.opacity(0.08),lineWidth:0.5))
        }.aspectRatio(0.69,contentMode:.fit)
            .shadow(color:.black.opacity(style == .plain ? 0.06 : 0.12),radius:style == .plain ? 3 : 6,x:1,y:style == .plain ? 2 : 4)
            .accessibilityHidden(true)
    }
}

struct ReadingAppearanceView: View {
    @ObservedObject var reader: ReaderModel
    @State private var advanced = false
    var body: some View {
        VStack(alignment:.leading,spacing:20) {
            Text("阅读外观").font(.headline)
                Picker("查看模式",selection:$reader.appearance.mode) {
                    Text("连续滚动").tag(ReadingMode.scroll)
                    Text("分页阅读").tag(ReadingMode.paged)
                }.pickerStyle(.segmented)
            HStack(spacing:18) {
                theme("paper","纸色",Color(red:242/255,green:227/255,blue:200/255))
                theme("light","白色",.white)
                theme("night","夜间",Color(red:0.125,green:0.153,blue:0.145))
            }.frame(maxWidth:.infinity)
            PDFLayoutControls(reader:reader)
            if let pdf = reader.pdfBookReader, !reader.isPDFTextLayout {
                HStack(spacing:14) {
                    Button("缩小",systemImage:"minus.magnifyingglass") { pdf.zoom(by:0.85) }
                    Button("放大",systemImage:"plus.magnifyingglass") { pdf.zoom(by:1.18) }
                }.frame(maxWidth:.infinity)
            } else {
                Picker("字体",selection:$reader.appearance.font) {
                    Text("苹方").tag("pingfang"); Text("宋体").tag("serif"); Text("黑体").tag("sans"); Text(reader.isPDFTextLayout ? "系统默认" : "原书").tag("publisher")
                }.pickerStyle(.segmented)
                HStack(spacing:16) {
                    Image(systemName:"textformat.size.smaller")
                    Slider(value:$reader.appearance.fontSize,in:14...36,step:1).accessibilityLabel("字号")
                    Text("\(Int(reader.appearance.fontSize))").font(.callout.monospacedDigit()).frame(width:28)
                    Image(systemName:"textformat.size.larger")
                }
            }
            DisclosureGroup("更多排版",isExpanded:$advanced) {
                VStack(spacing:14) {
                    if reader.supportsReflow || reader.isPDFTextLayout {
                        HStack { Text("行距").font(.callout); Slider(value:$reader.appearance.lineHeight,in:1.3...2.4,step:0.05).accessibilityLabel("行距") }
                    }
                    HStack { Text("左右留白").font(.callout); Slider(value:$reader.appearance.sideInset,in:0...30,step:1).accessibilityLabel("左右留白"); Text("\(Int(reader.appearance.sideInset))%").font(.caption.monospacedDigit()).frame(width:34) }
                    Button("恢复默认排版") { reader.appearance = ReaderAppearance() }.frame(maxWidth:.infinity,alignment:.leading)
                }.padding(.top,12)
            }.font(.callout)

        }.padding(24).tint(readingAccent)
    }
    private func theme(_ key: String,_ label: String,_ color: Color) -> some View {
        Button { reader.appearance.theme = key } label: {
            VStack(spacing:8) {
                Circle().fill(color).frame(width:44,height:44)
                    .overlay(Circle().strokeBorder(reader.appearance.theme == key ? readingAccent : Color.gray.opacity(0.3),lineWidth:reader.appearance.theme == key ? 2 : 0.5))
                Text(label).font(.caption)
            }
        }.buttonStyle(.plain).accessibilityLabel(label).accessibilityAddTraits(reader.appearance.theme == key ? .isSelected : [])
    }
}
