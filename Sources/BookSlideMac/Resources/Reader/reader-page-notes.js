/* Ink overlays follow a text anchor only when the original layout matches. */
(() => {
  class PageNotes {
    constructor(post) {
      this.post = post; this.lastVisibility = ''; this.visible = []; this.hidden = [];
      this.layer = document.createElement('div'); this.layer.id = 'page-note-layer';
      Object.assign(this.layer.style,{position:'fixed',inset:'0',overflow:'hidden',pointerEvents:'none',zIndex:'20'});
      this.layer.setAttribute('aria-hidden','true'); document.body.append(this.layer);
      this.items = []; this.images = new Map();
    }
    attach(rendition,session,items) {
      this.detach(); this.rendition = rendition; this.session = session; this.setItems(items || []);
      this.container = rendition.manager.container;
      this.scroll = () => this.render();
      this.container.addEventListener('scroll',this.scroll,{passive:true});
      this.timer = setInterval(()=>this.render(),120);
    }
    detach() {
      this.container?.removeEventListener('scroll',this.scroll); this.container = null; this.scroll = null;
      clearInterval(this.timer); this.timer = null; this.rendition = null; this.session = null;
      this.items = []; this.images.clear(); this.layer.replaceChildren();
      this.visible = []; this.hidden = []; this.lastVisibility = ''; this.editingID = null; this.layer.style.visibility = '';
    }
    setItems(items) {
      this.items = items; this.images.clear(); this.layer.replaceChildren(); this.render();
    }
    edit(id) { this.editingID = id; this.render(); }
    render() {
      if (!this.rendition) return;
      const key = window.reader.pageNoteLayoutKey(), contents = this.rendition.getContents();
      const visible = [], hidden = [];
      for (const note of this.items) {
       const parts=note.parts?.length ? note.parts : [{id:note.id,assetID:note.assetID,anchor:note.anchor,canvasID:note.id}];
       for(const part of parts){
        let image = this.images.get(part.id);
        if (!image) {
          if (!/^[0-9a-f-]{36}$/i.test(part.assetID)) continue;
          image = document.createElement('img'); image.alt = '';
          Object.assign(image.style,{position:'absolute',pointerEvents:'none',maxWidth:'none',display:'none'});
          image.src = `bookslide-ink://${part.assetID}/ink.png`;
          this.layer.append(image); this.images.set(part.id,image);
        }
        image.style.display = 'none';
        image.style.visibility = part.canvasID === this.editingID || note.id === this.editingID ? 'hidden' : '';
        try {
          const index = new ePub.CFI(part.anchor.locator).spinePos;
          const c = contents.find(c=>c.sectionIndex === index); if (!c) continue;
          const range = c.range(part.anchor.locator), rect = range.getBoundingClientRect();
          const frame = c.document.defaultView.frameElement.getBoundingClientRect();
          if (part.anchor.layoutKey !== key) {
            if (frame.top+rect.bottom > 0 && frame.top+rect.top < innerHeight && frame.left+rect.right > 0 && frame.left+rect.left < innerWidth) {
              visible.push(note.id); hidden.push(note.id);
            }
            continue;
          }
          const x = frame.left+rect.left-part.anchor.referenceX, y = frame.top+rect.top-part.anchor.referenceY;
          if (y+part.anchor.viewportHeight < 0 || y > innerHeight || x+part.anchor.viewportWidth < 0 || x > innerWidth) continue;
          visible.push(note.id);
          Object.assign(image.style,{left:`${x}px`,top:`${y}px`,width:`${part.anchor.viewportWidth}px`,height:`${part.anchor.viewportHeight}px`,display:'block'});
        } catch (_) { /* An unloaded chapter or stale anchor never breaks reading. */ }
       }
      }
      const uniqueVisible=[...new Set(visible)], uniqueHidden=[...new Set(hidden)];
      this.visible = uniqueVisible; this.hidden = uniqueHidden;
      const signature = JSON.stringify([uniqueVisible,uniqueHidden]);
      if (signature !== this.lastVisibility) {
        this.lastVisibility = signature;
        this.post?.('pageNoteVisibility',{session:this.session,visible:uniqueVisible,hidden:uniqueHidden});
      }
    }
  }
  window.BookSlidePageNotes = PageNotes;
})();
