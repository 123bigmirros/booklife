/* Annotation UI lives in the trusted host. Never enable scripts in EPUB frames. */
(() => {
  const colors = {yellow:'#f4d35e',green:'#8dce88',blue:'#85bde8',pink:'#efa4b7',purple:'#c1a2df',underline:'#da735c'};
  const titles = {yellow:'黄色',green:'绿色',blue:'蓝色',pink:'粉色',purple:'紫色',underline:'下划线'};
  class ReaderAnnotations {
    constructor(post) {
      this.post = post;
      this.items = [];
      this.renderedItems = new Map();
      this.pencilGraphemes = new WeakMap();
      this.menu = document.createElement('div');
      this.menu.id = 'annotation-menu';
      this.menu.setAttribute('role','dialog');
      this.menu.setAttribute('aria-label','高亮与笔记');
      this.menu.hidden = true;
      document.body.append(this.menu);
      // Preserve the book selection when a mouse clicks the host's controls.
      this.menu.addEventListener('mousedown', e => e.preventDefault());
      // Native recognizers observe the same click slightly later than the DOM.
      this.menu.addEventListener('click', () => { this.ignoreTapUntil = performance.now()+200; },true);
      document.addEventListener('pointerdown', e => { if (!this.menu.contains(e.target)) this.dismiss(); });
      document.addEventListener('keydown', e => { if (e.key === 'Escape') this.dismiss(true); });
      window.addEventListener('resize', () => { if (!this.nativeMenu) this.dismiss(true); });
    }
    attach(rendition, book, settings) {
      this.detach();
      this.rendition = rendition; this.book = book;
      this.session = settings.annotationSession;
      this.lastColor = colors[settings.annotationColor] ? settings.annotationColor : 'yellow';
      this.theme = settings.theme;
      this.nativeMenu = !!settings.nativeAnnotationMenu;
      this.nativeTouchControls = !!settings.nativeTouchControls;
      this.setItems(settings.annotations || []);
      // WebKit suppresses frame event callbacks in script-disabled documents.
      // Poll only while a book is open; native selection handles remain active.
      this.timer = setInterval(() => this.poll(),180);
    }
    detach() {
      clearInterval(this.timer); this.timer = null;
      this.dismiss(true);
      for (const item of this.renderedItems.values()) {
        try { this.rendition?.annotations.remove(item.cfi,item.color === 'underline' ? 'underline' : 'highlight'); } catch (_) {}
      }
      this.renderedItems.clear(); this.pencilGraphemes = new WeakMap();
      this.rendition = null; this.book = null; this.items = []; this.session = null;
    }
    setItems(items) {
      if (!this.rendition) return;
      this.items = items.filter(i => colors[i.color] && i.cfi?.startsWith('epubcfi('));
      const key = item => `${item.cfi}|${item.color === 'underline' ? 'underline' : 'highlight'}`;
      const next = new Map(this.items.map(item=>[key(item),item]));
      for (const [id,rendered] of this.renderedItems) {
        const item = next.get(id);
        if (item && item.id === rendered.id && item.color === rendered.color && rendered.theme === this.theme) continue;
        this.rendition.annotations.remove(rendered.cfi,rendered.color === 'underline' ? 'underline' : 'highlight');
        this.renderedItems.delete(id);
      }
      for (const [id,item] of next) {
        if (this.renderedItems.has(id)) continue;
        const underline = item.color === 'underline';
        const styles = underline
          ? {stroke:colors.underline,'stroke-opacity':'1','stroke-width':'2','mix-blend-mode':'normal','pointer-events':'none'}
          : {fill:colors[item.color],'fill-opacity':this.theme === 'night' ? '0.42' : '0.38','mix-blend-mode':this.theme === 'night' ? 'screen' : 'multiply','pointer-events':'none'};
        try {
          this.rendition.annotations[underline ? 'underline' : 'highlight'](item.cfi,{id:item.id},null,'bookslide-highlight',styles);
          this.renderedItems.set(id,{id:item.id,cfi:item.cfi,color:item.color,theme:this.theme});
        } catch (_) { /* One stale range must not prevent opening a book. */ }
      }
      if (this.active) {
        const saved = this.items.find(item=>item.cfi === this.active.cfi);
        if (saved) this.active = {...saved};
      }
    }
    restyle(theme) {
      if (theme === this.theme) return;
      this.theme = theme; this.setItems([...this.items]);
      if (!this.nativeMenu) this.dismiss(true);
    }
    clearSelection() {
      this.pencilRange = null; this.selectionSnapshot = null;
      for (const c of this.rendition?.getContents() || []) c.window.getSelection()?.removeAllRanges();
    }
    pencilGlyph(contents,x,y) {
      const doc = contents.document, caret = doc.caretRangeFromPoint(x,y);
      if (!caret || caret.startContainer.nodeType !== 3) return null;
      const node = caret.startContainer;
      this.pencilGraphemes ||= new WeakMap();
      let cached = this.pencilGraphemes.get(node);
      if (!cached || cached.text !== node.data) {
        cached = {text:node.data,segments:new Intl.Segmenter(undefined,{granularity:'grapheme'}).segment(node.data)};
        this.pencilGraphemes.set(node,cached);
      }
      if (!node.length) return null;
      const segments = cached.segments, part = segments.containing(Math.min(node.length-1,caret.startOffset));
      if (!part) return null;
      const candidates = [segments.containing(Math.max(0,part.index-1)),part,segments.containing(part.index+part.segment.length)];
      let best = null, distance = Infinity;
      // A caret rounds to either edge of a glyph. Compare the actual adjacent
      // glyph rectangles so the character under the tip is included exactly.
      for (const part of [...new Map(candidates.filter(Boolean).map(part=>[part.index,part])).values()]) {
        const range = doc.createRange();
        range.setStart(node,part.index); range.setEnd(node,part.index+part.segment.length);
        for (const rect of range.getClientRects()) {
          if (rect.width <= 0 || rect.height <= 0) continue;
          const dx = Math.max(rect.left-x,0,x-rect.right), dy = Math.max(rect.top-y,0,y-rect.bottom);
          const score = dx*dx+dy*dy;
          if (score < distance) { best = range; distance = score; }
        }
      }
      return best;
    }
    pencilSelect(x,y,phase) {
      if (phase === 'cancel') { this.dismiss(true); return false; }
      if (phase === 'end') {
        if (!this.pencilRange) return false;
        // Capture the lift location too, even if a move was coalesced or UIKit
        // did not deliver another changed callback immediately before lift.
        this.pencilSelect(x,y,'extend'); this.poll(true);
        if (!this.active) return false;
        const existing = this.items.find(item => item.cfi === this.active.cfi);
        const color = existing?.color || (this.lastColor === 'underline' ? 'yellow' : this.lastColor);
        this.pencilRange = null;
        this.emit('annotationPencilHighlight',{...this.active,color,x,y});
        return true;
      }
      if (!this.rendition) return false;
      if (phase === 'begin') this.clearSelection();
      for (const contents of this.rendition.getContents()) {
        const frame = contents.document.defaultView.frameElement.getBoundingClientRect();
        if (x < frame.left || x > frame.right || y < frame.top || y > frame.bottom) continue;
        const glyph = this.pencilGlyph(contents,x-frame.left,y-frame.top);
        if (!glyph) return false;
        let range;
        if (phase === 'begin') {
          if (!glyph.toString().trim()) return false;
          range = glyph.cloneRange();
          this.pencilRange = {contents,anchor:range.cloneRange()};
        } else {
          const saved = this.pencilRange;
          if (!saved || saved.contents !== contents) return false;
          range = saved.anchor.cloneRange();
          if (glyph.compareBoundaryPoints(Range.START_TO_START,range) < 0) range.setStart(glyph.startContainer,glyph.startOffset);
          else range.setEnd(glyph.endContainer,glyph.endOffset);
        }
        const selection = contents.window.getSelection();
        const previous = selection.rangeCount ? selection.getRangeAt(0) : null;
        if (!previous || previous.startContainer !== range.startContainer || previous.startOffset !== range.startOffset ||
            previous.endContainer !== range.endContainer || previous.endOffset !== range.endOffset) {
          selection.setBaseAndExtent(range.startContainer,range.startOffset,range.endContainer,range.endOffset);
        }
        // Changing the native selection is enough for live feedback. Avoid CFI
        // generation, quote extraction and SwiftUI updates on every drag sample.
        if (phase === 'begin') {
          if (this.nativeMenu && this.nativeTouchControls) this.announceSelection();
          else this.poll(true);
        }
        return true;
      }
      return false;
    }
    dismiss(clear = false) {
      if (this.nativeMenu && (this.active || this.selectionAnnounced)) this.post('annotationSelection',null);
      this.selectionAnnounced = false; this.selectionSnapshot = null;
      this.menu.hidden = true; this.active = null; this.activeContents = null;
      if (clear) { this.clearSelection(); this.selectionKey = null; }
    }
    dismissSelection(id,cfi) {
      // A menu can finish closing after the next drag has already begun.
      // Only clear the selection that menu actually belongs to.
      if (this.pencilRange || (this.active && (this.active.id !== id || this.active.cfi !== cfi))) return false;
      for (const contents of this.rendition?.getContents() || []) {
        const selection = contents.window.getSelection();
        if (!selection?.rangeCount || selection.isCollapsed) continue;
        try { if (contents.cfiFromRange(selection.getRangeAt(0)) !== cfi) return false; }
        catch (_) { return false; }
      }
      this.dismiss(true);
      return true;
    }
    rects(contents, range) {
      const frame = contents.document.defaultView.frameElement.getBoundingClientRect();
      return Array.from(range.getClientRects()).filter(r => r.width > 0 && r.height > 0).map(r => ({
        left:r.left+frame.left, right:r.right+frame.left, top:r.top+frame.top, bottom:r.bottom+frame.top
      }));
    }
    announceSelection(item = {}) {
      if (!this.selectionAnnounced || item.cfi) {
        this.selectionAnnounced = true;
        this.emit('annotationSelection',item);
      }
    }
    poll(force = false) {
      if (this.pencilRange && !force) return;
      // Retain the selection context even while a host is occluded. A native
      // right click can arrive before WebKit updates its visibility state.
      if (!this.rendition) return;
      // Ignore selections in prefetched chapters outside the viewport.
      for (const contents of this.rendition.getContents()) {
        const selection = contents.window.getSelection();
        if (!selection?.rangeCount || selection.isCollapsed) continue;
        const range = selection.getRangeAt(0);
        const saved = this.selectionSnapshot;
        const same = saved && saved.contents === contents && saved.start === range.startContainer && saved.startOffset === range.startOffset &&
          saved.end === range.endContainer && saved.endOffset === range.endOffset;
        if (this.nativeMenu && this.nativeTouchControls && !force) {
          if (!same) { this.active = null; this.activeContents = null; this.selectionKey = null; }
          // UIKit owns the live handles and menu. Dragging only announces the
          // presence of a selection; the menu requests rich context on demand.
          this.announceSelection();
          return;
        }
        if (same && this.active) {
          if (!this.menu.hidden) this.position(contents,range);
          return;
        }
        if (!range.toString().trim()) continue;
        const rects = this.rects(contents,range);
        if (!rects.some(r => r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth)) continue;
        let cfi;
        try { cfi = contents.cfiFromRange(range); } catch (_) { continue; }
        if (this.selectionKey === cfi && this.active) {
          if (!this.menu.hidden) this.position(contents,range);
          return;
        }
        this.selectionKey = cfi;
        this.selectionSnapshot = {contents,start:range.startContainer,startOffset:range.startOffset,end:range.endContainer,endOffset:range.endOffset};
        // Selecting an already highlighted range edits it instead of duplicating it.
        const existing = this.items.find(i => i.cfi === cfi);
        const section = this.book.spine.get(contents.sectionIndex);
        const chapter = window.reader.annotationChapter(cfi,contents);
        const spine = this.book.spine.spineItems.filter(s => s.linear);
        const fraction = (Math.max(0,spine.findIndex(s => s.index === contents.sectionIndex)) + BookSlideProgress.capture(contents,cfi,section.href).fraction) / Math.max(1,spine.length);
        this.show(existing || {id:crypto.randomUUID(),cfi,quote:range.toString(),chapter:chapter || section?.href || '',chapterHref:window.reader.annotationChapterHref(cfi,contents),progress:Math.max(0,Math.min(1,fraction || 0)),color:this.lastColor,note:''},contents,range);
        return;
      }
      this.selectionKey = null;
      if (this.nativeMenu) { this.dismiss(); return; }
      if (this.active && !this.items.some(i => i.id === this.active.id)) this.dismiss();
      else if (this.active) {
        try { this.position(this.activeContents,this.activeContents.range(this.active.cfi)); }
        catch (_) { this.dismiss(); }
      }
    }
    tap(x,y) {
      if (!this.rendition) return false;
      if (performance.now() < (this.ignoreTapUntil || 0)) return true;
      if (!this.menu.hidden) {
        const r = this.menu.getBoundingClientRect();
        if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) return true;
      }
      for (const c of this.rendition.getContents()) if (c.window.getSelection()?.toString().trim()) return true;
      // Native hit testing also works where WebKit suppresses frame callbacks.
      for (const contents of this.rendition.getContents()) {
        const frame = contents.document.defaultView.frameElement.getBoundingClientRect();
        if (x < frame.left || x > frame.right || y < frame.top || y > frame.bottom) continue;
        const target = contents.document.elementFromPoint(x-frame.left,y-frame.top);
        if (target?.closest('a,button,input,textarea,select,[contenteditable="true"]')) return false;
        for (const item of [...this.items].reverse()) {
          try {
            if (new ePub.CFI(item.cfi).spinePos !== contents.sectionIndex) continue;
            const range = contents.range(item.cfi);
            if (this.rects(contents,range).some(r => x >= r.left-2 && x <= r.right+2 && y >= r.top && y <= r.bottom)) {
              this.show(item,contents,range);
              if (this.nativeMenu) this.emit('annotationMenu',{...item,existing:true,x,y});
              return true;
            }
          } catch (_) { /* The range belongs to another chapter. */ }
        }
      }
      if (!this.menu.hidden) { this.dismiss(true); return true; }
      return false;
    }
    button(label,action) {
      const button = document.createElement('button'); button.type = 'button';
      button.textContent = label; button.addEventListener('click',action);
      return button;
    }
    emit(type,item) { this.post(type,{session:this.session,...item}); }
    show(item,contents,range) {
      this.active = {...item}; this.activeContents = contents;
      if (this.nativeMenu) {
        this.menu.hidden = true;
        this.announceSelection({...item,existing:this.items.some(i=>i.id === item.id)});
        return;
      }
      this.menu.replaceChildren(); this.menu.dataset.theme = this.theme;
      const existing = this.items.some(i => i.id === item.id);
      const header = document.createElement('div'); header.className = 'annotation-header';
      const title = document.createElement('span'); title.textContent = existing ? '高亮与笔记' : '选择颜色即可高亮';
      const close = this.button('×',() => this.dismiss(true)); close.className = 'annotation-close'; close.setAttribute('aria-label','关闭高亮与笔记');
      header.append(title,close); this.menu.append(header);
      const palette = document.createElement('div'); palette.className = 'annotation-colors';
      for (const [color,hex] of Object.entries(colors)) {
        const button = this.button(color === 'underline' ? 'U' : '',() => this.applyColor(color));
        button.className = 'annotation-color'; button.style.setProperty('--swatch',hex);
        button.dataset.color = color; button.setAttribute('aria-label',titles[color]); button.title = titles[color];
        button.setAttribute('aria-pressed',String(existing && item.color === color)); palette.append(button);
      }
      this.menu.append(palette);
      if (item.note) { const preview = document.createElement('p'); preview.className = 'annotation-preview'; preview.textContent = item.note; this.menu.append(preview); }
      const actions = document.createElement('div'); actions.className = 'annotation-actions';
      actions.append(this.button(item.note ? '编辑笔记' : '写笔记',() => {
        this.emit('annotationEdit',this.active); this.dismiss(true);
      }));
      actions.append(this.button('问 AI',() => {
        this.emit('annotationDiscuss',this.active); this.dismiss(true);
      }));
      actions.append(this.button('翻译',() => {
        this.emit('annotationTranslate',this.active); this.dismiss(true);
      }));
      if (this.items.some(i => i.id === item.id)) {
        const remove = this.button('移除标记',() => { this.emit('annotationRemove',{id:item.id}); this.dismiss(true); });
        remove.className = 'annotation-remove'; actions.append(remove);
      }
      this.menu.append(actions); this.menu.hidden = false; this.position(contents,range);
    }
    applyColor(color) {
      if (!this.active || !colors[color]) return;
      this.lastColor = color;
      this.emit('annotationChange',{...this.active,color}); this.dismiss(true);
    }
    position(contents,range) {
      const visible = this.rects(contents,range).filter(r => r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth);
      if (!visible.length) { this.dismiss(); return; }
      // Anchor to the whole visible selection, so a multiline highlight is not
      // covered by a menu placed just beneath its first line.
      const rect = {left:Math.min(...visible.map(r=>r.left)),right:Math.max(...visible.map(r=>r.right)),
        top:Math.max(0,Math.min(...visible.map(r=>r.top))),bottom:Math.min(innerHeight,Math.max(...visible.map(r=>r.bottom)))};
      const width = this.menu.offsetWidth, height = this.menu.offsetHeight;
      this.menu.style.left = `${Math.max(8,Math.min(innerWidth-width-8,(rect.left+rect.right-width)/2))}px`;
      this.menu.style.top = `${Math.max(8,Math.min(innerHeight-height-8,rect.top > height+16 ? rect.top-height-10 : rect.bottom+10))}px`;
    }
  }
  window.BookSlideAnnotations = ReaderAnnotations;
})();
