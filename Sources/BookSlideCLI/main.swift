import Foundation
import Darwin
import SystemConfiguration
import BookSlideTerminal
import BookSlideCore
import BookSlideTransport

let help = """
booklife — EPUB and PDF terminal reader

Usage: booklife [book.epub | book.pdf] [--no-remote] [--port 8766] [--mode scroll|paged]
       booklife --list
       booklife --help

↑/↓/j/k scroll one line   ←/→/Space/PageUp/PageDown move one screen
u continue shared progress   s sync now
m toggle scroll/pages   w text width   g line spacing   ? shortcuts
[/] chapter   c contents   b library   q quit
p pair iPhone   y confirm matching pairing code   n reject

Continuous scrolling is the default; m changes and saves the reading mode.
Uses your terminal's font and foreground/background colors.
Watch remote is enabled by default; --no-remote disables it. --remote remains supported.
EPUB images display inline in Ghostty, Kitty, iTerm2 and WezTerm.
BOOKSLIDE_IMAGES=kitty|iterm2|none overrides image detection.
Reading progress is shared with Mac and iPhone.
Configure an optional shared folder in the Mac app's Reading Progress Sync settings.
Without a path, select from Apple Books and booklife (recently read first).
--list lists the same library with titles and file paths.
"""

private struct ViewportImage: Equatable {
    let image: TerminalImage
    let screenRow: Int
    let firstRow: Int
    var count: Int
    let totalRows: Int
    let columns: Int
    var id: Int { 4_200_000 + screenRow }
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.image.id == rhs.image.id && lhs.screenRow == rhs.screenRow && lhs.firstRow == rhs.firstRow && lhs.count == rhs.count && lhs.totalRows == rhs.totalRows && lhs.columns == rhs.columns
    }
}
struct Location: Codable { var chapter: Int; var offset: Int }
final class TerminalReader {
    var mode = ReadingMode.scroll
    var widthStyle = TerminalWidth.standard, lineGap = 0
    var helpVisible = false, helpOffset = 0
    var book: TextBook
    var catalog: [CatalogBook] = [], choosingBook = false, selectedBook = 0, bookURL: URL?
    var pages: [TextPage] = [], index = 0, cols = 80, rows = 24, textWidth = 76
    var original = termios(), raw = false, sources: [DispatchSourceSignal] = []
    var input: DispatchSourceRead?, pendingInput = Data(), contents = false, selectedChapter = 0
    var notice = "", receiverID = UUID(), bookID = UUID(), sessionID = UUID(), token = "", port: UInt16
    var remoteStatus = "遥控未开启"
    var server: HTTPServer?, pairing: PairingCoordinator?, timer: Timer?
    private var bridgeServer: HTTPServer?, bridgeTimer: Timer?, bridgePort: UInt16?
    private let bridgeOwner = UUID()
    private var bridgeToken = ""
    let remote: Bool, stateDirectory: URL
    var unifiedStore: ProgressStore
    var progressDeviceID = UUID(), appliedProgressID: UUID?
    var pendingProgress: ReadingProgress?, progressSyncing = false
    var syncTimer: Timer?
    private var anchorIndexes: [Int:TextAnchorIndex] = [:]
    private var renderedLines: [Int:String] = [:]
    private var renderedScrollIndex: Int?
    private let imageProtocol = TerminalImageProtocol.detect()
    private var renderedImages: [ViewportImage] = []
    private var remoteMotion = TerminalScrollMotion()
    private var consumingInput = false
    private var progressWork: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label:"BookSlide.terminal.progress",qos:.utility)
    private var unsavedRecord: ReadingProgress?
    private var lastBridgeClaim = Date.distantPast
    var progressURL: URL
    init(url: URL?, remote: Bool, port: UInt16, mode: ReadingMode? = nil) throws {
        self.book = try url.map(TextBook.open) ?? TextBook(id:"library",title:"书库",chapters:[TextChapter(title:"",text:" ")])
        self.bookURL = url; self.choosingBook = url == nil
        self.remote = remote; self.port = port
        stateDirectory = ProcessInfo.processInfo.environment["BOOKSLIDE_TERMINAL_STATE_DIR"].map { URL(fileURLWithPath:$0,isDirectory:true) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/BookSlide/Terminal",isDirectory:true)
        unifiedStore = ProgressStore(directory:ProcessInfo.processInfo.environment["BOOKSLIDE_TERMINAL_STATE_DIR"] == nil ? ProgressStore.defaultDirectory : stateDirectory.appendingPathComponent("Progress"))
        try FileManager.default.createDirectory(at:stateDirectory,withIntermediateDirectories:true)
        let savedMode = (try? String(contentsOf:stateDirectory.appendingPathComponent("view-mode"))).flatMap(ReadingMode.init(rawValue:))
        self.mode = mode ?? savedMode ?? .scroll
        widthStyle = (try? String(contentsOf:stateDirectory.appendingPathComponent("text-width"))).flatMap(TerminalWidth.init(rawValue:)) ?? .standard
        lineGap = (try? String(contentsOf:stateDirectory.appendingPathComponent("line-gap"))) == "1" ? 1 : 0
        progressURL = stateDirectory.appendingPathComponent(book.id + ".json")
        catalog = try LibraryCatalog.allBooks()
        resize(saved:try? JSONDecoder().decode(Location.self,from:Data(contentsOf:progressURL)))
        progressDeviceID = try unifiedStore.deviceID(source:"terminal")
        if let url { restoreSharedOnOpen(); try LibraryCatalog.markRead(url,recentDirectory:stateDirectory) }
    }
    var bodyRows: Int { max(1,rows-8) }
    var readingRows: Int { max(1,rows-6) }
    var capacity: Int { max(1,(readingRows + lineGap)/(lineGap + 1)) }
    var lastIndex: Int { mode == .scroll ? max(0,pages.count-capacity) : max(0,pages.count-1) }
    var location: Location { Location(chapter:pages[index].chapter,offset:pages[index].offset) }
    var currentContentsIndex: Int {
        book.contents.lastIndex { TextLayout.pageIndex(pages,chapter:$0.chapter,offset:$0.offset) <= index } ?? 0
    }
    var currentChapterTitle: String { book.contents[currentContentsIndex].title }
    var contentAnchor: ContentAnchor {
        let position = location
        if anchorIndexes[position.chapter] == nil { anchorIndexes[position.chapter] = TextAnchorIndex(book.chapters[position.chapter].text) }
        return anchorIndexes[position.chapter]!.anchor(href:book.chapters[position.chapter].href,offset:position.offset)
    }
    var snapshot: ReadingSnapshot? {
        guard !choosingBook else { return nil }
        let page = pages[index]
        var snapshot = ReadingSnapshot(sessionID:sessionID,bookID:bookID,title:book.title,page:index+1,pageCount:pages.count,locator:"text:\(page.chapter):\(page.offset)",chapter:currentChapterTitle,progress:index == lastIndex ? 1 : (Double(book.chapters[page.chapter].spineIndex) + contentAnchor.fraction) / Double(max(1,book.spineCount)),canGoNext:index<lastIndex,canGoPrevious:index>0,readingMode:mode,readerName:"终端")
        snapshot.supportsFractionalScroll = true
        snapshot.maxScrollLines = 16
        return snapshot
    }
    func save() {
        guard !choosingBook else { return }
        progressWork?.cancel(); progressWork = nil
        let position = location, url = progressURL, bookURL = bookURL, directory = stateDirectory
        let record = unsavedRecord, store = unifiedStore
        unsavedRecord = nil
        saveQueue.async { [weak self] in
            do {
                try JSONEncoder().encode(position).write(to:url,options:.atomic)
                if let record { try store.merge([record]) }
                if let bookURL { try LibraryCatalog.markRead(bookURL,recentDirectory:directory) }
            } catch {
                DispatchQueue.main.async { self?.notice = "续读保存失败：\(error.localizedDescription)"; self?.draw() }
            }
        }
    }
    func resize(saved: Location? = nil) {
        stopRemoteScroll()
        if raw { for image in renderedImages { write(imageProtocol.delete(id:image.id)) } }
        renderedImages.removeAll()
        renderedLines.removeAll()
        renderedScrollIndex = nil
        if raw { write("\u{1B}[2J") }
        let anchor = saved ?? (pages.isEmpty ? Location(chapter:0,offset:0) : location)
        var size = winsize(); _ = ioctl(STDOUT_FILENO,TIOCGWINSZ,&size)
        cols = size.ws_col > 0 ? Int(size.ws_col) : 80; rows = size.ws_row > 0 ? Int(size.ws_row) : 24
        textWidth = widthStyle.columns(in:cols)
        let cellAspect = size.ws_xpixel > 0 && size.ws_ypixel > 0 ? Double(size.ws_xpixel)*Double(rows)/(Double(size.ws_ypixel)*Double(cols)) : 0.5
        pages = TextLayout.pages(book,columns:textWidth,rows:mode == .scroll ? 1 : capacity,images:imageProtocol != .none,imageMaxRows:max(1,min(16,capacity)),cellAspect:cellAspect/Double(lineGap+1))
        index = min(lastIndex,TextLayout.pageIndex(pages,chapter:anchor.chapter,offset:anchor.offset))
        if !choosingBook { _ = contentAnchor }
    }
    func write(_ value: String) { FileHandle.standardOutput.write(Data(value.utf8)) }
    var helpLines: [String] {
        ["阅读", "↑↓ / j k   逐行滚动或逐页翻动", "←→ / 空格  移动约一屏", "[ / ]      上一章 / 下一章", "c 目录    b 书库    q 退出", "",
         "外观 · 自动保存", "m  当前：\(mode == .scroll ? "滚动" : "分页") · 切换模式", "w  正文宽度：\(widthStyle.title)", "g  行距：\(lineGap == 0 ? "紧凑" : "舒展")", "",
         "插图：\(imageProtocol == .none ? "文字说明" : "终端图片")", "",
         "续读与遥控", "u  延续其他设备进度", "s  立即检查进度同步", remoteStatus, "p 配对    y 确认    n 取消"]
    }
    func draw() {
        guard raw, !consumingInput else { return }
        if Date().timeIntervalSince(lastBridgeClaim) >= 1 { updateBridge(claim:true); lastBridgeClaim = Date() }
        var output = "", nextLines: [Int:String] = [:], nextImages: [ViewportImage] = []
        // Chrome may be wider than compact prose, but never reaches the last cell.
        let frameWidth = max(1,min(cols-2,max(textWidth,min(100,cols-4))))
        func line(_ row: Int,_ text: String,_ style: String = "", prose: Bool = false) {
            guard row > 0, row <= rows else { return }
            let width = prose ? textWidth : frameWidth
            let value = prose ? TextLayout.clipped(TerminalTypography.singleLine(text),columns:width) : TerminalTypography.abbreviated(text,columns:width)
            nextLines[row] = "\u{1B}[\(max(1,(cols-width)/2+1))G" + (style.isEmpty ? "" : "\u{1B}[\(style)m") + value + "\u{1B}[0m"
        }
        func split(_ row: Int,_ left: String,_ right: String,_ style: String = "2") {
            line(row,TerminalTypography.joined(left,right:right,columns:frameWidth),style)
        }
        func render() {
            let imagesChanged = nextImages != renderedImages
            if imagesChanged {
                for image in renderedImages { output += imageProtocol.delete(id:image.id) }
                // EL removes old iTerm images too. Repaint their complete cells
                // before drawing the new placement, including empty image rows.
                for image in renderedImages + nextImages {
                    for row in image.screenRow..<(image.screenRow+image.count*(lineGap+1)-lineGap) { renderedLines[row] = "invalidated" }
                }
            }
            let scrollingText = nextImages.isEmpty && renderedImages.isEmpty && mode == .scroll && !choosingBook && !contents && !helpVisible && cols >= 24 && rows >= 10
            if scrollingText, let previous = renderedScrollIndex {
                let shift = (index-previous)*(lineGap+1)
                let region = 4..<(4+readingRows)
                // Move retained rows in the terminal itself, then paint only the
                // newly exposed lines. Verify overlap before reusing any cells.
                if shift != 0, abs(shift) < readingRows,
                   region.filter({ region.contains($0+shift) }).allSatisfy({ nextLines[$0] == renderedLines[$0+shift] }) {
                    output += "\u{1B}[0m\u{1B}[4;\(3+readingRows)r\u{1B}[4;1H\u{1B}[\(abs(shift))\(shift > 0 ? "S" : "T")\u{1B}[r"
                    let before = renderedLines
                    for row in region { renderedLines[row] = region.contains(row+shift) ? before[row+shift] : nil }
                }
            }
            renderedScrollIndex = scrollingText ? index : nil
            for row in Set(renderedLines.keys).union(nextLines.keys).sorted() where renderedLines[row] != nextLines[row] {
                output += "\u{1B}[\(row);1H\u{1B}[2K" + (nextLines[row] ?? "")
            }
            if imagesChanged {
                for image in nextImages {
                    if let png = image.image.png(firstRow:image.firstRow,rowCount:image.count,totalRows:image.totalRows) {
                        let height = image.count*(lineGap+1)-lineGap
                        output += "\u{1B}[\(image.screenRow);\(max(1,(cols-image.columns)/2+1))H"
                        output += imageProtocol.display(png,id:image.id,columns:image.columns,rows:height)
                    }
                }
            }
            renderedImages = nextImages
            renderedLines = nextLines
            // Supporting terminals present one complete update; others ignore
            // this private mode and still receive a single compact write.
            if !output.isEmpty { write("\u{1B}[?2026h" + output + "\u{1B}[?2026l") }
        }
        if cols < 24 || rows < 10 {
            line(1,"请扩大终端窗口")
            line(2,"至少 24 列 × 10 行 · q 退出","2")
            render(); return
        }
        let rule = String(repeating:"─",count:frameWidth)
        if helpVisible || choosingBook || contents { line(3,rule,"2") }
        if helpVisible {
            split(2,"操作与外观","? / Esc 返回","1")
            helpOffset = min(helpOffset,max(0,helpLines.count-bodyRows))
            for (i,text) in helpLines.dropFirst(helpOffset).prefix(bodyRows).enumerated() { line(i+4,text) }
            split(rows-3,"宽度与行距在正文中立即生效","\(helpOffset+1)–\(min(helpLines.count,helpOffset+bodyRows))/\(helpLines.count)")
            line(rows-1,"↑↓ 浏览帮助   ? / Esc 返回","2")
            render(); return
        }
        if choosingBook {
            split(2,frameWidth >= 40 ? "booklife  /  书库" : "书库","\(catalog.count) 本","1")
            let detailed = cols >= 56 && rows >= 18
            let stride = detailed ? 3 : 1
            let visibleCount = max(1,(bodyRows+1)/stride)
            let start = TerminalTypography.windowStart(selection:selectedBook,count:catalog.count,capacity:visibleCount)
            if catalog.isEmpty {
                line(5,"还没有可阅读的书籍")
                line(7,"在图书应用下载后按 r 刷新。","2")
            }
            for i in start..<min(catalog.count,start+visibleCount) {
                let selected = i == selectedBook
                let title = "\(selected ? "›" : " ") \(i+1)  \(catalog[i].title)"
                let fitted = TerminalTypography.abbreviated(title,columns:frameWidth)
                line(4+(i-start)*stride,selected ? fitted + String(repeating:" ",count:max(0,frameWidth-TextLayout.width(fitted))) : fitted,selected ? "1;7" : "")
                if detailed {
                    line(5+(i-start)*stride,"     " + [catalog[i].author,catalog[i].source].filter { !$0.isEmpty }.joined(separator:" · "),"2")
                }
            }
            let metadata = catalog.indices.contains(selectedBook) ? [catalog[selectedBook].author,catalog[selectedBook].source].filter { !$0.isEmpty }.joined(separator:" · ") : "Apple Books 与书籍人生"
            split(rows-3,detailed ? "最近阅读优先" : metadata,catalog.isEmpty ? "" : "\(selectedBook+1) / \(catalog.count)")
            if !notice.isEmpty { line(rows-2,notice,"2") }
            split(rows-1,frameWidth >= 60 ? "↑↓ 选择   Enter 阅读   r 刷新   q 退出" : (frameWidth >= 36 ? "↑↓ 选择  Enter 阅读" : "↑↓  Enter"),"? 帮助")
            render(); return
        }
        if contents {
            split(2,book.title,"目录","1")
            let start = TerminalTypography.windowStart(selection:selectedChapter,count:book.contents.count,capacity:bodyRows)
            for i in start..<min(book.contents.count,start+bodyRows) {
                let entry = book.contents[i]
                let branch = entry.depth == 0 ? "" : String(repeating:"  ",count:min(entry.depth,3)) + "↳ "
                let title = "\(i == selectedChapter ? "›" : " ") \(i+1)  " + branch + entry.title
                let fitted = TerminalTypography.abbreviated(title,columns:frameWidth)
                line(i-start+4,i == selectedChapter ? fitted + String(repeating:" ",count:max(0,frameWidth-TextLayout.width(fitted))) : fitted,i == selectedChapter ? "1;7" : "")
            }
            split(rows-3,"目录", "\(selectedChapter+1) / \(book.contents.count)")
            line(rows-1,frameWidth >= 50 ? "↑↓ 选择   Enter 打开   Esc 返回   ? 帮助" : "↑↓ 选择  Enter 打开  Esc 返回","2")
        } else {
            let progress = Int(min(1,max(0,snapshot?.progress ?? 0))*100)
            split(2,book.title,"\(progress)%")
            let visible = mode == .scroll ? Array(pages[index..<min(pages.count,index+capacity)]) : [pages[index]]
            var i = 0
            for page in visible {
                for j in page.lines.indices {
                    let row = i*(lineGap+1)+4
                    line(row,page.lines[j],page.headingLevels[j] > 0 ? "1" : "",prose:true)
                    if let slice = page.imageRows[j] {
                        if let last = nextImages.last, last.image.id == slice.image.id,
                           last.firstRow+last.count == slice.row, last.screenRow+last.count*(lineGap+1) == row {
                            nextImages[nextImages.count-1].count += 1
                        } else {
                            nextImages.append(ViewportImage(image:slice.image,screenRow:row,firstRow:slice.row,count:1,totalRows:slice.totalRows,columns:slice.columns))
                        }
                    }
                    i += 1
                }
            }
            split(rows-1,"","? 帮助")
        }
        if let pending = pairing?.pending {
            line(rows-2,"配对 \(pending.code) · 核对后 y 确认 / n 取消","1")
        } else if let record = pendingProgress {
            line(rows-2,"\(record.deviceName) 新进度 \(Int(record.progress*100))% · u 继续","1")
        } else if !notice.isEmpty { line(rows-2,notice,"2") }
        render()
    }
    func changeAppearance(width: Bool) {
        let anchor = location
        if width { widthStyle = widthStyle.next } else { lineGap = lineGap == 0 ? 1 : 0 }
        resize(saved:anchor)
        do {
            try widthStyle.rawValue.write(to:stateDirectory.appendingPathComponent("text-width"),atomically:true,encoding:.utf8)
            try String(lineGap).write(to:stateDirectory.appendingPathComponent("line-gap"),atomically:true,encoding:.utf8)
            notice = ""
        } catch { notice = "外观设置未能保存" }
        save()
    }
    func turn(_ direction: PageDirection, lines: Int? = nil) -> String? {
        if lines == nil { stopRemoteScroll() }
        guard !choosingBook, !contents, !helpVisible, cols >= 24, rows >= 10 else { return "请返回终端正文并展开窗口" }
        let step = mode == .scroll ? (lines ?? max(1,Int(Double(capacity) * 0.8))) : 1
        let next = min(lastIndex,max(0,index + (direction == .next ? step : -step)))
        guard next != index else { return direction == .next ? "已到结尾" : "已到开头" }
        index = next; notice = ""; recordUnifiedProgress(); draw(); return nil
    }
    func stopRemoteScroll() {
        remoteMotion.reset()
    }
    func scrollRemotely(_ direction: PageDirection, lines: Double) -> String? {
        guard mode == .scroll, !choosingBook, !contents, !helpVisible, cols >= 24, rows >= 10 else { return "请返回终端正文" }
        remoteMotion.append(lines * (direction == .next ? 1 : -1),now:ProcessInfo.processInfo.systemUptime)
        if let step = remoteMotion.step(now:ProcessInfo.processInfo.systemUptime) {
            return turn(step > 0 ? .next : .previous,lines:abs(step))
        }
        return nil
    }
    func toggleMode() {
        let anchor = location
        mode = mode == .scroll ? .paged : .scroll
        resize(saved:anchor)
        do { try mode.rawValue.write(to:stateDirectory.appendingPathComponent("view-mode"),atomically:true,encoding:.utf8) }
        catch { notice = "查看模式未能保存" }
        save()
    }
    func jump(_ chapter: Int) {
        guard book.contents.indices.contains(chapter) else { return }
        let entry = book.contents[chapter]
        index = min(lastIndex,TextLayout.pageIndex(pages,chapter:entry.chapter,offset:entry.offset))
        contents = false; notice = ""; recordUnifiedProgress(); draw()
    }
    func openSelection() {
        guard catalog.indices.contains(selectedBook) else { return }
        do {
            let url = catalog[selectedBook].url
            let loaded = try TextBook.open(url)
            saveQueue.sync {}
            anchorIndexes.removeAll()
            book = loaded; bookURL = url; sessionID = UUID(); bookID = UUID()
            progressURL = stateDirectory.appendingPathComponent(book.id + ".json")
            pages = []; choosingBook = false; contents = false; notice = ""
            resize(saved:try? JSONDecoder().decode(Location.self,from:Data(contentsOf:progressURL)))
            restoreSharedOnOpen(); save()
        } catch { notice = error.localizedDescription }
    }
    func showLibrary() {
        save(); choosingBook = true; contents = false; sessionID = UUID(); notice = ""
        do { catalog = try LibraryCatalog.allBooks(); selectedBook = 0 } catch { notice = error.localizedDescription }
    }
    func updateBridge(claim: Bool = false) {
        guard remote, let port = bridgePort else { return }
        if raw && !choosingBook {
            if !claim, let active = TerminalLease.load(), active.owner != bridgeOwner { return }
            do { try TerminalLease(owner:bridgeOwner,port:port,token:bridgeToken).save() }
            catch { notice = "无法连接 Mac 遥控：\(error.localizedDescription)" }
        } else { TerminalLease.remove(owner:bridgeOwner) }
    }
    func startBridge() throws {
        bridgeToken = try PairingStore.generate()
        let router = ReadingRouter(token:bridgeToken,snapshot:{ [weak self] in self?.snapshot },readiness:{ [weak self] in
            guard let self, self.raw, !self.choosingBook, !self.contents, !self.helpVisible, self.cols >= 24, self.rows >= 10 else { return "请返回终端正文" }
            return nil
        },turn:{ [weak self] direction in guard let self else { return "终端已关闭" }; return self.turn(direction) },scroll:{ [weak self] direction,lines in
            guard let self else { return "终端已关闭" }
            return self.scrollRemotely(direction,lines:lines)
        })
        let server = HTTPServer { await router.handle($0) }
        server.onState = { [weak self] _,port in
            self?.bridgePort = port
            self?.remoteStatus = port != nil ? "手表遥控已开启 · 使用原有 Mac 连接" : "手表遥控未连接"
            self?.draw()
        }
        bridgeServer = server
        try server.start(port:0,loopbackOnly:true)
        bridgeTimer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { [weak self] _ in self?.updateBridge() }
        if let path = ProcessInfo.processInfo.environment["BOOKSLIDE_MAC_APP"], FileManager.default.fileExists(atPath:path) {
            let launch = Process(); launch.executableURL = URL(fileURLWithPath:"/usr/bin/open"); launch.arguments = ["-g",path]
            launch.standardOutput = FileHandle.nullDevice; launch.standardError = FileHandle.nullDevice
            try? launch.run()
        }
    }
    func startRemote() throws {
        try startBridge()
        let identityURL = stateDirectory.appendingPathComponent("receiver-id")
        if let value = try? String(contentsOf:identityURL), let id = UUID(uuidString:value) { receiverID = id }
        else { try receiverID.uuidString.write(to:identityURL,atomically:true,encoding:.utf8) }
        token = try PairingStore.load() ?? PairingStore.generate(); try PairingStore.save(token)
        let name = String((Host.current().localizedName ?? "Mac").prefix(40)) + " · Terminal"
        let pairing = PairingCoordinator(receiverID:receiverID) { [weak self] in
            guard let self, let host = SCDynamicStoreCopyLocalHostName(nil) as String? else { return nil }
            return SavedConnection(receiverID:self.receiverID,name:name,endpoint:"http://\(host).local:\(self.port)",token:self.token)
        }
        self.pairing = pairing
        pairing.onChange = { [weak self] in self?.draw() }
        let router = ReadingRouter(token:token,snapshot:{ [weak self] in self?.snapshot },readiness:{ [weak self] in
            guard let self, self.raw, !self.choosingBook, !self.contents, !self.helpVisible, self.cols >= 24, self.rows >= 10 else { return "请打开终端正文" }
            return nil
        },turn:{ [weak self] direction in guard let self else { return "终端阅读器已退出" }; return self.turn(direction) },scroll:{ [weak self] direction,lines in
            guard let self else { return "终端已关闭" }
            return self.scrollRemotely(direction,lines:lines)
        })
        let server = HTTPServer { request in
            if let reply = pairing.handle(request) { return reply }
            return await router.handle(request)
        }
        server.onState = { [weak self] message, actualPort in
            guard let self else { return }
            if let actualPort { self.port = actualPort }
            self.remoteStatus = (self.bridgePort != nil || actualPort != nil) ? "手表遥控已开启 · 使用原有 Mac 连接" : message
            if actualPort == nil && self.bridgePort == nil { self.notice = message }
            self.draw()
        }
        self.server = server; try server.start(port:port,serviceName:name,receiverID:receiverID)
        timer = Timer.scheduledTimer(withTimeInterval:1,repeats:true) { _ in pairing.expire() }
    }
    func run() throws {
        guard tcgetattr(STDIN_FILENO,&original) == 0 else { throw TextError("无法读取终端设置") }
        var settings = original; cfmakeraw(&settings)
        guard tcsetattr(STDIN_FILENO,TCSAFLUSH,&settings) == 0 else { throw TextError("无法启动终端阅读") }
        syncTimer = Timer.scheduledTimer(withTimeInterval:15,repeats:true) { [weak self] _ in self?.syncUnifiedProgress() }
        syncUnifiedProgress()
        raw = true; write("\u{1B}[?1049h\u{1B}[2J\u{1B}[?25l\u{1B}[?1000h\u{1B}[?1006h")
        for number in [SIGINT,SIGTERM,SIGHUP,SIGWINCH] {
            signal(number,SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal:number,queue:.main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                if number == SIGWINCH { self.resize(); self.draw() } else { self.finish() }
            }
            source.resume(); sources.append(source)
        }
        if remote { do { try startRemote() } catch { notice = "遥控未启动：\(error.localizedDescription)" } }
        let source = DispatchSource.makeReadSource(fileDescriptor:STDIN_FILENO,queue:.main)
        source.setEventHandler { [weak self] in
            self?.readInput()
        }
        input = source; source.resume(); draw(); RunLoop.main.run()
    }
    func readInput() {
        // Drain only input already available. A small read boundary must not
        // turn one wheel burst into several rapidly repainted frames. Bound
        // the work so sustained input still yields to signals and remote work.
        var batch: [UInt8] = []
        var ended = false
        while batch.count < 4096 {
            var ready = pollfd(fd:STDIN_FILENO,events:Int16(POLLIN),revents:0)
            guard poll(&ready,1,0) > 0 else { break }
            var bytes = [UInt8](repeating:0,count:4096-batch.count)
            let count = Darwin.read(STDIN_FILENO,&bytes,bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { ended = true; break }
            batch.append(contentsOf:bytes.prefix(count))
        }
        if !batch.isEmpty { consume(batch) }
        if ended { finish() }
    }
    func consume(_ bytes: [UInt8]) {
        stopRemoteScroll()
        consumingInput = true
        var wheelLines = 0
        func flushWheel() {
            guard wheelLines != 0 else { return }
            notice = turn(wheelLines > 0 ? .next : .previous,lines:abs(wheelLines)) ?? ""
            wheelLines = 0
        }
        defer { flushWheel(); consumingInput = false; draw() }
        pendingInput.append(contentsOf:bytes)
        while let first = pendingInput.first {
            var key = String(UnicodeScalar(first)); var length = 1
            if first == 27 {
                if pendingInput.count == 1 {
                    DispatchQueue.main.asyncAfter(deadline:.now()+0.08) { [weak self] in
                        guard let self, self.pendingInput == Data([27]) else { return }
                        self.pendingInput.removeAll()
                        if self.helpVisible { self.helpVisible = false } else { self.contents = false }
                        self.draw()
                    }; return
                }
                if pendingInput[pendingInput.startIndex+1] == 91 {
                    guard let end = pendingInput.dropFirst(2).firstIndex(where: { (64...126).contains($0) }) else { return }
                    length = pendingInput.distance(from:pendingInput.startIndex,to:end)+1
                    key = String(data:pendingInput.prefix(length),encoding:.utf8) ?? ""
                }
            }
            pendingInput.removeFirst(length)
            // SGR mouse wheel; leave other pointer events without actions.
            if key.hasPrefix("\u{1B}[<") {
                guard key.hasSuffix("M"), let code = Int(key.dropFirst(3).split(separator:";").first ?? ""), code == 64 || code == 65 else { continue }
                if mode == .scroll, !choosingBook, !contents, !helpVisible {
                    // Terminals already encode wheel/trackpad acceleration and
                    // momentum in event frequency. Keep one line per event,
                    // combine queued deltas, and don't add another animation.
                    wheelLines += code == 65 ? 1 : -1
                    continue
                }
                if choosingBook || contents || helpVisible { key = code == 65 ? "\u{1B}[B" : "\u{1B}[A" }
                else { notice = turn(code == 65 ? .next : .previous,lines:1) ?? ""; continue }
            }
            // Apply movement before a key can change mode/book or quit. Never
            // discard non-wheel input while coalescing a mouse burst.
            flushWheel()
            if key == "q" || first == 3 || first == 4 { finish() }
            if key == "?" { helpVisible.toggle(); helpOffset = 0; continue }
            if helpVisible {
                if ["\u{1B}[B","j"].contains(key) { helpOffset = min(max(0,helpLines.count-bodyRows),helpOffset+1) }
                if ["\u{1B}[A","k"].contains(key) { helpOffset = max(0,helpOffset-1) }
                if key == "\u{1B}[6~" || key == " " { helpOffset = min(max(0,helpLines.count-bodyRows),helpOffset+bodyRows) }
                if key == "\u{1B}[5~" { helpOffset = max(0,helpOffset-bodyRows) }
                continue
            }
            if choosingBook {
                if ["\u{1B}[B","j"].contains(key) { selectedBook = min(max(0,catalog.count-1),selectedBook+1) }
                if ["\u{1B}[A","k"].contains(key) { selectedBook = max(0,selectedBook-1) }
                let step = max(1,(bodyRows+1)/(cols >= 56 && rows >= 18 ? 3 : 1))
                if key == "\u{1B}[6~" { selectedBook = min(max(0,catalog.count-1),selectedBook+step) }
                if key == "\u{1B}[5~" { selectedBook = max(0,selectedBook-step) }
                if ["\u{1B}[H","\u{1B}[1~"].contains(key) { selectedBook = 0 }
                if ["\u{1B}[F","\u{1B}[4~"].contains(key) { selectedBook = max(0,catalog.count-1) }
                if key == "\r" || key == "\n" { openSelection() }
                if key == "r" { showLibrary() }
                draw(); continue
            }
            if key == "b" { showLibrary(); draw(); continue }
            if key == "c" { contents.toggle(); selectedChapter = currentContentsIndex }
            else if contents {
                if ["\u{1B}[B","j"].contains(key) { selectedChapter = min(book.contents.count-1,selectedChapter+1) }
                if ["\u{1B}[A","k"].contains(key) { selectedChapter = max(0,selectedChapter-1) }
                if key == "\u{1B}[6~" { selectedChapter = min(book.contents.count-1,selectedChapter+bodyRows) }
                if key == "\u{1B}[5~" { selectedChapter = max(0,selectedChapter-bodyRows) }
                if ["\u{1B}[H","\u{1B}[1~"].contains(key) { selectedChapter = 0 }
                if ["\u{1B}[F","\u{1B}[4~"].contains(key) { selectedChapter = book.contents.count-1 }
                if key == "\r" || key == "\n" { jump(selectedChapter) }
            } else if key == "u", let record = pendingProgress { applyUnifiedProgress(record); notice = "已延续其他设备的阅读位置"; save() }
            else if key == "s" { syncUnifiedProgress() }
            else if key == "m" { toggleMode() }
            else if key == "w" { changeAppearance(width:true) }
            else if key == "g" { changeAppearance(width:false) }
            else if ["\u{1B}[B","j"].contains(key) { notice = turn(.next,lines:1) ?? "" }
            else if ["\u{1B}[A","k"].contains(key) { notice = turn(.previous,lines:1) ?? "" }
            else if ["\u{1B}[C","\u{1B}[6~"," ","\r"].contains(key) { notice = turn(.next) ?? "" }
            else if ["\u{1B}[D","\u{1B}[5~"].contains(key) { notice = turn(.previous) ?? "" }
            else if key == "]" { jump(currentContentsIndex+1) }
            else if key == "[" { jump(currentContentsIndex-1) }
            else if key == "p", let pairing { pairing.begin(); notice = "在 iPhone 的管理设备中选择名称带 Terminal 的 Mac" }
            else if key == "y", let pending = pairing?.pending { notice = pairing?.approve(id:pending.id) == true ? "已配对 · 打开手表即可阅读" : "配对已过期" }
            else if key == "n" { pairing?.clear(); notice = "已取消配对" }
            draw()
        }
    }
    func recordUnifiedProgress() {
        guard !choosingBook, !book.chapters[location.chapter].href.isEmpty else { return }
        let record = ReadingProgress(bookKey:book.progressKey,deviceID:progressDeviceID,deviceName:"终端",anchor:contentAnchor,progress:snapshot?.progress ?? 0)
        unsavedRecord = record; appliedProgressID = record.id; pendingProgress = nil
        // Coalesce rapid input, retaining the input timestamp and final location.
        // Disk coordination and iCloud never delay a remote acknowledgement.
        if progressWork == nil {
            let work = DispatchWorkItem { [weak self] in self?.save() }
            progressWork = work; DispatchQueue.main.asyncAfter(deadline:.now()+0.2,execute:work)
        }
    }
    func applyUnifiedProgress(_ record: ReadingProgress) {
        guard record.bookKey == book.progressKey, let target = book.location(for:record.anchor) else { return }
        progressWork?.cancel(); progressWork = nil; unsavedRecord = nil
        index = min(lastIndex,TextLayout.pageIndex(pages,chapter:target.chapter,offset:target.offset))
        appliedProgressID = record.id; pendingProgress = nil
    }
    func restoreSharedOnOpen() {
        pendingProgress = nil; appliedProgressID = nil
        if let record = try? unifiedStore.latest(bookKey:book.progressKey) {
            if record.deviceID == progressDeviceID, FileManager.default.fileExists(atPath:progressURL.path) { appliedProgressID = record.id }
            else { applyUnifiedProgress(record) }
        }
        else if FileManager.default.fileExists(atPath:progressURL.path), let attributes = try? FileManager.default.attributesOfItem(atPath:progressURL.path), let date = attributes[.modificationDate] as? Date {
            let legacy = ReadingProgress(bookKey:book.progressKey,deviceID:progressDeviceID,deviceName:"终端",updatedAt:date,anchor:book.anchor(chapter:location.chapter,offset:location.offset),progress:snapshot?.progress ?? 0)
            try? unifiedStore.merge([legacy]); appliedProgressID = legacy.id
        }
    }
    func syncUnifiedProgress() {
        guard !progressSyncing else { return }
        progressSyncing = true
        let store = unifiedStore, key = book.progressKey
        Task { @MainActor in
            let (message, record) = await Task.detached(priority:.utility) { () -> (String?,ReadingProgress?) in
                var message: String?
                do { try store.syncCloud() } catch { message = "云端暂未连接 · 本机进度已保留" }
                return (message,try? store.latest(bookKey:key))
            }.value
            progressSyncing = false
            if let message { notice = message }
            if !choosingBook, key == book.progressKey, let record, record.id != appliedProgressID, record.deviceID != progressDeviceID { pendingProgress = record }
            draw()
        }
    }
    func finish() -> Never {
        stopRemoteScroll()
        save(); saveQueue.sync {}; TerminalLease.remove(owner:bridgeOwner); bridgeServer?.stop(); bridgeTimer?.invalidate(); server?.stop(); timer?.invalidate()
        if raw { for image in renderedImages { write(imageProtocol.delete(id:image.id)) }; tcsetattr(STDIN_FILENO,TCSAFLUSH,&original); write("\u{1B}[?1000l\u{1B}[?1006l\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l"); raw = false }
        exit(0)
    }
}

do {
    setlocale(LC_ALL,"")
    var args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") || args.contains("-h") { print(help); exit(0) }
    if args == ["--list"] {
        for book in try LibraryCatalog.allBooks() { print("\(clean(book.title))\t\(book.url.path)") }
        exit(0)
    }
    let remote = !args.contains("--no-remote")
    args.removeAll { $0 == "--remote" || $0 == "--no-remote" }
    var mode: ReadingMode?
    if let index = args.firstIndex(of:"--mode") {
        guard index+1 < args.count, let value = ReadingMode(rawValue:args[index+1]) else { throw TextError("--mode 需要 scroll 或 paged") }
        mode = value; args.removeSubrange(index...index+1)
    }
    var port: UInt16 = 8766
    if let index = args.firstIndex(of:"--port") {
        guard index+1 < args.count, let value = UInt16(args[index+1]), value > 0 else { throw TextError("--port 需要 1–65535") }
        port = value; args.removeSubrange(index...index+1)
    }
    guard args.count <= 1, args.first?.hasPrefix("--") != true else { throw TextError(help) }
    guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1, ProcessInfo.processInfo.environment["TERM"] != "dumb" else { throw TextError("请在交互式终端运行 booklife；使用 --help 查看用法") }
    let reader = try TerminalReader(url:args.first.map { URL(fileURLWithPath:$0) },remote:remote,port:port,mode:mode)
    try reader.run()
} catch {
    FileHandle.standardError.write(Data("booklife: \(error.localizedDescription)\n".utf8)); exit(1)
}
