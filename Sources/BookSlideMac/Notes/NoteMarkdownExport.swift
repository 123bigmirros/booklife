import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif
#if canImport(BookSlideCore)
import BookSlideCore
#endif

enum NoteMarkdownExport {
    static func safeFilename(_ title: String) -> String {
        let name = title.components(separatedBy:CharacterSet(charactersIn:"/\\:\n\r\t")).joined(separator:" ").trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn:".")))
        return name.isEmpty || name == "." || name == ".." ? "读书笔记" : String(name.prefix(90))
    }
    private static func heading(_ text: String) -> String {
        text.replacingOccurrences(of:"\r",with:" ").replacingOccurrences(of:"\n",with:" ").replacingOccurrences(of:"#",with:"\\#")
    }
    static func render(_ records: [LibraryNoteRecord], title: String, assetsFolder: String? = nil) -> String {
        let ordered = LibraryNotes.filtered(records,byPosition:true)
        let selectedIDs = Set(records.map(\.id))
        var lines = ["# " + heading(title), "", "共 \(Set(records.map { $0.book.id }).count) 本书 · \(records.count) 条记录", ""]
        var previousBook: UUID?
        for record in ordered {
            if previousBook != record.book.id {
                previousBook = record.book.id
                lines += ["## " + heading(record.book.title), "", "作者：" + heading(record.book.author), ""]
            }
            lines += ["<a id=\"note-\(record.book.id.uuidString)-\(record.note.id)\"></a>", "", "### " + heading(record.note.title), "",
                      "\(record.kind) · \(heading(record.note.chapter)) · 书中 \(Int(record.note.progress*100))%", ""]
            if !record.note.quote.isEmpty {
                lines += record.note.quote.components(separatedBy:.newlines).map { "> " + $0 }
                lines.append("")
            }
            if !record.note.text.isEmpty { lines += [record.note.text, ""] }
            if let parent = record.note.responseToID {
                let parentID = record.book.id.uuidString + "/" + parent
                if selectedIDs.contains(parentID) { lines += ["回应：[原疑问](#note-\(record.book.id.uuidString)-\(parent))", ""] }
                else { lines += ["回应原疑问（原疑问未包含在本次导出中）。", ""] }
            }
            if !record.aliases.isEmpty { lines += ["关联：" + Array(Set(record.aliases)).sorted().joined(separator:"、"), ""] }
            for asset in record.inkAssetIDs {
                if let assetsFolder {
                    let path = assetsFolder + "/" + asset.uuidString + ".png"
                    let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn:"()#?"))
                    lines += ["![书页手写](\(path.addingPercentEncoding(withAllowedCharacters:allowed) ?? path))", ""]
                } else { lines += ["书页手写：请在书籍人生中查看原页与笔迹。", ""] }
            }
            lines += ["<!-- BookSlide \(record.id) -->", ""]
        }
        return lines.joined(separator:"\n")
    }
    static func write(_ records: [LibraryNoteRecord], title: String, to url: URL, libraryDirectory: URL) throws {
        let assets = records.flatMap(\.inkAssetIDs)
        let folder = url.deletingPathExtension().lastPathComponent + "-assets"
        if !assets.isEmpty {
            let destination = url.deletingLastPathComponent().appendingPathComponent(folder,isDirectory:true)
            try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
            let store = ReaderPageNoteStore(libraryDirectory:libraryDirectory)
            for asset in Set(assets) {
                let data = try inkImage(asset,records:records,store:store)
                try data.write(to:destination.appendingPathComponent(asset.uuidString + ".png"),options:.atomic)
            }
        }
        try render(records,title:title,assetsFolder:assets.isEmpty ? nil : folder).write(to:url,atomically:true,encoding:.utf8)
    }
    static func inkImage(_ asset: UUID,records: [LibraryNoteRecord],store: ReaderPageNoteStore) throws -> Data {
        if let part=records.flatMap(\.inkParts).first(where:{ $0.assetID==asset }) {
            let b=part.bounds,a=part.anchor
            return try store.croppedPreview(asset,rect:.init(x:b.x/a.viewportWidth,y:b.y/a.viewportHeight,width:b.width/a.viewportWidth,height:b.height/a.viewportHeight))
        }
        return try store.image(asset,name:"preview.png")
    }
}

struct NoteMarkdownDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(importedAs:"net.daringfireball.markdown",conformingTo:.plainText)] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding:configuration.file.regularFileContents ?? Data(),as:UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:Data(text.utf8)) }
}

/// A standard uncompressed ZIP preserves the Markdown and its relative image
/// links when iPad users save or share a handwriting export through Files.
enum NoteExportArchive {
    private static let crcTable: [UInt32] = (0..<256).map { byte in
        var value = UInt32(byte)
        for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb88320 : 0) }
        return value
    }
    static func make(_ records: [LibraryNoteRecord], title: String, libraryDirectory: URL) throws -> Data {
        var files: [(String,Data)] = [(NoteMarkdownExport.safeFilename(title) + ".md", Data(NoteMarkdownExport.render(records,title:title,assetsFolder:"assets").utf8))]
        let store = ReaderPageNoteStore(libraryDirectory:libraryDirectory)
        for asset in Set(records.flatMap(\.inkAssetIDs)).sorted(by: { $0.uuidString < $1.uuidString }) {
            files.append(("assets/" + asset.uuidString + ".png",try NoteMarkdownExport.inkImage(asset,records:records,store:store)))
        }
        guard files.count <= Int(UInt16.max), files.reduce(0,{ $0 + $1.1.count }) < 512*1024*1024 else {
            throw NSError(domain:"BookSlide.Export",code:1,userInfo:[NSLocalizedDescriptionKey:"导出内容较大，请分批选择笔记。"])
        }
        func crc32(_ data: Data) -> UInt32 {
            var value = UInt32.max
            for byte in data {
                value = (value >> 8) ^ crcTable[Int((value ^ UInt32(byte)) & 0xff)]
            }
            return value ^ UInt32.max
        }
        func word(_ value: UInt16) -> Data { var n = value.littleEndian; return withUnsafeBytes(of:&n) { Data($0) } }
        func long(_ value: UInt32) -> Data { var n = value.littleEndian; return withUnsafeBytes(of:&n) { Data($0) } }
        var result = Data(), central = Data()
        for (name,data) in files {
            let filename = Data(name.utf8), size = UInt32(data.count), checksum = crc32(data), offset = UInt32(result.count)
            for part in [long(0x04034b50),word(20),word(0x800),word(0),word(0),word(0x21),long(checksum),long(size),long(size),word(UInt16(filename.count)),word(0),filename,data] { result.append(part) }
            for part in [long(0x02014b50),word(20),word(20),word(0x800),word(0),word(0),word(0x21),long(checksum),long(size),long(size),word(UInt16(filename.count)),word(0),word(0),word(0),word(0),long(0),long(offset),filename] { central.append(part) }
        }
        let offset = UInt32(result.count)
        result += central
        for part in [long(0x06054b50),word(0),word(0),word(UInt16(files.count)),word(UInt16(files.count)),long(UInt32(central.count)),long(offset),word(0)] { result.append(part) }
        return result
    }
}

struct NoteArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zip] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents:data) }
}

struct NoteExportButton: View {
    @ObservedObject var reader: ReaderModel
    let records: [LibraryNoteRecord]
    let title: String
    var compact = false
    @State private var exporting = false
    @State private var failure: String?
    @State private var message: String?
    @State private var document = NoteMarkdownDocument(text:"")
    @State private var exportingArchive = false
    @State private var archive = NoteArchiveDocument(data:Data())
    var body: some View {
        Button(action:primaryExport) { Label(compact ? "导出此条" : "导出 Markdown",systemImage:"square.and.arrow.up") }
            .buttonStyle(.borderless).disabled(records.isEmpty)
            .help("导出当前筛选的 \(records.count) 条记录")
            .contextMenu { Button("选择保存位置…",action:export) }
            .alert("导出未完成",isPresented:Binding(get:{failure != nil},set:{if !$0 { failure = nil }})) { Button("好") { failure = nil } } message: { Text(failure ?? "") }
            .alert("已导出",isPresented:Binding(get:{message != nil},set:{if !$0 { message = nil }})) { Button("好") { message = nil } } message: { Text(message ?? "") }
            #if !os(macOS)
            .fileExporter(isPresented:$exporting,document:document,contentType:NoteMarkdownDocument.readableContentTypes[0],defaultFilename:NoteMarkdownExport.safeFilename(title)) { result in
                if case .failure(let error) = result { failure = error.localizedDescription }
                else { message = "\(records.count) 条记录已导出。" }
            }
            .fileExporter(isPresented:$exportingArchive,document:archive,contentType:.zip,defaultFilename:NoteMarkdownExport.safeFilename(title)) { result in
                if case .failure(let error) = result { failure = error.localizedDescription }
                else { message = "笔记和手写图片已导出，解压后打开 Markdown 即可查看。" }
            }
            #endif
    }
    private func primaryExport() {
        #if os(macOS)
        do {
            let directory: URL
            #if DEBUG
            if let preview = Bundle.main.object(forInfoDictionaryKey:"BookSlidePreviewLibrary") as? String {
                directory = URL(fileURLWithPath:preview).deletingLastPathComponent()
            } else { directory = FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0] }
            #else
            directory = FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask)[0]
            #endif
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let name = NoteMarkdownExport.safeFilename(title)
            var url = directory.appendingPathComponent(name + ".md"), counter = 2
            while FileManager.default.fileExists(atPath:url.path) {
                url = directory.appendingPathComponent(name + "-\(counter).md"); counter += 1
            }
            try NoteMarkdownExport.write(records,title:title,to:url,libraryDirectory:reader.directory)
            message = "\(records.count) 条记录已保存到\n\(url.path)"
        } catch { failure = error.localizedDescription }
        #else
        export()
        #endif
    }
    private func export() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps:true)
        let panel = NSSavePanel()
        // Use the declared Markdown type rather than a dynamic extension lookup.
        panel.allowedContentTypes = NoteMarkdownDocument.readableContentTypes
        panel.allowsOtherFileTypes = true
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = NoteMarkdownExport.safeFilename(title) + ".md"
        panel.prompt = "导出"
        panel.message = "导出 \(records.count) 条记录，保留摘录、想法与出处。手写图片保存在旁边的素材文件夹中。"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try NoteMarkdownExport.write(records,title:title,to:url,libraryDirectory:reader.directory)
                message = "\(records.count) 条记录已保存到「\(url.lastPathComponent)」。"
            } catch { failure = error.localizedDescription }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
            panel.beginSheetModal(for:window,completionHandler:completion)
        }
        else { panel.begin(completionHandler:completion) }
        #else
        do {
            if records.contains(where:{ $0.inkAssetID != nil }) {
                archive = NoteArchiveDocument(data:try NoteExportArchive.make(records,title:title,libraryDirectory:reader.directory))
                exportingArchive = true
            } else {
                document = NoteMarkdownDocument(text:NoteMarkdownExport.render(records,title:title))
                exporting = true
            }
        } catch { failure = error.localizedDescription }
        #endif
    }
}
