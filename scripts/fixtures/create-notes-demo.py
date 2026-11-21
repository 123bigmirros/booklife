#!/usr/bin/env python3
"""Create an isolated, editable three-book library for the notes preview."""
import datetime
import html
import json
from pathlib import Path
import runpy
import sys
import uuid
import zipfile

root = Path(sys.argv[1] if len(sys.argv) > 1 else "build/notes-upgrade/demo-library").resolve()
sys.argv = ["create-graph-demo.py", str(root)]
runpy.run_path(str(Path(__file__).with_name("create-graph-demo.py")), run_name="__main__")
books = json.loads((root / "library.json").read_text())
now = (datetime.datetime.now(datetime.timezone.utc) - datetime.datetime(2001, 1, 1, tzinfo=datetime.timezone.utc)).total_seconds()

def key(value):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "bookslide-notes-preview/" + value)).upper()

def add_book(slug, title, chapter_title, rows, age):
    filename = slug + ".epub"
    paragraphs = [row[1] for row in rows]
    paragraphs += ["读书时，先记下此刻真实的疑问。隔一段时间再回来，看看哪些想法仍然成立，哪些已经改变。重要的是让记录帮助自己继续思考。" for _ in range(24)]
    with zipfile.ZipFile(root / filename, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", '<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
        archive.writestr("OPS/package.opf", f'<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">{slug}</dc:identifier><dc:title>{html.escape(title)}</dc:title><dc:creator>BookSlide · 原创功能示例</dc:creator><dc:language>zh-CN</dc:language><meta property="dcterms:modified">2026-11-07T00:00:00Z</meta></metadata><manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c1"/></spine></package>')
        archive.writestr("OPS/nav.xhtml", f'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol><li><a href="c1.xhtml">{chapter_title}</a></li></ol></nav></body></html>')
        body = f"<h1>{chapter_title}</h1>" + "".join(f'<p id="p{i+1}">{html.escape(text)}</p>' for i, text in enumerate(paragraphs))
        archive.writestr("OPS/c1.xhtml", f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>{chapter_title}</title></head><body>{body}</body></html>')
    notes = []
    for i, (name, quote, thought, question) in enumerate(rows):
        notes.append(dict(id=key(slug + str(i)),title=name,quote=quote,note=thought,chapter=chapter_title,chapterHref="c1.xhtml",progress=0.12+i*0.16,
                          cfi=f"epubcfi(/6/2[c1]!/4/{(i+2)*2}[p{i+1}],/1:0,/1:{len(quote)})",color="green" if question else "yellow",
                          createdAt=now-age-i*1200,updatedAt=now-age-i*1200,intent="question" if question else "thought",questionResolved=False))
    books.append(dict(id=key(slug),title=title,author="BookSlide · 原创功能示例",filename=filename,locator="epubcfi(/6/2[c1]!/4/4[p1]/1:0)",progress=0.12,furthestReadProgress=0.85,lastRead=now-age,bookmarks=[],annotations=notes))

add_book("uncertainty", "不确定性手记 · 示例", "第一章 · 给判断留一点余地", [
    ("先问自己可能错在哪里", "一个判断越笃定，越值得为反例留一个位置。", "做计划时，加一栏：哪些条件变了，这个判断就不成立？", False),
    ("耐心也是一种决策能力", "在信息不足时，等待也是一种有意识的选择。", "和《山河旧事》里先学静心的提醒连起来看：不要为了立即得到答案而仓促下结论。", False),
    ("什么时候应该停止收集信息？", "更多的信息，未必带来更清晰的判断。", "需要一个可以行动的门槛，而不是一直等到完全确定。这个门槛如何设定？", True),
    ("留一点余地", "为尚未看见的事情，留下一点可以调整的空间。", "", False)
], 3600)
add_book("reading", "慢慢读懂一本书 · 示例", "第二章 · 从摘录到理解", [
    ("把摘录变成自己的判断", "值得留下来的，不只有原句，还有你此刻的理解。", "下次整理读书笔记，选三条真正影响自己的摘录，分别写下：它改变了什么判断？我准备怎样使用？", False),
    ("让耐心留下痕迹", "理解有时发生在第二次读到同一句话的时候。", "第一次只留下疑问也很好。重读时补上新理解，保留当初为什么困惑。", False),
    ("回顾应该发生在什么时候？", "记录只有在再次被需要时，才重新进入生活。", "试试看：每次继续一本搁置的书之前，先回看上一章的两条想法。", True),
    ("保留原文的来处", "一段摘录的上下文，往往和摘录本身同样重要。", "", False)
], 0)
(root / "library.json").write_text(json.dumps(books,ensure_ascii=False))
print(f"{len(books)} books, {sum(len(book.get('annotations', [])) for book in books)} notes")
