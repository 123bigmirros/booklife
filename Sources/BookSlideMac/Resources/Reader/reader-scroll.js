/* Crown distance follows the next display frame. Network packets may coalesce,
   but the reader adds no easing delay or motion after the received destination. */
(() => {
  window.BookSlideScroll = class {
    constructor(container, settled) {
      this.container = container;
      this.settled = settled;
      this.target = this.lastPosition = container.scrollTop;
      this.frame = null;
      this.waiters = [];
      this.direction = 0;
    }
    destination(distance) {
      this.rebase();
      const base = Math.sign(distance) === this.direction ? this.target : this.container.scrollTop;
      return Math.max(0, Math.min(this.container.scrollHeight-this.container.clientHeight, base+distance));
    }
    rebase() {
      // EPUB may insert/remove chapters above the viewport. Carry the pending
      // destination with that adjustment, without inventing crown movement.
      if (this.frame !== null) {
        this.target += this.container.scrollTop-this.lastPosition;
      } else if (this.container.scrollTop !== this.lastPosition) {
        this.target = this.container.scrollTop;
        this.direction = 0;
      }
      this.lastPosition = this.container.scrollTop;
    }
    move(distance, acceptInput = false) {
      this.target = this.destination(distance);
      this.direction = Math.sign(distance);
      if (matchMedia('(prefers-reduced-motion: reduce)').matches) {
        if (this.frame !== null) cancelAnimationFrame(this.frame);
        this.tick();
        return Promise.resolve();
      }
      const firstFrame = acceptInput ? Promise.resolve() : new Promise(resolve => this.waiters.push(resolve));
      if (this.frame === null) this.frame = requestAnimationFrame(() => this.tick());
      return firstFrame;
    }
    tick() {
      if (!this.container.isConnected) { this.cancel(); return; }
      this.rebase();
      this.target = Math.max(0, Math.min(this.container.scrollHeight-this.container.clientHeight, this.target));
      // Retain a fractional target even when WebKit rounds scrollTop to an
      // integer, so sixteen 1/16-line samples still add up to one full line.
      this.container.scrollTop = this.target;
      this.lastPosition = this.container.scrollTop;
      this.frame = null;
      for (const resolve of this.waiters.splice(0)) resolve();
      this.settled();
    }
    cancel() {
      if (this.frame !== null) cancelAnimationFrame(this.frame);
      this.frame = null;
      this.direction = 0;
      for (const resolve of this.waiters.splice(0)) resolve();
    }
  };
})();
