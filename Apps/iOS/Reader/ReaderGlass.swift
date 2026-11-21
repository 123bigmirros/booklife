import SwiftUI
import UIKit

/// Glass belongs to floating controls, leaving the book's viewport untouched.
struct ReaderGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(Color(uiColor:.secondarySystemBackground),in:shape)
        } else if #available(iOS 26.0, *) {
            // Keep the optical layer behind the controls. Applying glass to
            // their container can intercept embedded button and editor input.
            content.background {
                Color.clear.glassEffect(.regular,in:shape)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        } else {
            content.background(.ultraThinMaterial,in:shape)
                .overlay(shape.stroke(.white.opacity(0.22),lineWidth:0.5).allowsHitTesting(false))
        }
    }
}

/// Let iPadOS supply its native glass popover instead of overriding its material.
struct ReaderPanelMaterial: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 26.0, *) { content }
        else { content.presentationBackground(.regularMaterial) }
    }
}

struct ReaderInkToolbar: View {
    @ObservedObject var reader: ReaderModel
    var body: some View {
        VStack(spacing:4) {
            HStack(spacing:0) {
                ForEach([ReaderInkTool.pen,.eraser,.reading],id:\.self) { tool in
                    Button { reader.selectInkTool(tool) } label: {
                        VStack(spacing:4) { Image(systemName:tool.symbol).font(.system(size:18)); Text(tool.title).font(.system(size:12,weight:.medium)) }
                            .frame(width:82,height:50)
                            .background(reader.inlineInkTool == tool ? readingAccent.opacity(0.16) : .clear,in:RoundedRectangle(cornerRadius:12))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Pencil \(tool.title)模式")
                        .accessibilityIdentifier("reader-pencil-mode-" + tool.rawValue)
                        .accessibilityAddTraits(reader.inlineInkTool == tool ? .isSelected : [])
                }
                Menu {
                    Button("荧光笔",systemImage:"highlighter") { reader.selectInkTool(.marker) }
                    Button("套索",systemImage:"lasso") { reader.selectInkTool(.lasso) }
                    Divider()
                    Button("撤销笔迹",systemImage:"arrow.uturn.backward") { reader.inlineInk?.undo() }.disabled(!reader.inlineInkCanUndo)
                    Button("重做笔迹",systemImage:"arrow.uturn.forward") { reader.inlineInk?.redo() }.disabled(!reader.inlineInkCanRedo)
                } label: { Image(systemName:"ellipsis").frame(width:36,height:44) }.accessibilityLabel("更多画笔工具")
                Button { reader.beginPageHandwriting() } label: { Image(systemName:"xmark").frame(width:36,height:44) }.accessibilityLabel("收起 Pencil 工具")
            }
            Divider().padding(.horizontal,8)
            if reader.inlineInkTool == .pen || reader.inlineInkTool == .marker {
            HStack(spacing:0) {
                ForEach(ReaderInkColor.allCases,id:\.self) { color in
                    Button { reader.inlineInkColor = color } label: {
                        Circle().fill(color.color(appearance:reader.appearance)).frame(width:23,height:23)
                            .overlay {
                                if reader.inlineInkColor == color {
                                    Circle().stroke(reader.appearance.ink.opacity(0.65),lineWidth:1).padding(-4)
                                }
                            }.frame(width:40,height:44).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(color.title)
                        .accessibilityAddTraits(reader.inlineInkColor == color ? .isSelected : [])
                }
                Spacer(minLength:4)
                Menu {
                    ForEach([CGFloat(1.5),3,5],id:\.self) { width in
                        Button {
                            reader.inlineInkWidth = width
                        } label: {
                            if reader.inlineInkWidth == width { Label(width == 1.5 ? "细" : width == 3 ? "中" : "粗",systemImage:"checkmark") }
                            else { Text(width == 1.5 ? "细" : width == 3 ? "中" : "粗") }
                        }
                    }
                } label: {
                    HStack(spacing:6) {
                        Image(systemName:"lineweight")
                        Text(reader.inlineInkWidth == 1.5 ? "细" : reader.inlineInkWidth == 3 ? "中" : "粗").font(.caption)
                    }.frame(minWidth:80,minHeight:44)
                }.accessibilityLabel("笔画粗细")
                    .disabled(reader.inlineInkTool == .eraser || reader.inlineInkTool == .lasso)
            }.padding(.horizontal,6)
            }
            Text(UIDevice.current.userInterfaceIdiom == .pad ? "双击切笔与橡皮 · 侧捏切书写与阅读" : "用手指书写 · 阅读模式可滑动和选字")
                .font(.system(size:11)).foregroundStyle(.secondary).padding(.bottom,8)
        }.padding(8).frame(width:344)
            .foregroundStyle(reader.appearance.ink)
            .modifier(ReaderGlassSurface(shape:RoundedRectangle(cornerRadius:24)))
            .onChange(of:reader.inlineInkTool) { _,_ in reader.inlineInk?.updateTools() }
            .onChange(of:reader.inlineInkColor) { _,_ in reader.inlineInk?.updateTools() }
            .onChange(of:reader.inlineInkWidth) { _,_ in reader.inlineInk?.updateTools() }
    }
    private func button(_ symbol: String,_ title: String,selected: Bool = false,action: @escaping () -> Void) -> some View {
        Button(action:action) {
            Image(systemName:symbol).font(.system(size:18))
                .frame(width:44,height:44)
                .background(selected ? reader.appearance.ink.opacity(0.10) : .clear,in:Circle())
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct ReaderGlassPanelKey: EnvironmentKey { static let defaultValue = false }
private struct ReaderPanelBackKey: EnvironmentKey { static let defaultValue: (() -> Void)? = nil }
extension EnvironmentValues {
    var readerGlassPanel: Bool {
        get { self[ReaderGlassPanelKey.self] }
        set { self[ReaderGlassPanelKey.self] = newValue }
    }
    var readerPanelBack: (() -> Void)? {
        get { self[ReaderPanelBackKey.self] }
        set { self[ReaderPanelBackKey.self] = newValue }
    }
}

/// UIKit reports the actual end of dismissal before another editor is opened.
@MainActor final class ReaderPanelPresentation: ObservableObject {
    weak var controller: UIViewController?
    func dismiss(completion: @escaping () -> Void) -> Bool {
        guard var presented = controller else { return false }
        while let parent = presented.parent { presented = parent }
        guard presented.presentingViewController != nil, !presented.isBeingDismissed else { return false }
        presented.dismiss(animated:true,completion:completion)
        return true
    }
}

struct ReaderPopoverLifecycle: UIViewControllerRepresentable {
    let dismissed: () -> Void
    var presentation: ReaderPanelPresentation? = nil
    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller(dismissed:dismissed)
        presentation?.controller = controller
        return controller
    }
    func updateUIViewController(_ controller: Controller,context: Context) {
        controller.dismissed = dismissed; presentation?.controller = controller
    }
    final class Controller: UIViewController {
        var dismissed: () -> Void
        init(dismissed: @escaping () -> Void) { self.dismissed = dismissed; super.init(nibName:nil,bundle:nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func loadView() { view = UIView(); view.backgroundColor = .clear; view.isUserInteractionEnabled = false }
        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            dismissed()
        }
    }
}

enum ReaderMenuDestination { case contents, search, appearance, progress, watch, sync }
enum ReaderMenuAction { case note, graph, handwriting, drafts, originalPage }

struct ReaderMenuPanel: View {
    @ObservedObject var reader: ReaderModel
    let navigate: (ReaderMenuDestination) -> Void
    let perform: (ReaderMenuAction) -> Void
    let close: () -> Void
    @Environment(\.dismiss) private var dismiss
    private var tile: Color { Color.primary.opacity(0.055) }
    var body: some View {
        ScrollView {
            VStack(spacing:8) {
                Button { navigate(.contents) } label: {
                    HStack(spacing:8) {
                        Text("目录与书签")
                        if let position = reader.position {
                            Text("· \(Int(position.progress*100))%")
                                .foregroundStyle(.white.opacity(0.65)).monospacedDigit()
                        }
                        Spacer(minLength:4)
                        Image(systemName:"list.bullet").font(.system(size:20))
                    }.font(.subheadline).foregroundStyle(.white)
                        .padding(.horizontal,16).frame(minHeight:48)
                        .background(Color(white:0.20),in:RoundedRectangle(cornerRadius:14))
                        .contentShape(RoundedRectangle(cornerRadius:14))
                }.buttonStyle(.plain).accessibilityLabel("目录与书签")
                row("搜索书中内容",symbol:"magnifyingglass") { navigate(.search) }
                row("主题与排版",symbol:"textformat.size") { navigate(.appearance) }
                HStack(spacing:8) {
                    noteButton("随手记",symbol:"square.and.pencil",label:"随手记") { perform(.note) }
                    noteButton("脉络与笔记",symbol:"point.3.connected.trianglepath.dotted",label:"全书脉络与笔记") { perform(.graph) }
                }.padding(.top,4)
                HStack(spacing:8) {
                    Button { reader.toggleBookmark() } label: {
                        Image(systemName:reader.isBookmarked ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(reader.isBookmarked ? readingAccent : .primary)
                            .frame(maxWidth:.infinity,minHeight:44).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(tile,in:RoundedRectangle(cornerRadius:14))
                        .disabled(reader.loading || reader.busy || reader.position == nil)
                        .accessibilityLabel(reader.isBookmarked ? "移除书签" : "添加书签")
                        .accessibilityAddTraits(reader.isBookmarked ? .isSelected : [])
                    Menu {
                        Button(reader.inlineInkToolsVisible ? "收起画笔工具" : "显示画笔工具",systemImage:"pencil.tip.crop.circle") { perform(.handwriting) }
                        if reader.recoverableNoteDraftCount > 0 || !reader.removedNotes.isEmpty {
                            Button(reader.recoverableNoteDraftCount > 0 ? "草稿与最近删除" : "最近删除",systemImage:"clock.arrow.circlepath") { perform(.drafts) }
                        }
                        if !reader.hiddenPageNoteIDs.isEmpty {
                            Button("查看此处手写的原页",systemImage:"doc.richtext") { perform(.originalPage) }
                        }
                        if let id = reader.noteUndoID {
                            Button("撤销刚才的移除",systemImage:"arrow.uturn.backward") { reader.restoreRemovedNote(id) }
                        }
                        Divider()
                        Button("阅读进度",systemImage:"slider.horizontal.3") { navigate(.progress) }
                        Button("手表遥控",systemImage:"applewatch") { navigate(.watch) }
                        Button("阅读进度同步",systemImage:"icloud") { navigate(.sync) }
                    } label: {
                        Image(systemName:"ellipsis").frame(maxWidth:.infinity,minHeight:44).contentShape(Rectangle())
                    }.background(tile,in:RoundedRectangle(cornerRadius:14))
                        .accessibilityLabel("更多阅读选项")
                    Button { close(); dismiss() } label: {
                        Image(systemName:"xmark").font(.system(size:16,weight:.medium))
                            .frame(maxWidth:.infinity,minHeight:44).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(tile,in:RoundedRectangle(cornerRadius:14))
                        .accessibilityLabel("关闭面板，继续阅读")
                        .accessibilityIdentifier("reader-panel-close").keyboardShortcut(.cancelAction)
                }.font(.system(size:20)).padding(.top,4)
            }.padding(12)
        }.scrollBounceBehavior(.basedOnSize).foregroundStyle(.primary)
    }
    private func row(_ title: String,symbol: String,action: @escaping () -> Void) -> some View {
        Button(action:action) {
            HStack(spacing:12) {
                Text(title).font(.subheadline)
                Spacer(minLength:0)
                Image(systemName:symbol).font(.system(size:20)).frame(width:26)
            }.padding(.horizontal,16).frame(minHeight:48)
                .background(tile,in:RoundedRectangle(cornerRadius:14))
                .contentShape(RoundedRectangle(cornerRadius:14))
        }.buttonStyle(.plain)
    }
    private func noteButton(_ title: String,symbol: String,label: String,action: @escaping () -> Void) -> some View {
        Button(action:action) {
            VStack(spacing:7) {
                Image(systemName:symbol).font(.system(size:20))
                Text(title).font(.footnote).lineLimit(1).minimumScaleFactor(0.8)
            }.frame(maxWidth:.infinity,minHeight:64)
                .background(tile,in:RoundedRectangle(cornerRadius:14))
                .contentShape(RoundedRectangle(cornerRadius:14))
        }.buttonStyle(.plain).accessibilityLabel(label)
    }
}

struct ReaderProgressPanel: View {
    @ObservedObject var reader: ReaderModel
    let seek: (Double) -> Void
    let close: () -> Void
    @State private var progress = 0.0
    @State private var dragging = false
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            ReaderPanelHeader(title:"阅读进度",subtitle:reader.position?.chapter,close:close)
                .padding(.horizontal,-22).padding(.top,-16)
            HStack(alignment:.firstTextBaseline) {
                Text("\(Int((dragging ? progress : reader.position?.progress ?? 0)*100))%")
                    .font(.system(.largeTitle,design:.rounded).weight(.light)).monospacedDigit()
                Spacer()
                Text(dragging ? "松手跳转" : "已读全书").font(.caption).foregroundStyle(.secondary)
            }
            Slider(value:Binding(get:{ dragging ? progress : reader.position?.progress ?? 0 },set:{ value in
                progress = value
                // VoiceOver and accessibility adjustments do not necessarily
                // begin a touch drag, so commit those changes here as well.
                if !dragging { seek(value) }
            }),in:0...1) { editing in
                if editing { progress = reader.position?.progress ?? 0 }
                dragging = editing
                if !editing { seek(progress) }
            }.disabled(!reader.locationsReady || reader.busy || reader.handwritingActive)
                .accessibilityLabel("全书阅读进度").accessibilityValue("已读 \(Int((dragging ? progress : reader.position?.progress ?? 0)*100))%")
            HStack { Text("开始"); Spacer(); Text("读完") }.font(.caption2).foregroundStyle(.secondary)
        }.padding(22)
    }
}
