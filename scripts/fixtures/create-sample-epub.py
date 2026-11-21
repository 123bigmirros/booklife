#!/usr/bin/env python3
"""Build an original, offline EPUB used for first-run reading and smoke tests."""
from pathlib import Path
from zipfile import ZipFile, ZIP_STORED, ZIP_DEFLATED
from html import escape
root = Path(__file__).resolve().parents[2]
chapters = [
    ('让时间慢下来', [
        '窗边的光，刚好落在这一页。',
        '阅读有一种很轻的力量。它不催促，不提醒，也不要求我们立刻回答。只要翻开一本书，世界就多出一段可以由自己安排的时间。',
        '我们常常以为，专注意味着用力。其实有时，它只是把不必要的东西拿远一点：桌上的手机、不断跳动的消息，以及那个总想尽快完成的念头。',
        '留一点时间，给没有进度要求的阅读。读得慢一些，允许一句话停留，允许自己的目光越过纸面，落向窗外。',
        '书籍人生想做的，就是把这一刻留得更完整。你坐在喜欢的位置，文字在眼前，轻轻抬腕，下一页便接着展开。',
        '开始之前，可以在阅读菜单打开「主题与排版」；Mac 使用右上角的阅读外观按钮。选一种舒服的字号，放松行距，再把背景换成喜欢的纸色。好的阅读空间，应当适应你。',
    ]),
    ('在文字之间呼吸', [
        '书页之间，也需要留白。',
        '字与字的距离，行与行的间隔，窗边一杯温水的位置——这些细小的事情，一起构成阅读的感受。让眼睛不必寻找，让手不必总是伸出去，注意力就能自然地停在文字上。',
        'EPUB 的一页不是固定的一张纸。当你放大文字或改变窗口，段落会重新排列。我们记住的是你读到的那句话附近，而不是某个随排版改变的页码。',
        '在目录中，你可以跳到想读的章节。遇见喜欢的一页，就留下一个书签。离开的时候，无需记下位置；下次打开，继续这一段旅程。',
        '阅读并不总是从头到尾。有时我们回到某一页，只为再读一句话。有时我们跳过一段，并在更久以后才理解它。这样的自由，同样属于阅读。',
        '夜晚把灯调暗一些，换成夜读主题。屏幕不必像白天那样明亮，文字也不必急着带你抵达终点。',
    ]),
    ('下一页，仍然从容', [
        '把翻页交给手腕，把注意力留给文字。',
        '在 iPad 或 Mac 的书籍人生中打开「手表遥控」，选择「连接新设备」。在 Apple Watch 打开书籍人生，点选附近的阅读设备，核对两端数字，并在阅读设备允许连接。',
        '打开一本书后，手表会显示书名和阅读进度。直接轻点手表或转动表冠，就能继续阅读；支持双指互点的手表，也可以在唤醒时用手势继续阅读。',
        '手表通过蓝牙直接连接 iPad 或 Mac，无需 iPhone 中转。iPad 需保持阅读页面前台亮屏，Mac 需保持唤醒、阅读窗口打开且未最小化。已配对的设备会自动恢复连接。',
        '每一次确认，都来自阅读器实际到达的位置。如果连接短暂中断，书籍人生不会偷偷积攒指令，也不会在恢复连接时突然翻过几页。先看一眼眼前的书，再继续就好。',
        '这本小书到这里结束。你的阅读，才刚刚开始。',
    ])
]
output=root/'Sources/BookSlideMac/Resources/Reader/QuietHours.epub'
with ZipFile(output,'w',ZIP_DEFLATED) as z:
    z.writestr('mimetype','application/epub+zip',compress_type=ZIP_STORED)
    z.writestr('META-INF/container.xml','<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>')
    items=''.join(f'<item id="c{i}" href="chapter{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(3))
    spine=''.join(f'<itemref idref="c{i}"/>' for i in range(3))
    z.writestr('EPUB/package.opf',f'''<?xml version="1.0" encoding="UTF-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">urn:uuid:717c0b17-f978-4d18-a463-ab7b1ccdb36b</dc:identifier><dc:title>留一点时间，给阅读</dc:title><dc:creator>书籍人生 · 阅读体验</dc:creator><dc:language>zh-CN</dc:language><meta property="dcterms:modified">2026-11-09T00:00:00Z</meta></metadata><manifest>{items}<item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/><item id="style" href="style.css" media-type="text/css"/></manifest><spine>{spine}</spine></package>''')
    z.writestr('EPUB/style.css','body{font-family:"Songti SC",serif;line-height:1.85;color:#292d2b}h1{font-size:1.8em;font-weight:500;margin:1.3em 0 1.5em}p{text-align:justify;text-indent:2em;margin:0 0 1em}.eyebrow{font-family:sans-serif;font-size:.6em;letter-spacing:.2em;color:#547a63;text-indent:0}.intro{font-size:1.18em;text-indent:0;margin-bottom:2em}')
    for i,(title,paragraphs) in enumerate(chapters):
        ps=''.join(f'<p class="{"intro" if j == 0 else "body"}">{escape(text)}</p>' for j,text in enumerate(paragraphs))
        z.writestr(f'EPUB/chapter{i}.xhtml',f'<?xml version="1.0" encoding="UTF-8"?><html xmlns="http://www.w3.org/1999/xhtml" lang="zh-CN"><head><title>{title}</title><link rel="stylesheet" href="style.css"/></head><body><p class="eyebrow">booklife / 0{i+1}</p><h1>{title}</h1>{ps}</body></html>')
    links=''.join(f'<li><a href="chapter{i}.xhtml">{title}</a></li>' for i,(title,_) in enumerate(chapters))
    z.writestr('EPUB/nav.xhtml',f'<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目录</title></head><body><nav epub:type="toc"><ol>{links}</ol></nav></body></html>')
print(output)
