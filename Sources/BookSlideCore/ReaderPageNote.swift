import Foundation
import ImageIO

/// Ink is tied to a text anchor and the layout in which it was written.
/// The original page remains available if a later reflow would misalign ink.
public struct ReaderPageAnchor: Codable, Equatable {
    public var locator: String
    public var chapter: String
    public var progress: Double
    public var referenceX: Double
    public var referenceY: Double
    public var viewportWidth: Double
    public var viewportHeight: Double
    public var layoutKey: String
    public var chapterHref: String?
    public var textSpans: [ReaderInkTextSpan]?
    public init(locator: String, chapter: String, progress: Double, referenceX: Double, referenceY: Double,
                viewportWidth: Double, viewportHeight: Double, layoutKey: String) {
        self.locator = locator; self.chapter = chapter; self.progress = progress
        self.referenceX = referenceX; self.referenceY = referenceY
        self.viewportWidth = viewportWidth; self.viewportHeight = viewportHeight; self.layoutKey = layoutKey
    }
}

public struct ReaderPageNote: Codable, Equatable, Identifiable {
    public var id: UUID
    public var assetID: UUID
    public var anchor: ReaderPageAnchor
    public var createdAt: Date
    public var updatedAt: Date
    public var title: String?
    public var entityIDs: [UUID]?
    public var parts: [ReaderInkPart]?
    public var text: String?
    public var attributes: ReadingNodeAttributes?
    public var manualGrouping: Bool?
    public init(id: UUID = UUID(), assetID: UUID, anchor: ReaderPageAnchor, createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id; self.assetID = assetID; self.anchor = anchor; self.createdAt = createdAt; self.updatedAt = updatedAt
    }
    public var inkParts: [ReaderInkPart] {
        var result=parts ?? [.init(id:id,canvasID:id,assetID:assetID,anchor:anchor,
                        bounds:.init(x:0,y:0,width:anchor.viewportWidth,height:anchor.viewportHeight),strokeIDs:[],sources:[],title:title)]
        if result.count==1 { result[0].title=title;result[0].text=text;result[0].entityIDs=entityIDs }
        else if let entityIDs {
            let active=Set(entityIDs)
            for i in result.indices { result[i].entityIDs=result[i].entityIDs?.filter { active.contains($0) } }
        }
        return result
    }
    public var excerpt: String { inkParts.map(\.quote).filter { !$0.isEmpty }.joined(separator:"\n\n") }
    public var displayTitle: String {
        if let explicit=title?.trimmingCharacters(in:.whitespacesAndNewlines), !explicit.isEmpty { return explicit }
        let content=(text ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        return String((content.isEmpty ? excerpt : content).split(whereSeparator:\.isNewline).first?.prefix(24) ?? "手写笔记")
    }
}

public struct ReaderInkRect: Codable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double,y: Double,width: Double,height: Double) { self.x=x;self.y=y;self.width=width;self.height=height }
    public var rect: CGRect { .init(x:x,y:y,width:width,height:height) }
    public init(_ rect: CGRect) { self.init(x:rect.minX,y:rect.minY,width:rect.width,height:rect.height) }
    public var valid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && width>0 && height>0 }
}
public struct ReaderInkTextSpan: Codable, Equatable, Identifiable {
    public var id: String
    public var block: String
    public var offset: Int
    public var text: String
    public var boxes: [ReaderInkRect]
    public init(id: String,block: String,offset: Int,text: String,boxes: [ReaderInkRect]) {
        self.id=id;self.block=block;self.offset=offset;self.text=text;self.boxes=boxes
    }
}
/// Parts keep their own source and immutable editable asset when groups merge.
public struct ReaderInkPart: Codable, Equatable, Identifiable {
    public var id: UUID
    public var canvasID: UUID
    public var assetID: UUID
    public var anchor: ReaderPageAnchor
    public var bounds: ReaderInkRect
    public var strokeIDs: [String]
    public var sources: [ReaderInkTextSpan]
    public var title: String?
    public var text: String?
    public var entityIDs: [UUID]?
    public init(id: UUID,canvasID: UUID,assetID: UUID,anchor: ReaderPageAnchor,bounds: ReaderInkRect,strokeIDs: [String],sources: [ReaderInkTextSpan],title: String? = nil) {
        self.id=id;self.canvasID=canvasID;self.assetID=assetID;self.anchor=anchor;self.bounds=bounds;self.strokeIDs=strokeIDs;self.sources=sources;self.title=title
    }
    public var quote: String {
        var result="", last: ReaderInkTextSpan?
        for span in sources {
            if let last, last.block != span.block { result += "\n" }
            else if let last, span.offset>last.offset+last.text.utf16.count { result += " " }
            result += span.text;last=span
        }
        return result.trimmingCharacters(in:.whitespacesAndNewlines)
    }
}

/// Geometry proposes local units; source overlap joins passages. Existing
/// ownership wins, so saving new ink never undoes a user's merge or split.
public enum ReaderInkGrouping {
    public struct Stroke { public var id: String; public var bounds: CGRect
        public init(id: String,bounds: CGRect) { self.id=id;self.bounds=bounds } }
    public struct Unit { public var id: UUID; public var owner: UUID?; public var strokes: [String]; public var bounds: CGRect; public var sources: [ReaderInkTextSpan] }
    public static func plan(_ strokes: [Stroke],canvasID: UUID,anchor: ReaderPageAnchor,previous: [ReaderPageNote]) -> [[Unit]] {
        let spans=(anchor.textSpans ?? []).filter { !$0.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
        let height=spans.flatMap(\.boxes).map(\.height).sorted()
        let line=height.isEmpty ? 22 : max(12,min(48,height[height.count/2]))
        var old: [UUID:(ReaderInkPart,UUID)]=[:], byStroke: [String:UUID]=[:]
        for note in previous { for part in note.inkParts where part.canvasID==canvasID {
            old[part.id]=(part,note.id);for key in part.strokeIDs { byStroke[key]=part.id }
        } }
        var clusters: [[Stroke]]=[]
        for stroke in strokes where !stroke.bounds.isNull && !stroke.bounds.isInfinite {
            if let part=byStroke[stroke.id], let i=clusters.firstIndex(where:{ byStroke[$0[0].id]==part }) { clusters[i].append(stroke) }
            else { clusters.append([stroke]) }
        }
        func box(_ c: [Stroke]) -> CGRect { c.reduce(CGRect.null) { $0.union($1.bounds) } }
        // Only unassigned strokes are clustered. An old group remains stable
        // even when its strokes are moved apart with the Pencil lasso.
        var changed=true
        while changed {
            changed=false
            outer: for i in clusters.indices { for j in clusters.indices where j>i {
                let a=byStroke[clusters[i][0].id], b=byStroke[clusters[j][0].id]
                if a != nil || b != nil { continue }
                if box(clusters[i]).insetBy(dx:-line*0.35,dy:-line*0.20).intersects(box(clusters[j]).insetBy(dx:-line*0.35,dy:-line*0.20)) {
                    clusters[i] += clusters.remove(at:j);changed=true;break outer
                }
            } }
        }
        var units: [Unit]=[]
        for c in clusters {
            let bounds=box(c), existing=byStroke[c[0].id]
            let sources=spans.filter { $0.boxes.contains { $0.rect.insetBy(dx:-2,dy:-line*0.22).intersects(bounds) } }
            let id=existing ?? (units.isEmpty && !strokes.contains(where:{ byStroke[$0.id] != nil }) ? canvasID : UUID())
            units.append(.init(id:id,owner:old[id]?.1,strokes:c.map(\.id),bounds:bounds,sources:sources.isEmpty ? old[id]?.0.sources ?? [] : sources))
        }
        var u=0
        while u<units.count {
            if units[u].owner==nil {
                let matches=units.indices.filter { j in j != u && units[j].owner != nil && units[j].bounds.insetBy(dx:-line*0.5,dy:-line*0.25).intersects(units[u].bounds) }
                if matches.count==1 {
                    let j=matches[0];units[j].strokes += units[u].strokes;units[j].bounds=units[j].bounds.union(units[u].bounds)
                    let ids=Set(units[j].sources.map(\.id));units[j].sources += units[u].sources.filter { !ids.contains($0.id) }
                    units[j].sources.sort { $0.block==$1.block ? $0.offset<$1.offset : ($0.boxes.first?.y ?? 0)<($1.boxes.first?.y ?? 0) }
                    units.remove(at:u);continue
                }
            }
            u += 1
        }
        // The same source passage can have ink written under a different
        // font/orientation. Keep its node while retaining each layout's ink.
        for i in units.indices where units[i].owner==nil && !units[i].sources.isEmpty {
            let matches=previous.filter { note in note.inkParts.contains { part in
                part.sources.contains { a in units[i].sources.contains { b in
                    a.id==b.id || (a.block==b.block && max(a.offset,b.offset)<min(a.offset+a.text.utf16.count,b.offset+b.text.utf16.count))
                } }
            } }.map(\.id)
            let owners=Set(matches)
            if owners.count==1 { units[i].owner=owners.first }
            else if owners.count>1 { units[i].owner=units[i].id }
        }
        func related(_ a: Unit,_ b: Unit) -> Bool {
            if let x=a.owner, let y=b.owner { return x==y }
            if !Set(a.sources.map(\.id)).isDisjoint(with:b.sources.map(\.id)) { return true }
            for x in a.sources { for y in b.sources where x.block==y.block {
                let gap=max(x.offset,y.offset)-min(x.offset+x.text.utf16.count,y.offset+y.text.utf16.count)
                if gap<=2 && a.bounds.insetBy(dx:-line,dy:-line*1.6).intersects(b.bounds) { return true }
            } }
            return false
        }
        var groups=units.map { [$0] }
        changed=true
        while changed {
            changed=false
            outer: for i in groups.indices { for j in groups.indices where j>i {
                let owners=Set((groups[i]+groups[j]).compactMap(\.owner))
                if owners.count>1 { continue }
                if groups[i].contains(where:{ a in groups[j].contains { related(a,$0) } }) {
                    groups[i] += groups.remove(at:j);changed=true;break outer
                }
            } }
        }
        // A margin explanation may join a passage only when exactly one
        // nearby passage is plausible. Ambiguous notes remain independent.
        var i=0
        while i<groups.count {
            if groups[i].allSatisfy({ $0.sources.isEmpty && $0.owner==nil }) {
                let rect=groups[i].reduce(CGRect.null) { $0.union($1.bounds) }
                let candidates=groups.indices.filter { j in j != i && groups[j].contains { !$0.sources.isEmpty } && groups[j].contains { $0.bounds.insetBy(dx:-line*2,dy:-line).intersects(rect) } }
                if candidates.count==1 { let target=candidates[0];groups[target] += groups[i];groups.remove(at:i);continue }
            }
            i += 1
        }
        return groups.sorted { a,b in
            let x=a.reduce(CGRect.null) { $0.union($1.bounds) }, y=b.reduce(CGRect.null) { $0.union($1.bounds) }
            return x.minY==y.minY ? x.minX<y.minX : x.minY<y.minY
        }
    }
}

public struct ReaderPageNoteFiles {
    public var drawing: Data
    public var page: Data
    public var ink: Data
    public var preview: Data
    public init(drawing: Data, page: Data, ink: Data, preview: Data) {
        self.drawing = drawing; self.page = page; self.ink = ink; self.preview = preview
    }
}

/// Immutable asset versions keep both the current index and its backup readable.
/// Large PencilKit drawings and page images never enter the library JSON bridge.
public struct ReaderPageNoteStore {
    public let directory: URL
    public init(libraryDirectory: URL) { directory = libraryDirectory.appendingPathComponent("PageNotes",isDirectory:true) }
    private func folder(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString,isDirectory:true) }
    public func image(_ id: UUID, name: String) throws -> Data {
        guard ["page.png","ink.png","preview.png"].contains(name) else { throw CocoaError(.fileReadNoPermission) }
        return try Data(contentsOf:folder(id).appendingPathComponent(name))
    }
    public func load(_ id: UUID) throws -> ReaderPageNoteFiles {
        try ReaderPageNoteFiles(drawing:Data(contentsOf:folder(id).appendingPathComponent("drawing.data")),
            page:image(id,name:"page.png"),ink:image(id,name:"ink.png"),preview:image(id,name:"preview.png"))
    }
    public func croppedPreview(_ id: UUID,rect: ReaderInkRect) throws -> Data {
        guard rect.valid, rect.x>=0,rect.y>=0,rect.x+rect.width<=1.001,rect.y+rect.height<=1.001,
              let source=CGImageSourceCreateWithData(try image(id,name:"preview.png") as CFData,nil),
              let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CocoaError(.fileReadCorruptFile) }
        let region=CGRect(x:rect.x*Double(image.width),y:rect.y*Double(image.height),width:rect.width*Double(image.width),height:rect.height*Double(image.height)).integral.intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
        guard let cropped=image.cropping(to:region) else { throw CocoaError(.fileReadCorruptFile) }
        let data=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil) else { throw CocoaError(.fileReadCorruptFile) }
        CGImageDestinationAddImage(destination,cropped,nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileReadCorruptFile) }
        return data as Data
    }
    public func save(_ files: ReaderPageNoteFiles) throws -> UUID {
        let values = ["drawing.data":files.drawing,"page.png":files.page,"ink.png":files.ink,"preview.png":files.preview]
        guard values.values.allSatisfy({ !$0.isEmpty && $0.count <= 32 * 1024 * 1024 }),
              values.values.reduce(0,{ $0 + $1.count }) <= 64 * 1024 * 1024 else {
            throw NSError(domain:"BookSlide.PageNotes",code:1,userInfo:[NSLocalizedDescriptionKey:"书页批注数据为空或过大"])
        }
        let fm = FileManager.default, id = UUID()
        try fm.createDirectory(at:directory,withIntermediateDirectories:true)
        let staging = directory.appendingPathComponent(".pending-\(id.uuidString)",isDirectory:true)
        try fm.createDirectory(at:staging,withIntermediateDirectories:false)
        defer { try? fm.removeItem(at:staging) }
        for (name,data) in values { try data.write(to:staging.appendingPathComponent(name),options:.atomic) }
        try fm.moveItem(at:staging,to:folder(id))
        return id
    }
}
