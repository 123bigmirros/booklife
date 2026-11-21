const {test} = require('node:test');
const assert = require('node:assert/strict');
const {install} = require('../../Sources/BookSlideMac/Resources/Reader/reader-input.js');
function setup(selection = '') {
  const listeners = {}, calls = [];
  install({defaultView:{getSelection:() => selection},addEventListener:(name,fn) => listeners[name] = fn},dir => calls.push(dir));
  return {listeners,calls};
}
test('trackpad inertia produces one page command per gesture', () => {
  const {listeners,calls} = setup();
  for (let i=0;i<20;i++) listeners.wheel({deltaY:20,deltaX:0,preventDefault(){}});
  assert.deepEqual(calls,['next']);
});
test('upward wheel turns previous and zoom is left alone', () => {
  const {listeners,calls} = setup();
  listeners.wheel({deltaY:200,ctrlKey:true});
  listeners.wheel({deltaY:-100,deltaX:0,preventDefault(){}});
  assert.deepEqual(calls,['previous']);
});
test('text selection does not turn pages', () => {
  const {listeners,calls} = setup('selected text');
  listeners.wheel({deltaY:100,deltaX:0});
  listeners.touchstart({touches:[{clientX:200,clientY:100}]});
  listeners.touchend({touches:[],changedTouches:[{clientX:20,clientY:100}]});
  assert.deepEqual(calls,[]);
});
test('upward swipe advances and a tap does nothing', () => {
  const {listeners,calls} = setup();
  listeners.touchstart({touches:[{clientX:100,clientY:200}]});
  listeners.touchend({touches:[],changedTouches:[{clientX:100,clientY:40}]});
  listeners.touchstart({touches:[{clientX:100,clientY:100}]});
  listeners.touchend({touches:[],changedTouches:[{clientX:100,clientY:105}]});
  assert.deepEqual(calls,['next']);
});
function touchReader(selection = '') {
  const listeners = {}, calls = [], taps = [];
  install({defaultView:{innerWidth:390,getSelection:() => selection},addEventListener:(name,fn) => listeners[name] = fn},dir => calls.push(dir),{tap:action => taps.push(action)});
  const tap = (x,y=120,target) => {
    listeners.touchstart({target,touches:[{clientX:x,clientY:y}]});
    listeners.touchend({touches:[],changedTouches:[{clientX:x,clientY:y}]});
  };
  return {listeners,calls,taps,tap};
}
test('single tap in the body reveals tools without turning a page', async () => {
  const reader = touchReader(); reader.tap(195);
  await new Promise(resolve => setTimeout(resolve,320));
  assert.deepEqual(reader.taps,['controls']); assert.deepEqual(reader.calls,[]);
});
test('page edges are previous and next without visible buttons', async () => {
  const left = touchReader(), right = touchReader(); left.tap(20); right.tap(370);
  await new Promise(resolve => setTimeout(resolve,320));
  assert.deepEqual(left.taps,['previous']); assert.deepEqual(right.taps,['next']);
});
test('double tap, links and selected text never become edge page turns', async () => {
  const double = touchReader(), link = touchReader(), selected = touchReader('选中文字');
  double.tap(370); double.tap(370);
  link.tap(370,120,{closest:() => true}); selected.tap(370);
  await new Promise(resolve => setTimeout(resolve,320));
  assert.deepEqual(double.taps,[]); assert.deepEqual(link.taps,[]); assert.deepEqual(selected.taps,[]);
});
test('a swipe cancels a pending tap and multi-touch remains native', async () => {
  const reader = touchReader(); reader.tap(195);
  reader.listeners.touchstart({touches:[{clientX:300,clientY:120}]});
  reader.listeners.touchend({touches:[],changedTouches:[{clientX:100,clientY:120}]});
  reader.listeners.touchstart({touches:[{clientX:300,clientY:120}]});
  reader.listeners.touchmove({touches:[{},{}]});
  reader.listeners.touchend({touches:[],changedTouches:[{clientX:100,clientY:120}]});
  await new Promise(resolve => setTimeout(resolve,320));
  assert.deepEqual(reader.calls,['next']); assert.deepEqual(reader.taps,[]);
});

test('scroll mode leaves the wheel and touch drag native; switching back restores paging', () => {
  const listeners = {}, turns = []; let scrolling = true, prevented = 0;
  install({defaultView:{getSelection:()=>''},addEventListener:(name,fn)=>listeners[name]=fn},
          direction=>turns.push(direction), {scrolling:()=>scrolling});
  listeners.wheel({deltaY:120,deltaX:0,preventDefault(){prevented++;}});
  listeners.touchstart({touches:[{clientX:100,clientY:300}]});
  listeners.touchend({touches:[],changedTouches:[{clientX:100,clientY:50}]});
  assert.equal(prevented,0); assert.deepEqual(turns,[]);
  scrolling = false;
  listeners.wheel({deltaY:120,deltaX:0,preventDefault(){prevented++;}});
  assert.equal(prevented,1); assert.deepEqual(turns,['next']);
});
