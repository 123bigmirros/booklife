/* EPUB.js's trailing scroll debounce starves chapter loading during a fling.
   Its queued view.destroy also uses visibility from before a possible reversal.
   Keep the continuous manager's layout/CFI mapping, but own its scroll work and
   reclaim only after scrolling stops, using the geometry at execution time. */
(() => {
  const Continuous = ePub.Rendition.prototype.requireManager('continuous');
  window.BookSlideContinuous = class extends Continuous {
    constructor(options) {
      super(options);
      this.pendingViews = new Map();
      this.scrollFrame = null;
      this.checkQueued = false;
      this.scrollDirty = false;
      this.reclaimTimer = null;
      this.lastScrollTime = 0;
      this.disposed = false;
    }
    createView(...args) {
      const view = super.createView(...args), reframe = view.reframe.bind(view);
      const display = view.display.bind(view);
      let displaying = null;
      // add()/check()/update() can meet the same not-yet-displayed frame.
      // Loading it twice replaces iframe.onload and strands the first caller.
      view.display = (...request) => displaying ||= display(...request).finally(() => { displaying = null; });
      view.reframe = (...size) => {
        if (this.isPaginated || this.disposed || !this.preserveViewport()) return reframe(...size);
        const bounds = this.bounds();
        const anchor = this.views.all().find(v => v.displayed && this.isVisible(v,0,0,bounds));
        const top = anchor?.element.getBoundingClientRect().top;
        const result = reframe(...size);
        if (anchor?.element.isConnected) {
          this.compensate(anchor.element.getBoundingClientRect().top-top);
        }
        return result;
      };
      return view;
    }
    counter(size) {
      // A rehydrated placeholder can resize above the viewport too, even if
      // originally appended. reframe() measures both cases; avoid counting a
      // prepended chapter's height a second time here.
      if (this.isPaginated || !this.preserveViewport()) super.counter(size);
    }
    compensate(distance) {
      // Fractional DOM rects must not accumulate integer scrollTop rounding
      // errors across repeated chapter reflows or resize round trips.
      const target = Math.round(this.container.scrollTop+distance);
      if (target !== this.container.scrollTop) this.scrollTo(this.container.scrollLeft,target,true);
      this.scrollTop = this.container.scrollTop;
    }
    preserveViewport() { return this.settings.bookslidePreserveViewport?.() !== false; }
    lookahead() { return Math.max(500, this.container.clientHeight * 2); }
    addScrollListeners() {
      super.addScrollListeners();
      const debounced = this._scrolled;
      this._scrolled = () => {
        if (this.isPaginated) { debounced(); return; }
        this.lastScrollTime = performance.now();
        this.scheduleReclaim();
        this.scrollDirty = true;
        this.scheduleScroll();
      };
      this.cancelScrollDebounce = () => debounced.cancel?.();
    }
    scheduleScroll() {
      if (this.disposed || this.scrollFrame !== null || this.checkQueued) return;
      this.scrollFrame = requestAnimationFrame(() => {
        this.scrollFrame = null;
        if (this.disposed || this.isPaginated || !this.container.isConnected) return;
        this.scrollDirty = false;
        this.checkQueued = true;
        this.q.enqueue(() => this.check()).then(() => {
          if (!this.disposed) this.emit('scrolled', {top:this.scrollTop,left:this.scrollLeft});
        }).catch(error => this.emit('scrollError',error)).finally(() => {
          this.checkQueued = false;
          if (this.scrollDirty) this.scheduleScroll();
        });
        this.emit('scroll', {top:this.scrollTop,left:this.scrollLeft});
      });
    }
    async check(...args) {
      if (this.disposed || !this.container?.isConnected) return false;
      if (!this.isPaginated) this.settings.offset = this.lookahead();
      const result = await super.check(...args);
      // Upstream check() queues update() without awaiting chapter readiness.
      if (!this.disposed && !this.isPaginated) await this.update();
      return result;
    }
    update(offset) {
      if (this.disposed || !this.views) return Promise.resolve();
      if (this.isPaginated) return super.update(offset);
      const bounds = this.bounds(), buffer = Math.max(offset || 0,this.lookahead());
      const work = [];
      for (const view of this.views.all()) {
        if (!this.isVisible(view,buffer,buffer,bounds)) continue;
        if (view.displayed) { view.show(); continue; }
        let pending = this.pendingViews.get(view);
        if (!pending) {
          pending = view.display(this.request).then(() => {
            if (this.disposed || !this.views.all().includes(view)) { view.destroy(); return; }
            view.show();
          }).finally(() => this.pendingViews.delete(view));
          this.pendingViews.set(view,pending);
        }
        work.push(pending);
      }
      this.scheduleReclaim();
      return Promise.all(work);
    }
    scheduleReclaim() {
      clearTimeout(this.reclaimTimer);
      this.reclaimTimer = setTimeout(() => {
        this.reclaimTimer = null;
        if (!this.disposed && !this.isPaginated) this.q.enqueue(() => this.trim());
      },250);
    }
    trim() {
      if (this.disposed || !this.views?.length) return Promise.resolve();
      if (this.isPaginated) return super.trim();
      // The queue may have been blocked by chapter loading while the user
      // started another swipe. Never act on the timer's old visibility.
      if (performance.now()-this.lastScrollTime < 250 || this.pendingViews.size || this.scrollDirty) {
        this.scheduleReclaim();
        return Promise.resolve();
      }
      const bounds = this.bounds(), buffer = this.lookahead();
      const anchor = this.views.all().find(v => v.displayed && this.isVisible(v,0,0,bounds));
      if (!anchor) return Promise.resolve();
      const top = anchor.element.getBoundingClientRect().top;
      for (const view of this.views.all()) {
        if (view.displayed && !this.isVisible(view,buffer,buffer,bounds)) view.destroy();
      }
      const result = super.trim();
      // Use measured geometry even if a chapter's cached height changed.
      this.compensate(anchor.element.getBoundingClientRect().top-top);
      return result;
    }
    destroy() {
      this.disposed = true;
      if (this.scrollFrame !== null) cancelAnimationFrame(this.scrollFrame);
      clearTimeout(this.reclaimTimer);
      clearTimeout(this.trimTimeout);
      this.cancelScrollDebounce?.();
      super.destroy();
    }
  };
})();
