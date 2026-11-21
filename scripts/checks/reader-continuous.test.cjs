const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname,'../../Sources/BookSlideMac/Resources/Reader/reader-continuous.js'),'utf8');
function fixture() {
  const frames = new Map(), timers = new Map(), queued = [];
  let id = 0, loads = 0, resolveLoad;
  class Base {
    constructor() {
      this.settings = {}; this.container = {clientHeight:700,scrollTop:0,scrollLeft:0,isConnected:true};
      this.q = {enqueue:fn => new Promise(resolve => queued.push(async()=>resolve(await fn())))};
    }
    createView() { return {display:()=>{loads++;return new Promise(resolve=>{resolveLoad=resolve;});},reframe(){}}; }
    addScrollListeners() { this._scrolled = () => {}; }
    check() { assert.notEqual(this.disposed,true); return Promise.resolve(false); }
    emit() {}
    scrollTo(x,y) { this.container.scrollTop = Math.floor(y); }
    destroy() {}
  }
  const window = {};
  vm.runInNewContext(source,{window,ePub:{Rendition:{prototype:{requireManager:()=>Base}}},performance:{now:()=>0},
    requestAnimationFrame:fn=>{frames.set(++id,fn);return id;},cancelAnimationFrame:id=>frames.delete(id),
    setTimeout:fn=>{timers.set(++id,fn);return id;},clearTimeout:id=>timers.delete(id)});
  const manager = new window.BookSlideContinuous({});
  return {manager,frames,timers,queued,get loads(){return loads;},resolveLoad:value=>resolveLoad(value),
    frame(){const work=[...frames.values()];frames.clear();work.forEach(fn=>fn());}};
}
test('initial chapter loading shares one iframe load across add, check and update callers', async()=>{
  const f=fixture(), view=f.manager.createView();
  const first=view.display(), second=view.display(), third=view.display();
  assert.equal(first,second); assert.equal(first,third); assert.equal(f.loads,1);
  f.resolveLoad(view);
  assert.equal(await first,view); await second; await third;
});
test('continuous scroll work runs before input stops and coalesces while a check is pending',async()=>{
  const f=fixture(); let checks=0;
  f.manager.check=async()=>{checks++;}; f.manager.addScrollListeners();
  for(let i=0;i<100;i++) f.manager._scrolled();
  assert.equal(f.frames.size,1); f.frame(); assert.equal(f.queued.length,1);
  for(let i=0;i<100;i++) {f.manager._scrolled();f.frame();}
  assert.equal(f.queued.length,1);
  await f.queued.shift()();
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(checks,1); assert.equal(f.frames.size,1);
  f.frame(); assert.equal(f.queued.length,1);
  f.manager.destroy();
});
test('fractional chapter geometry corrections do not accumulate pixel drift',()=>{
  const f=fixture(); f.manager.container.scrollTop=1557;
  for(let i=0;i<100;i++) {f.manager.compensate(-0.015625);f.manager.compensate(0.015625);}
  assert.equal(f.manager.container.scrollTop,1557);
  f.manager.compensate(695); assert.equal(f.manager.container.scrollTop,2252);
  f.manager.compensate(-695); assert.equal(f.manager.container.scrollTop,1557);
});
test('closing the book cancels scheduled scroll and reclaim work',()=>{
  const f=fixture();f.manager.addScrollListeners();f.manager._scrolled();
  assert.equal(f.frames.size,1);assert.equal(f.timers.size,1);
  f.manager.destroy();
  assert.equal(f.frames.size,0);assert.equal(f.timers.size,0);assert.equal(f.queued.length,0);
});

test('a queued chapter check is harmless after the book closes',async()=>{
  const f=fixture();f.manager.destroy();
  assert.equal(await f.manager.check(),false);
});
