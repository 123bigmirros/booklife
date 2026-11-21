/* One page per wheel gesture; touch swipes leave taps, links and selections intact. */
(function(root) {
  function install(document, turn, options = {}) {
    let distance = 0, fired = false, timer, touch, tapTimer, lastTap;
    const selected = () => !!document.defaultView?.getSelection()?.toString();
    const interactive = event => event.target?.closest?.('a,button,input,textarea,select,[contenteditable="true"]');
    document.addEventListener('wheel', event => {
      if (options.scrolling?.() || event.ctrlKey || event.metaKey || selected() || interactive(event)) return;
      const delta = Math.abs(event.deltaY) >= Math.abs(event.deltaX) ? event.deltaY : event.deltaX;
      if (!delta) return;
      event.preventDefault();
      clearTimeout(timer);
      timer = setTimeout(() => { distance = 0; fired = false; },180);
      if (fired) return;
      distance += delta * (event.deltaMode === 1 ? 20 : event.deltaMode === 2 ? 200 : 1);
      if (Math.abs(distance) >= 70) { fired = true; turn(distance > 0 ? 'next' : 'previous'); }
    },{passive:false});
    document.addEventListener('touchstart', event => {
      touch = event.touches.length === 1 && !interactive(event) ? {x:event.touches[0].clientX,y:event.touches[0].clientY,time:Date.now()} : null;
    },{passive:true});
    document.addEventListener('touchmove', event => { if (event.touches.length !== 1) touch = null; },{passive:true});
    document.addEventListener('touchcancel', () => { touch = null; clearTimeout(tapTimer); });
    document.addEventListener('touchend', event => {
      const start = touch; touch = null;
      if (!start || event.touches.length || selected() || !event.changedTouches.length || Date.now() - start.time > 800) return;
      const end = event.changedTouches[0], dx = end.clientX - start.x, dy = end.clientY - start.y;
      const delta = Math.abs(dx) > Math.abs(dy) ? dx : dy;
      if (Math.abs(delta) > 45) {
        if (options.scrolling?.()) return;
        clearTimeout(tapTimer); lastTap = null;
        turn(delta < 0 ? 'next' : 'previous');
      } else if (options.tap && Math.abs(dx) < 12 && Math.abs(dy) < 12 && Date.now() - start.time < 300) {
        const now = Date.now();
        // Leave double-tap word selection to WebKit, including at the page edges.
        if (lastTap && now - lastTap.time < 320 && Math.abs(end.clientX - lastTap.x) < 24 && Math.abs(end.clientY - lastTap.y) < 24) {
          clearTimeout(tapTimer); lastTap = null; return;
        }
        lastTap = {time:now,x:end.clientX,y:end.clientY};
        clearTimeout(tapTimer);
        tapTimer = setTimeout(() => {
          if (selected()) return;
          const width = document.defaultView?.innerWidth || 390;
          const edge = Math.min(72,width * 0.18);
          options.tap(end.clientX < edge ? 'previous' : end.clientX > width - edge ? 'next' : 'controls');
        },280);
      }
    },{passive:true});
  }
  root.BookSlideInput = {install};
  if (typeof module !== 'undefined') module.exports = {install};
})(typeof window !== 'undefined' ? window : globalThis);
