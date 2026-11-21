const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const source = fs.readFileSync(require('node:path').join(__dirname, '../../Sources/BookSlideMac/Resources/Reader/reader-scroll.js'), 'utf8');
function fixture(reduced = false) {
  let time = 0, id = 0, settled = 0;
  const frames = new Map(), window = {};
  vm.runInNewContext(source, {window, performance:{now:()=>time}, matchMedia:()=>({matches:reduced}),
    requestAnimationFrame:fn=>{frames.set(++id,fn);return id;}, cancelAnimationFrame:id=>frames.delete(id)});
  const container = {scrollTop:0, scrollHeight:5000, clientHeight:700, isConnected:true};
  const motion = new window.BookSlideScroll(container, ()=>settled++);
  const tick = (ms = 1000/60) => { time += ms; const callbacks = [...frames.values()]; frames.clear(); callbacks.forEach(fn=>fn(time)); };
  const finish = () => { for(let i=0; frames.size && i<100; i++) tick(); assert.equal(frames.size,0); };
  return {motion,container,frames,tick,finish,get settled(){return settled;}};
}
test('received crown distance is fully applied on the next frame with no settling tail', async () => {
  for (const rate of [60,120]) {
    const f=fixture(); let ack=false;
    const first=f.motion.move(136).then(()=>ack=true);
    assert.equal(ack,false); assert.equal(f.container.scrollTop,0);
    f.tick(1000/rate); await first;
    assert.equal(f.container.scrollTop,136); assert.equal(f.frames.size,0);
    f.tick(200); assert.equal(f.container.scrollTop,136);
  }
});
test('packets before one frame coalesce without losing distance or adding a queue', async () => {
  const f=fixture();
  for(let i=0;i<12;i++) await f.motion.move(34,true);
  assert.equal(f.frames.size,1); f.tick();
  assert.equal(f.container.scrollTop,408); assert.equal(f.frames.size,0);
});
test('120 Hz input follows each frame exactly', async () => {
  const f=fixture();
  for(let i=1;i<=120;i++) {
    await f.motion.move(2.125,true); f.tick(1000/120);
    assert.equal(f.container.scrollTop,i*2.125);
    assert.equal(f.frames.size,0);
  }
});
test('reversal discards undisplayed forward motion and responds on the next frame', async () => {
  const f=fixture(); f.container.scrollTop=300;
  await f.motion.move(136,true);
  await f.motion.move(-34,true); f.tick();
  assert.equal(f.container.scrollTop,266); assert.equal(f.frames.size,0);
});
test('chapter rebase retains pending distance and boundaries never overshoot', async () => {
  const f=fixture(); f.container.scrollTop=1000;
  await f.motion.move(34,true); f.container.scrollTop-=500; f.tick();
  assert.equal(f.container.scrollTop,534);
  await f.motion.move(-1000,true); f.tick(); assert.equal(f.container.scrollTop,0);
  await f.motion.move(10000,true); f.tick(); assert.equal(f.container.scrollTop,4300);
});
test('cancel and detached containers release acknowledgements without later motion', async () => {
  for(const detached of [false,true]) {
    const f=fixture(), first=f.motion.move(34);
    if(detached) {f.container.isConnected=false;f.tick();} else f.motion.cancel();
    await first; f.tick(); assert.equal(f.container.scrollTop,0); assert.equal(f.frames.size,0);
  }
});
test('reduced motion moves immediately without scheduling frames', async () => {
  const f=fixture(true); await f.motion.move(34);
  assert.equal(f.container.scrollTop,34); assert.equal(f.frames.size,0);
});
test('stream acknowledgement does not wait for the display frame', async () => {
  const f=fixture(); await f.motion.move(2.125,true);
  assert.equal(f.container.scrollTop,0); assert.equal(f.frames.size,1);
  f.tick(); assert.equal(f.container.scrollTop,2.125);
});
test('fractional samples preserve distance even on integer viewports and reduced motion', async () => {
  for (const reduced of [false,true]) {
    const f=fixture(reduced); let pixels=0;
    Object.defineProperty(f.container,'scrollTop',{get:()=>pixels,set:value=>{pixels=Math.floor(value);}});
    for(let i=0;i<16;i++) { await f.motion.move(34/16,true); f.tick(); }
    assert.equal(pixels,34); assert.equal(f.frames.size,0);
  }
});
test('local movement after completion becomes the new reference position', async () => {
  const f=fixture(); await f.motion.move(34,true); f.tick();
  f.container.scrollTop=500;
  await f.motion.move(34,true); f.tick(); assert.equal(f.container.scrollTop,534);
});
