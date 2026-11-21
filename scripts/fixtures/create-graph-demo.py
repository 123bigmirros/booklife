#!/usr/bin/env python3
"""A fictional, isolated EPUB/library for inspecting the production graph UI."""
import datetime
import html
import json
from pathlib import Path
import sys
import uuid
import zipfile

root = Path(sys.argv[1] if len(sys.argv) > 1 else "build/graph-integration/demo-library").resolve()
root.mkdir(parents=True, exist_ok=True)
key = lambda name: str(uuid.uuid5(uuid.NAMESPACE_URL, "bookslide-graph-demo/" + name)).upper()
now = (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds()
chapters = [
    ("c6", "第六章 · 旧路", ["林川在旧路上认出了沈砚。", "山风从松林间穿过，两人沿石阶慢慢向上。林川说，走路和读书一样，有时慢一点，才能看清来处。", "沈砚记下这句话，继续跟着他向山门走去。"]),
    ("c7", "第七章 · 山门前", ["沈砚向林川行了弟子礼。", "入门之前，须先学会静心。林川指着山门旁的石碑，让沈砚把这句话记在心里。", "钟声从院中传来，几名弟子收起书卷。沈砚回头望了望来时的路，觉得往日的许多困惑，都可以留待以后慢慢解答。", "他重新整理衣袖，跟随林川走进山门。"]),
    ("c8", "第八章 · 初晴", ["雨停之后，石阶上的苔色更加清亮。", "沈砚把新读到的内容写在纸上，留下一些尚未想明白的问题。"])
]
for _, _, paragraphs in chapters:
    # Real chapter length keeps WebKit's continuous-scroll layout representative.
    paragraphs.extend(["山中的日子过得很慢。晨钟响过，院子里渐渐有了翻书的声音。沈砚沿着石阶走去，把一路所见和心中的疑问记在纸上，准备在晚课时向林川请教。" for _ in range(22)])
with zipfile.ZipFile(root / "graph-demo.epub", "w") as archive:
    archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
    archive.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    manifest = '<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>'
    manifest += "".join(f'<item id="{cid}" href="{cid}.xhtml" media-type="application/xhtml+xml"/>' for cid, _, _ in chapters)
    spine = "".join(f'<itemref idref="{cid}"/>' for cid, _, _ in chapters)
    archive.writestr("OPS/package.opf", f'<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">bookslide-fictional-graph-demo</dc:identifier><dc:title>山河旧事 · 示例</dc:title><dc:creator>BookSlide · 虚构功能示例</dc:creator><dc:language>zh-CN</dc:language><meta property="dcterms:modified">2026-11-02T00:00:00Z</meta></metadata><manifest>{manifest}</manifest><spine>{spine}</spine></package>')
    links = "".join(f'<li><a href="{cid}.xhtml">{title}</a></li>' for cid, title, _ in chapters)
    archive.writestr("OPS/nav.xhtml", f'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol>{links}</ol></nav></body></html>')
    for cid, title, paragraphs in chapters:
        body = f"<h1>{html.escape(title)}</h1>" + "".join(f'<p id="p{i+1}">{html.escape(text)}</p>' for i, text in enumerate(paragraphs))
        archive.writestr(f"OPS/{cid}.xhtml", f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{title}</title></head><body>{body}</body></html>')

people = [
    dict(id=key("lin"), name="林川", kind="person", aliases=["青川客"]),
    dict(id=key("shen"), name="沈砚", kind="person", aliases=["小沈"]),
    dict(id=key("patience"), name="耐心", kind="concept", aliases=["静心"])
]
def note(name, chapter, paragraph, quote, title, text, progress, entities):
    pos = next(i for i, item in enumerate(chapters) if item[0] == chapter)
    return dict(id=key(name), cfi=f"epubcfi(/6/{(pos+1)*2}[{chapter}]!/4/{(paragraph+1)*2}[p{paragraph}],/1:0,/1:{len(quote)})", quote=quote, chapter=chapters[pos][1], chapterHref=f"{chapter}.xhtml", progress=progress, color="yellow", note=text, title=title, entityIDs=[key(x) for x in entities], createdAt=now, updatedAt=now)
notes = [
    note("teacher", "c7", 1, chapters[1][2][0], "师徒身份确认", "两人的师徒关系在这里明确了。", 0.36, ["lin", "shen"]),
    note("rules", "c7", 2, "入门之前，须先学会静心。", "山门的规矩", "门规首先强调耐心，和上一章林川的提醒相互呼应。", 0.40, ["lin", "patience"]),
    note("old-road", "c6", 1, chapters[0][2][0], "旧路相逢", "人物的相识在这里交代，后文可以回看。", 0.10, ["lin", "shen"])
]
question = note("quiet-question", "c7", 2, "入门之前，须先学会静心。", "为什么先要求静心？", "这是入门的规矩，还是在说理解事物的方法？先留着，继续往下读。", 0.39, [])
question["intent"] = "question"
question["questionResolved"] = False
response = note("quiet-response", "c7", 3, "钟声从院中传来，几名弟子收起书卷。", "我现在的一点理解", "可能是在提醒沈砚先放下急于得到答案的心态，还需要看看后文。", 0.42, [])
response["responseToID"] = question["id"]
notes += [question, response]
for i in range(8):
    item = note(f"highlight-{i}", "c7", i + 5, chapters[1][2][i + 4][:35], "", "", 0.405 + i * 0.003, [])
    notes.append(item)
for entity in people:
    entity["progress"] = 0.1
    entity["chapterHref"] = "c7.xhtml"
independent = dict(id=key("independent-relation"), sourceID=key("lin"), targetID=key("patience"), label="强调", evidenceIDs=[], conjecture=False, standalone=True, progress=0.4, chapterHref="c7.xhtml")
book = dict(id=key("book"), title="山河旧事 · 示例", author="BookSlide · 虚构功能示例", filename="graph-demo.epub",
            locator="epubcfi(/6/4[c7]!/4/26[p12]/1:0)", progress=0.49, lastRead=now, bookmarks=[], annotations=notes,
            knowledgeEntities=people, knowledgeRelations=[dict(id=key("relation"), sourceID=key("lin"), targetID=key("shen"), label="师父", evidenceIDs=[key("teacher")], conjecture=False), independent])
(root / "library.json").write_text(json.dumps([book], ensure_ascii=False))
print(root)
