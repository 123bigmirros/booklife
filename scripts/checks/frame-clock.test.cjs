const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../../Sources/BookSlideMac/Resources/Reader/frame-clock.js'), 'utf8');
function clock() {
  let sequence = 0;
  const frames = new Map(), timers = new Map();
  const window = {
    requestAnimationFrame(fn) { const id = ++sequence; frames.set(id, fn); return id; },
    cancelAnimationFrame(id) { frames.delete(id); }
  };
  vm.runInNewContext(source, {window, performance: {now: () => 80},
    setTimeout(fn) { const id = ++sequence; timers.set(id, fn); return id; },
    clearTimeout(id) { timers.delete(id); }});
  return {window, frames, timers};
}
test('an occluded window completes a frame once through the fallback', () => {
  const c = clock(); let count = 0;
  c.window.requestAnimationFrame(() => count++);
  const native = [...c.frames.values()][0];
  [...c.timers.values()][0](); native(90);
  assert.equal(count, 1); assert.equal(c.frames.size, 0); assert.equal(c.timers.size, 0);
});
test('normal frames cancel their fallback', () => {
  const c = clock(); let count = 0;
  c.window.requestAnimationFrame(() => count++);
  [...c.frames.values()][0](16);
  assert.equal(count, 1); assert.equal(c.timers.size, 0);
});
test('cancelled frames execute neither callback', () => {
  const c = clock(); let count = 0;
  const id = c.window.requestAnimationFrame(() => count++);
  const native = [...c.frames.values()][0], fallback = [...c.timers.values()][0];
  c.window.cancelAnimationFrame(id); native(16); fallback();
  assert.equal(count, 0); assert.equal(c.frames.size + c.timers.size, 0);
});
