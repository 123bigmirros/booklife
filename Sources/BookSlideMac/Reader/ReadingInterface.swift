import SwiftUI
#if canImport(BookSlideCore)
import BookSlideCore
#endif

/// Shared chrome for the reading graph's notes, interpretations and nodes.
/// Content stays on paper; floating creation sheets keep the system material.
enum ReadingInterface {
    static let inset: CGFloat = 20
    static let sheetInset: CGFloat = 24
    static let radius: CGFloat = 14
    static let control: CGFloat = 44
}

/// Reading editors contribute their own title and actions to one header.
/// The workspace adds navigation here instead of stacking a second toolbar.
struct ReadingCompanionChrome {
    let tools: AnyView
    let ink: Color
}
private struct ReadingGraphAccentKey: EnvironmentKey {
    static let defaultValue: Color? = nil
}
private struct ReadingCompanionChromeKey: EnvironmentKey {
    static let defaultValue: ReadingCompanionChrome? = nil
}
extension EnvironmentValues {
    var readingGraphAccent: Color? {
        get { self[ReadingGraphAccentKey.self] }
        set { self[ReadingGraphAccentKey.self] = newValue }
    }
    var readingCompanionChrome: ReadingCompanionChrome? {
        get { self[ReadingCompanionChromeKey.self] }
        set { self[ReadingCompanionChromeKey.self] = newValue }
    }
}

struct ReadingToolButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action:action) {
            Image(systemName:symbol).font(.system(size:16,weight:.medium))
                .frame(width:ReadingInterface.control,height:ReadingInterface.control)
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.primary).opacity(enabled ? 1 : 0.35).accessibilityLabel(label)
    }
}

struct ReadingEditorHeader<Actions: View>: View {
    let title: String
    let symbol: String
    var status: String? = nil
    var statusID = ""
    var titleID = ""
    var back: (() -> Void)? = nil
    var backLabel = "返回图中"
    var discussionMode: Binding<Bool>? = nil
    @ViewBuilder var actions: () -> Actions
    @Environment(\.readingCompanionChrome) private var companion
    var body: some View {
        HStack(spacing:8) {
            if let back { ReadingToolButton(symbol:"chevron.left",label:backLabel,action:back) }
            if let discussionMode {
                HStack(spacing:16) {
                    modeButton("笔记",label:"我的笔记",value:false,binding:discussionMode)
                    modeButton("AI 对话",label:"AI 对话",value:true,binding:discussionMode)
                }
            } else {
                Group {
                    if back != nil || companion != nil { Text(title) }
                    else { Label(title,systemImage:symbol) }
                }.font(.system(size:16,weight:.semibold)).lineLimit(1)
                    .accessibilityAddTraits(.isHeader).accessibilityIdentifier(titleID)
            }
            Spacer(minLength:4)
            if let status, companion == nil {
                Text(status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityIdentifier(statusID)
            }
            actions()
            if let companion { companion.tools }
        }.frame(minHeight:ReadingInterface.control)
    }
    private func modeButton(_ title: String,label: String,value: Bool,binding: Binding<Bool>) -> some View {
        Button { binding.wrappedValue = value } label: {
            VStack(spacing:5) {
                Text(title).font(.system(size:15,weight:binding.wrappedValue == value ? .semibold : .regular)).lineLimit(1)
                Capsule().fill(.primary.opacity(binding.wrappedValue == value ? 0.65 : 0)).frame(width:18,height:1.5)
            }.frame(minHeight:44).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(binding.wrappedValue == value ? .primary : .secondary)
            .accessibilityLabel(label).accessibilityAddTraits(binding.wrappedValue == value ? .isSelected : [])
    }
}

struct ReadingCardSurface: ViewModifier {
    var emphasized = false
    func body(content: Content) -> some View {
        content.padding(14).frame(maxWidth:.infinity,alignment:.leading)
            .background(.primary.opacity(emphasized ? 0.055 : 0.035),in:RoundedRectangle(cornerRadius:ReadingInterface.radius))
    }
}

struct ReadingFieldSurface: ViewModifier {
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size:16))
            .padding(.horizontal,12).frame(minHeight:ReadingInterface.control)
            .background(.background.opacity(0.65),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(.primary.opacity(0.08),lineWidth:0.75).allowsHitTesting(false))
    }
}

struct ReadingPrimaryAction: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.readingGraphAccent) private var accent
    var compact = false
    @Environment(\.readingCompanionChrome) private var companion
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder func body(content: Content) -> some View {
        if compact {
            content.buttonStyle(ReadingCompactPrimaryButtonStyle(ink:accent ?? companion?.ink ?? readingAccent,
                foreground:(accent != nil || companion != nil) && colorScheme == .dark ? .black : .white))
        } else if let preferred = accent ?? companion?.ink {
            styled(content).tint(preferred)
                .foregroundStyle(enabled ? (colorScheme == .dark ? Color.black : Color.white) : Color.secondary)
        } else { styled(content).tint(readingAccent) }
    }
    private func styled(_ content: Content) -> some View {
        content.font(.system(size:15,weight:.medium)).buttonStyle(.borderedProminent)
            .controlSize(.large)
            #if os(iOS)
            .buttonBorderShape(.capsule)
            #endif
    }
}

private struct ReadingCompactPrimaryButtonStyle: ButtonStyle {
    let ink: Color
    let foreground: Color
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size:14,weight:.semibold)).foregroundStyle(foreground)
            .padding(.horizontal,14).frame(minHeight:44)
            .background(ink,in:RoundedRectangle(cornerRadius:10))
            .contentShape(RoundedRectangle(cornerRadius:10))
            .opacity(!enabled ? 0.3 : configuration.isPressed ? 0.75 : 1)
    }
}

struct ReadingCreationFooter<Action: View>: View {
    let hint: String
    @ViewBuilder var action: () -> Action
    var body: some View {
        HStack(spacing:16) {
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Spacer(minLength:0)
            action().modifier(ReadingPrimaryAction())
        }.frame(minHeight:ReadingInterface.control)
    }
}

struct ReadingSourceCard: View {
    var chapter: String? = nil
    let text: String
    var lineLimit: Int? = 4
    var textID = ""
    var body: some View {
        HStack(alignment:.top,spacing:12) {
            RoundedRectangle(cornerRadius:1).fill(.primary.opacity(0.18)).frame(width:2)
            VStack(alignment:.leading,spacing:8) {
                if let chapter, !chapter.isEmpty { Text(chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(text).font(.system(size:16,design:.serif)).lineSpacing(5).lineLimit(lineLimit).textSelection(.enabled)
                    .accessibilityIdentifier(textID)
            }.frame(maxWidth:.infinity,alignment:.leading)
        }.fixedSize(horizontal:false,vertical:true).padding(.vertical,6)
    }
}

struct ReadingNodeComposerHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat,nextValue: () -> CGFloat) { value = max(value,nextValue()) }
}

/// A single input row; narrow windows can place the action beneath the name.
struct ReadingNodeComposer<Action: View>: View {
    @Binding var name: String
    @Binding var kind: BookEntityKind
    var placeholder = "名称"
    var accessibilityName = "节点名称"
    @ViewBuilder var action: () -> Action
    var body: some View {
        ViewThatFits(in:.horizontal) {
            HStack(alignment:.bottom,spacing:8) {
                nameField.frame(minWidth:120)
                kindPicker
                action().modifier(ReadingPrimaryAction(compact:true)).frame(minHeight:44)
            }
            VStack(alignment:.leading,spacing:10) {
                nameField
                HStack(alignment:.bottom) {
                    kindPicker
                    Spacer(minLength:8)
                    action().modifier(ReadingPrimaryAction(compact:true)).frame(minHeight:44)
                }
            }
        }
    }
    private var nameField: some View {
        VStack(alignment:.leading,spacing:4) {
            fieldLabel("名称")
            TextField(placeholder,text:$name).textFieldStyle(.plain).font(.system(size:17,weight:.medium))
                .padding(.horizontal,12).frame(minHeight:44)
                .background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
                .overlay(RoundedRectangle(cornerRadius:10).strokeBorder(.primary.opacity(0.08),lineWidth:0.5).allowsHitTesting(false))
                .accessibilityLabel(accessibilityName)
        }
    }
    private var kindPicker: some View {
        VStack(alignment:.leading,spacing:4) {
            fieldLabel("类型")
            Picker("类型",selection:$kind) {
                ForEach(BookEntityKind.allCases,id:\.self) { Text($0.title).tag($0) }
            }.pickerStyle(.menu).tint(.primary).font(.system(size:14))
                .padding(.horizontal,4).frame(minHeight:44)
                .background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:10))
                .accessibilityLabel("节点类型")
        }.fixedSize(horizontal:true,vertical:false)
    }
    private func fieldLabel(_ title: String) -> some View {
        Text(title).font(.caption2).foregroundStyle(.secondary).padding(.leading,4)
            .accessibilityHidden(true)
    }
}

struct ReadingEndpointCard: View {
    @Environment(\.readingGraphAccent) private var accent
    let role: String
    let title: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action:action) {
            VStack(alignment:.leading,spacing:5) {
                Text(role).font(.caption).foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.medium)).lineLimit(2)
                    .frame(maxWidth:.infinity,alignment:.leading)
            }.padding(12).frame(maxWidth:.infinity,minHeight:72,alignment:.leading)
                .background(.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:ReadingInterface.radius))
                .overlay(RoundedRectangle(cornerRadius:ReadingInterface.radius)
                    .strokeBorder(selected ? (accent ?? readingAccent).opacity(0.55) : .primary.opacity(0.08),lineWidth:0.75))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }
}

struct ReadingCreationSurface: ViewModifier {
    let floating: Bool
    let palette: BookGraphPalette
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        content.background(floating ? Color.clear : palette.paper)
        #else
        content.background(palette.paper)
        #endif
    }
}
