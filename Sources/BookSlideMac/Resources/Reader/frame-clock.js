/* WebKit pauses animation frames in occluded native windows. EPUB layout queues
   still need to finish a user-initiated operation and return an acknowledgement.
   Each requested frame gets one bounded fallback; no idle polling is introduced. */
(() => {
  const request = window.requestAnimationFrame.bind(window);
  const cancel = window.cancelAnimationFrame.bind(window);
  const pending = new Map();
  let sequence = 0;
  window.requestAnimationFrame = callback => {
    const id = --sequence;
    const entry = {native:0,timer:0};
    function run(time) {
      if (!pending.has(id)) return;
      pending.delete(id); clearTimeout(entry.timer); cancel(entry.native);
      callback(time);
    }
    pending.set(id,entry);
    entry.native = request(run);
    entry.timer = setTimeout(() => run(performance.now()),80);
    return id;
  };
  window.cancelAnimationFrame = id => {
    const entry = pending.get(id);
    if (entry) { clearTimeout(entry.timer); cancel(entry.native); pending.delete(id); }
    else cancel(id);
  };
})();
