import MindElixir from './vendor/MindElixir.js';
let mind, session, documentVersion, suppress = false, selected, editor = false, connectionSource = null, connectionTarget = null, notice = '';
let lastCommand, lastFrame = 0, ready = false, saving = false, pending = false, lastSent, lastSaved, lastTheme, unsaved = false;
let savedTopics=new Map(), sentTopics;
const hint = document.getElementById('hint'), connection = document.getElementById('connect');
const nodeStatus = document.getElementById('node-status'), relation = document.getElementById('relation');
const dragStatus = document.getElementById('drag-status');
let touchDrag = null, lastNodeTap = null, mergeSource = null, lastGroupEdit = -1000;
let expandedNodeID = null, expandedSize = null, expansionFrame = null;
let lastContentTap = null, selectionRevision = 0;
const post = (type,value={}) => window.webkit?.messageHandlers.mindmap.postMessage({type,session,...value});
const virtual = node => ['book','chapter'].includes(node?.metadata?.kind);
const signature = data => {
  const topic=n=>[n.id,n.topic,n.expanded??true,n.direction??1,n.note??'',n.metadata?.name??'',n.metadata?.summary??'',n.metadata?.chapterTitle??'',n.metadata?.inkParts??[],n.metadata?.inkEntityIDs??[],(n.children||[]).map(topic)];
  return JSON.stringify([topic(data.nodeData),(data.arrows||[]).map(a=>[a.id,a.from,a.to,a.label]).sort((a,b)=>a[0].localeCompare(b[0]))]);
};
function nodesIn(data) {
  const nodes=new Map();
  const visit=node=>{nodes.set(node.id,node);for(const child of node.children || [])visit(child);};
  visit(data.nodeData);
  return nodes;
}
const topicsIn=data=>new Map([...nodesIn(data)].map(([id,node])=>[id,node.topic]));
const snapshot = () => {
  const data = mind.getData();
  // The engine retains cross-links when removing a branch. Exclude their
  // missing endpoints from the persisted document, but retain the engine's
  // history so undo can restore the branch and its connections together.
  const topics=topicsIn(data);
  return {nodeData:data.nodeData,arrows:(data.arrows || []).filter(a=>topics.has(a.from) && topics.has(a.to)),direction:data.direction ?? 1,
    editedTopics:[...topics].filter(([id,text])=>savedTopics.get(id)!==text).map(([id])=>id)};
};
function rectFor(id) { try { const r=mind.findEle(id).getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height}; } catch { return null; } }
const isInk=node=>node?.metadata?.kind==='ink';
const canEditTopic=node=>!!node && !virtual(node) && !isInk(node);
function titleFor(id) {
  try{
    const node=mind.findEle(id).nodeObj;
    return (node.metadata?.name || (isInk(node) ? node.metadata.inkParts?.[0]?.quote || '手写标记' : node.topic)).slice(0,80);
  }catch{return '节点';}
}
function nodeTools() {
  document.getElementById('cancel-link').hidden=!connectionSource && !mergeSource;
  document.getElementById('cancel-link').textContent=mergeSource ? '取消合并' : '取消连线';
  document.querySelectorAll('.book-connection-source,.book-connection-target').forEach(el=>el.classList.remove('book-connection-source','book-connection-target'));
  if(connectionSource==='__pick__')nodeStatus.textContent='选择连线起点，例如一条笔记。';
  else if(connectionSource){
    try{mind.findEle(connectionSource).classList.add('book-connection-source');}catch{}
    if(connectionTarget){
      try{mind.findEle(connectionTarget).classList.add('book-connection-target');}catch{}
      nodeStatus.textContent='';
    }else nodeStatus.textContent=`已选「${titleFor(connectionSource)}」。选择要连接的节点。`;
  }else nodeStatus.textContent=mergeSource ? `点另一个手写节点，将「${titleFor(mergeSource)}」合并进去。` : notice;
  nodeStatus.hidden=!nodeStatus.textContent;
}
function toolbar() {
  nodeTools();
  const typing=!!document.getElementById('input-box');
  hint.hidden=typing || editor || (!!selected && !unsaved);
  if(typing || editor)nodeStatus.hidden=true;
}
function frame(force=false) {
  // Rendering may replace DOM elements while Swift is still closing the previous
  // editor. Keep the explicitly selected ID, resolving its current model object.
  if(selected){
    try{selected=mind.findEle(selected.id).nodeObj;}catch{selected=mind.currentNode?.nodeObj || null;}
  }
  toolbar();
  const id=editor && expandedNodeID ? expandedNodeID : selected?.id;
  if(!id || (!force && !editor) || (!force && performance.now()-lastFrame<16))return;
  lastFrame=performance.now(); const rect=rectFor(id);
  if(rect){
    const slot=document.querySelector('.book-node-expanded .book-native-content');
    const r=slot?.closest('.me-tpc')?.nodeObj.id===id ? slot.getBoundingClientRect() : null;
    post('frame',{id,rect,contentRect:r ? {x:r.x,y:r.y,width:r.width,height:r.height} : null});
  }
}
function expandedVerticalInsets() {
  return {top:64,bottom:72};
}
function keepExpandedVisible() {
  if(!expandedNodeID)return;
  const r=rectFor(expandedNodeID),v=window.visualViewport;
  if(!r)return;
  const left=(v?.offsetLeft || 0)+12,right=(v?.offsetLeft || 0)+(v?.width || innerWidth)-12;
  const insets=expandedVerticalInsets();
  const top=(v?.offsetTop || 0)+insets.top,bottom=(v?.offsetTop || 0)+(v?.height || innerHeight)-insets.bottom;
  const dx=r.x<left ? left-r.x : r.x+r.width>right ? right-r.x-r.width : 0;
  const dy=r.y<top || r.height>bottom-top ? top-r.y : r.y+r.height>bottom ? bottom-r.y-r.height : 0;
  if(Math.abs(dx)>.5 || Math.abs(dy)>.5)mind.move(dx,dy);
}
function expandCard(el,node) {
  const expanded=node.id===expandedNodeID && editor && !document.getElementById('input-box');
  const had=el.classList.contains('book-node-expanded');
  const oldSize=expanded ? el.getBoundingClientRect() : null;
  el.classList.toggle('book-node-expanded',expanded);
  if(expanded){el.setAttribute('role','group');el.setAttribute('aria-label',isInk(node) ? '展开的手写节点' : '展开的节点：'+titleFor(node.id));el.setAttribute('aria-expanded','true');}
  else if(had){el.removeAttribute('role');el.removeAttribute('aria-label');el.removeAttribute('aria-expanded');}
  if(!expanded){
    if(had){el.querySelector('.book-native-content')?.remove();el.querySelector('.book-node-heading')?.remove();el.querySelector('.book-node-collapse')?.remove();el.style.removeProperty('--book-expanded-width');el.style.removeProperty('--book-card-scale');}
    return had;
  }
  const scale=mind.scaleVal || 1,width=Math.max(180,Math.min(expandedSize?.width || 360,(window.visualViewport?.width || innerWidth)-24));
  el.style.setProperty('--book-expanded-width',`${width/scale}px`);el.style.setProperty('--book-card-scale',scale);
  let slot=el.querySelector('.book-native-content');
  if(!slot){
    const heading=document.createElement('span');heading.className='book-node-heading';
    el.append(heading);
    const close=document.createElement('button');close.className='book-node-collapse';close.type='button';
    close.setAttribute('aria-label','完成节点编辑');close.title='收起节点内容';
    close.innerHTML='<svg width="16" height="16" viewBox="0 0 20 20" fill="none" aria-hidden="true"><path d="m5 12 5-5 5 5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>';
    close.addEventListener('pointerdown',event=>{event.preventDefault();event.stopPropagation();});
    close.addEventListener('click',event=>{event.stopPropagation();post('action',{action:'collapse',id:node.id});});
    el.append(close);
    slot=document.createElement('div');slot.className='book-native-content';slot.setAttribute('aria-hidden','true');el.append(slot);
  }
  const heading=el.querySelector('.book-node-heading');
  const title=node.metadata?.name || (node.metadata?.kind==='note' ? node.metadata.chapterTitle || '' : titleFor(node.id));
  if(heading.textContent!==title)heading.textContent=title;
  const header=el.getBoundingClientRect().height-slot.getBoundingClientRect().height;
  const {top,bottom}=expandedVerticalInsets();
  const available=(window.visualViewport?.height || innerHeight)-top-bottom-header;
  slot.style.height=`${Math.max(60,Math.min(expandedSize?.height || 380,available))/scale}px`;
  const size=el.getBoundingClientRect();
  return !had || Math.abs(size.width-oldSize.width)>.5 || Math.abs(size.height-oldSize.height)>.5;
}
function previews(node=mind.nodeData) {
  try {
    const el=mind.findEle(node.id); el.dataset.bookReadonly=virtual(node)?'true':'false';
    el.dataset.bookKind=node.metadata?.kind || 'note';
    el.title=node.parent ? '拖到节点上改变所属分支，拖到上下边缘调整顺序' : '拖动空白处移动整张图';
    const name=node.metadata?.name, summary=node.metadata?.summary;
    for(const [className,text] of [['book-card-name',name],['book-card-summary',summary]]){
      let line=el.querySelector('.'+className);
      if(text && text!==node.topic){
        if(!line){line=document.createElement('span');line.className=className;if(name && className==='book-card-name')el.prepend(line);else el.append(line);}
        if(line.textContent!==text)line.textContent=text;
      }else line?.remove();
    }
    const parts=node.metadata?.inkParts || [];
    let ink=el.querySelector('.book-ink-preview');
    if(parts.length){
      if(!ink){ink=document.createElement('span');ink.className='book-ink-preview';el.append(ink);}
      const part=parts[0],key=part.image+'|'+part.quote+'|'+parts.length;
      if(ink.dataset.key!==key){
        ink.replaceChildren();ink.dataset.key=key;
        const excerpt=document.createElement('span');excerpt.className='book-ink-excerpt';
        excerpt.textContent=part.quote || '手写标记';
        if(/^bookslide-ink:\/\/[0-9a-f-]{36}\/preview\.png\?/i.test(part.image)){
          const image=document.createElement('img');image.alt=excerpt.textContent;
          image.addEventListener('error',()=>{image.replaceWith(excerpt);mind.linkDiv();},{once:true});
          image.style.height=`${Math.min(112,168*part.aspect)}px`;image.src=part.image;ink.append(image);
        }else ink.append(excerpt);
        if(parts.length>1){const count=document.createElement('span');count.textContent=`共 ${parts.length} 处标记`;count.className='book-ink-count';ink.append(count);}
      }
    }else ink?.remove();
    if(expandCard(el,node) && expansionFrame===null){
      expansionFrame=requestAnimationFrame(()=>{expansionFrame=null;mind.linkDiv();keepExpandedVisible();frame(true);});
    }
  } catch {}
  for(const child of node.children || [])previews(child);
}
function cardCurve(x,y,tx,ty) {
  const bend=Math.max(18,Math.abs(tx-x)*.5), sign=tx>=x?1:-1;
  return `M ${x} ${y} C ${x+sign*bend} ${y} ${tx-sign*bend} ${ty} ${tx} ${ty}`;
}
function cardMainBranch({pT,pL,pW,pH,cT,cL,cW,cH,direction}) {
  const left=direction===0;
  return cardCurve(pL+(left?0:pW),pT+pH/2,cL+(left?cW:0),cT+cH/2);
}
function cardSubBranch({pT,pL,pW,pH,cT,cL,cW,cH,direction,isFirst}) {
  const gap=parseFloat(this.container.style.getPropertyValue('--node-gap-x')) || 36;
  const left=direction===0, inset=isFirst?0:gap;
  return cardCurve(left?pL+inset:pL+pW-inset,pT+pH/2,left?cL+cW-gap:cL+gap,cT+cH/2);
}

// A touch on a card is a node drag; a touch on blank canvas is a pan.
// Keep the upstream engine's move/history operations, without its hidden
// half-second long-press requirement on iPad.
function clearDragPreview() {
  touchDrag?.ghost?.remove();
  if(touchDrag?.source)touchDrag.source.style.opacity='';
  document.querySelectorAll('[data-book-drop]').forEach(el=>delete el.dataset.bookDrop);
  dragStatus.hidden=true;
}
function dragDestination(event) {
  const target=document.elementFromPoint(event.clientX,event.clientY)?.closest('.me-tpc');
  if(!target || !touchDrag)return null;
  let ancestor=target.nodeObj;
  while(ancestor){if(ancestor.id===touchDrag.id)return null;ancestor=ancestor.parent;}
  const r=target.getBoundingClientRect(), fraction=(event.clientY-r.top)/r.height;
  const mode=!target.nodeObj.parent ? 'in' : fraction<.25 ? 'before' : fraction>.75 ? 'after' : 'in';
  const parent=mode==='in' ? target.nodeObj : target.nodeObj.parent;
  if(virtual(touchDrag.source.nodeObj) && !virtual(parent))return null;
  return {target,mode};
}
function installTouchDragging() {
  const container=mind.container;
  const activeTouches=new Set();
  let handledTouch=false;
  window.addEventListener('pointerdown',()=>{handledTouch=false;},true);
  // WebKit may emit a compatibility mouse click after this touch handler has
  // already opened a menu or toggled content, even when the target reflows.
  window.addEventListener('click',event=>{
    if(handledTouch && event.detail!==0){
      event.preventDefault();event.stopImmediatePropagation();handledTouch=false;
    }
  },true);
  let holdTimer;
  container.addEventListener('pointerdown',event=>{
    if((event.pointerType!=='touch' && !mergeSource) || event.button!==0 || event.target.closest('#input-box,.book-node-collapse'))return;
    activeTouches.add(event.pointerId);
    if(touchDrag){
      event.preventDefault();event.stopImmediatePropagation();
      clearTimeout(holdTimer);
      clearDragPreview();touchDrag.phase='pinch';
      touchDrag.pointers.set(event.pointerId,{x:event.clientX,y:event.clientY});
      const points=[...touchDrag.pointers.values()];
      touchDrag.distance=Math.hypot(points[0].x-points[1].x,points[0].y-points[1].y);
      lastNodeTap=null;
      try{container.setPointerCapture(event.pointerId);}catch{/* Pointer may already be cancelled. */}
      return;
    }
    const source=event.target.closest('.me-tpc');
    if(activeTouches.size>1 || !source?.nodeObj || connectionSource)return;
    handledTouch=event.pointerType==='touch';
    event.preventDefault();event.stopImmediatePropagation();
    // Commit grouping on pointer-up, after the engine's selection gesture has
    // finished. Refreshing the graph inside its pointer-down selection leaves
    // that gesture holding detached elements.
    if(mergeSource){
      touchDrag={id:source.nodeObj.id,source,phase:'merge',x:event.clientX,y:event.clientY,
        pointers:new Map([[event.pointerId,{x:event.clientX,y:event.clientY}]])};
      try{source.setPointerCapture(event.pointerId);}catch{}
      return;
    }
    // Selecting must not pan the card away from the finger at gesture start.
    touchDrag={id:source.nodeObj.id,source,phase:'pending',x:event.clientX,y:event.clientY,
      pointers:new Map([[event.pointerId,{x:event.clientX,y:event.clientY}]])};
    const gesture=touchDrag;
    holdTimer=setTimeout(()=>{
      if(touchDrag!==gesture || gesture.phase!=='pending' || !gesture.source.isConnected)return;
      gesture.phase='menu';lastNodeTap=null;
      openNodeMenu(gesture.source);
    },500);
    // An expanded editor already owns its card. Reselecting it during a hold
    // can scroll the card and dismiss the menu as the finger lifts.
    if(expandedNodeID!==gesture.id || selected?.id!==gesture.id){
      if(mind.selection){mind.clearSelection();mind.selection.select(source);}else mind.selectNode(source);
    }
    try{source.setPointerCapture(event.pointerId);}catch{/* A cancelled pointer has no capture target. */}
  },true);
  container.addEventListener('pointermove',event=>{
    if(!touchDrag || !touchDrag.pointers.has(event.pointerId))return;
    event.preventDefault();event.stopImmediatePropagation();
    touchDrag.pointers.set(event.pointerId,{x:event.clientX,y:event.clientY});
    if(touchDrag.phase==='merge' || touchDrag.phase==='menu')return;
    if(touchDrag.phase==='pan'){
      mind.move(event.clientX-touchDrag.x,event.clientY-touchDrag.y);
      touchDrag.x=event.clientX;touchDrag.y=event.clientY;return;
    }
    if(touchDrag.phase==='pinch'){
      const points=[...touchDrag.pointers.values()];
      if(points.length<2)return;
      const distance=Math.hypot(points[0].x-points[1].x,points[0].y-points[1].y);
      if(touchDrag.distance)mind.scale(Math.max(.25,Math.min(2.5,mind.scaleVal*distance/touchDrag.distance)),
        {x:(points[0].x+points[1].x)/2,y:(points[0].y+points[1].y)/2});
      touchDrag.distance=distance;return;
    }
    if(touchDrag.phase==='pending'){
      if(Math.hypot(event.clientX-touchDrag.x,event.clientY-touchDrag.y)<8)return;
      clearTimeout(holdTimer);lastNodeTap=null;
      if(!touchDrag.source.nodeObj.parent){
        touchDrag.phase='pan';mind.move(event.clientX-touchDrag.x,event.clientY-touchDrag.y);
        touchDrag.x=event.clientX;touchDrag.y=event.clientY;return;
      }
      touchDrag.phase='drag';
      const ghost=touchDrag.source.cloneNode(true);ghost.classList.add('book-drag-preview');
      ghost.setAttribute('aria-hidden','true');
      ghost.removeAttribute('data-nodeid');ghost.style.width=`${touchDrag.source.offsetWidth}px`;
      document.body.appendChild(ghost);touchDrag.ghost=ghost;touchDrag.source.style.opacity='.35';
    }
    touchDrag.ghost.style.left=`${event.clientX+18}px`;touchDrag.ghost.style.top=`${event.clientY+18}px`;
    document.querySelectorAll('[data-book-drop]').forEach(el=>delete el.dataset.bookDrop);
    const destination=dragDestination(event);touchDrag.destination=destination;
    if(destination){
      destination.target.dataset.bookDrop=destination.mode;
      const title=destination.target.nodeObj.topic.slice(0,28);
      dragStatus.textContent=destination.mode==='in' ? `松开，放入「${title}」` : `松开，排在「${title}」${destination.mode==='before'?'之前':'之后'}`;
    }else dragStatus.textContent='拖到另一个节点上改挂分支，拖到节点上下边缘调整顺序';
    dragStatus.hidden=false;
  },true);
  const finish=async(event,cancelled=false)=>{
    activeTouches.delete(event.pointerId);
    if(!touchDrag || !touchDrag.pointers.has(event.pointerId))return;
    event.preventDefault();event.stopImmediatePropagation();
    clearTimeout(holdTimer);
    touchDrag.pointers.delete(event.pointerId);
    if(touchDrag.phase==='pinch' && touchDrag.pointers.size)return;
    const drag=touchDrag, destination=dragDestination(event);
    clearDragPreview();touchDrag=null;
    if(cancelled){frame(true);return;}
    if(drag.phase==='merge'){
      lastNodeTap=null;
      if(Math.hypot(event.clientX-drag.x,event.clientY-drag.y)<10)select(drag.source.nodeObj);
    }else if(drag.phase==='pending'){
      if(lastNodeTap?.id===drag.id && performance.now()-lastNodeTap.time<320 && !virtual(drag.source.nodeObj)){
        lastNodeTap=null;mind.editTopic(drag.source);
      }else {
        lastNodeTap={id:drag.id,time:performance.now()};
        if(!virtual(drag.source.nodeObj))action('note');
      }
    }else if(drag.phase==='drag' && destination){
      const method={in:'moveNodesIn',before:'moveNodesBefore',after:'moveNodesAfter'}[destination.mode];
      await mind[method]([drag.source],destination.target);
      const message=`已移动「${drag.source.nodeObj.topic.slice(0,28)}」，可用撤销恢复。`;
      notice=message;
      setTimeout(()=>{if(notice===message){notice='';frame(true);}},5000);
      requestSave();
    }
    frame(true);
  };
  container.addEventListener('pointerup',event=>finish(event),true);
  container.addEventListener('pointercancel',event=>finish(event,true),true);
}
function requestSave() {
  if(suppress || !ready)return;
  const data=snapshot(), sig=signature(data);
  if(sig===lastSent || sig===lastSaved)return;
  if(saving){pending=true;return;}
  saving=true;lastSent=sig;sentTopics=topicsIn(data);post('change',{document:data});
}
function preserveTextDuringHistory() {
  const history=mind.historyStack;
  for(const [method,offset,side] of [['undo',-1,'before'],['redo',0,'after']]){
    const restore=history[method].bind(history);
    history[method]=()=>{
      const entry=history.getEntries()[history.currentIndex+offset];
      if(entry?.doc==='map'){
        const live=nodesIn(mind.getData());
        const edited=entry.meta?.operation==='finishEdit' ? entry.meta.currentTarget.value[0] : null;
        // Layout history predates edits made in the expanded native editor.
        // Replay the layout while carrying the current text of surviving notes.
        for(const [id,node] of nodesIn(entry[side])){
          const current=live.get(id),kind=node.metadata?.kind || 'note';
          if(!current || id===edited || (kind!=='note' && kind!=='ink'))continue;
          if(kind==='ink'){
            const parts=node.metadata.inkParts || [],existing=current.metadata?.inkParts || [];
            if(parts.length!==existing.length || parts.some((part,index)=>part.id!==existing[index].id))continue;
            node.note=current.note;
          }
          node.topic=current.topic;
        }
      }
      return restore();
    };
  }
}
function select(node) {
  selected=node;notice='';
  if(mergeSource){
    if(node.id!==mergeSource && node.metadata?.kind==='ink'){
      const source=mergeSource;mergeSource=null;mergeInkNodes(source,node.id);return;
    }
    frame(true);return;
  }
  if(connectionSource){connectionTarget=null;connection.hidden=true;}
  if(connectionSource==='__pick__')connectionSource=node.id;
  else if(connectionSource && connectionSource!=='__pick__' && node.id!==connectionSource){
    connectionTarget=node.id;
    const r=rectFor(node.id); connection.hidden=false;
    document.getElementById('connection-from').textContent=titleFor(connectionSource);
    document.getElementById('connection-to').textContent=titleFor(node.id);
    connection.style.left=`${Math.max(8,Math.min(innerWidth-connection.offsetWidth-8,r?.x || 8))}px`;
    const top=8;
    connection.style.top=`${Math.max(top,Math.min(innerHeight-connection.offsetHeight-8,(r?.y || top)+50))}px`;
  }
  frame(true);
  post('select',{id:node.id,rect:rectFor(node.id),selectionRevision:++selectionRevision});
}
function commitInkDocument(before,after,target,message){
  post('action',{action:'dismiss',id:target});
  suppress=true;mind.diffRefresh(after);suppress=false;
  try{mind.selectNode(mind.findEle(target));}catch{}
  previews();mind.linkDiv();
  mind.historyStack.push('map',before,snapshot(),{operation:'inkGrouping',currentSelected:[target],currentTarget:{type:'nodes',value:[target]}});
  notice=message;lastGroupEdit=performance.now();requestSave();frame(true);
}
function mergeInkNodes(sourceID,targetID){
  const before=snapshot(),after=structuredClone(before);
  const find=(n,id)=>n.id===id?n:(n.children || []).map(c=>find(c,id)).find(Boolean);
  const source=find(after.nodeData,sourceID),target=find(after.nodeData,targetID);
  if(!source || !target || source===target || source.metadata?.kind!=='ink' || target.metadata?.kind!=='ink')return;
  const parts=[...(target.metadata.inkParts || []),...(source.metadata.inkParts || [])];
  if(!parts.length || parts.length>1000 || new Set(parts.map(p=>p.id)).size!==parts.length)return;
  target.metadata.inkParts=parts;
  target.metadata.inkEntityIDs=[...new Set([...(target.metadata.inkEntityIDs || []),...(source.metadata.inkEntityIDs || [])])];
  target.note=[target.note,source.note].filter(Boolean).join('\n\n');
  if(target.note.trim())target.topic=target.note.trim();
  const path=(source.children || []).filter(c=>find(c,targetID));
  const moved=(source.children || []).filter(c=>!find(c,targetID));
  target.children=[...(target.children || []),...moved];
  const detach=n=>{n.children=(n.children || []).flatMap(c=>c.id===sourceID?path:[c]);for(const child of n.children)detach(child);};
  detach(after.nodeData);
  after.arrows=(after.arrows || []).map(a=>({...a,from:a.from===sourceID?targetID:a.from,to:a.to===sourceID?targetID:a.to})).filter(a=>a.from!==a.to);
  commitInkDocument(before,after,targetID,'已合并标记，可用左下角撤销。');
}
function splitInkNode(id){
  const before=snapshot(),after=structuredClone(before);
  const split=parent=>{
    for(let i=0;i<(parent.children || []).length;i++){
      const node=parent.children[i],parts=node.metadata?.inkParts || [];
      if(node.id===id && parts.length>1){
        const primary=parts.findIndex(p=>id==='ink:'+p.id);
        if(primary>0)parts.unshift(...parts.splice(primary,1));
        const originalText=parts.map(p=>p.text || '').filter(Boolean).join('\n\n');
        const extraEntities=(node.metadata.inkEntityIDs || []).filter(id=>!parts.some(p=>(p.entityIDs || []).includes(id)));
        const siblings=parts.map((part,index)=>{
          const result={...structuredClone(node),id:index===0?id:'ink:'+part.id,topic:index===0?node.topic:(part.title || ''),
            note:part.text || '',children:index===0?(node.children || []):[]};
          if(index===0 && (node.note || '')!==originalText)result.note=node.note || '';
          result.metadata={...node.metadata,nodeID:{kind:'ink',owner:result.id.slice(4)},inkParts:[part],inkEntityIDs:[...(part.entityIDs || []),...(index===0?extraEntities:[])]};
          if(result.note.trim())result.topic=result.note.trim();
          return result;
        });
        parent.children.splice(i,1,...siblings);return true;
      }
      if(split(node))return true;
    }
    return false;
  };
  if(split(after.nodeData))commitInkDocument(before,after,id,'已拆分标记，原节点的连接保留。可用撤销恢复。');
}

function beginConnection(source=null) {
  const content=[];
  const visit=node=>{if(content.length>=2)return;content.push(node);for(const child of node.children || [])visit(child);};
  visit(mind.nodeData);
  if(content.length<2){notice='请先添加至少两个节点，再连接它们。';frame(true);return;}
  notice='';connectionSource=source || '__pick__';connectionTarget=null;connection.hidden=true;
  relation.value='';document.getElementById('save-connection').disabled=true;frame(true);
}
function cancelConnection() {
  const merging=!!mergeSource;mergeSource=null;connectionSource=null;connectionTarget=null;connection.hidden=true;notice=merging?'已取消合并，节点保持原样。':'已取消连接，节点保持原样。';frame(true);
}
function chapterForNewNode(selectedID=selected?.id) {
  const path=(node,id)=>node.id===id?[node]:(node.children || []).map(child=>path(child,id)).find(Boolean)?.concat(node);
  const ancestors=selectedID ? path(mind.nodeData,selectedID) || [] : [];
  return ancestors.find(node=>node.metadata?.kind==='chapter') || mind.nodeData.children?.find(node=>node.metadata?.kind==='chapter') || mind.nodeData;
}
async function action(name) {
  if(!selected)return;
  if(name==='note'){
    const now=performance.now();
    if(lastContentTap?.id===selected.id && now-lastContentTap.time<300)return;
    lastContentTap={id:selected.id,time:now};
  }
  document.getElementById('input-box')?.blur();
  const el=mind.findEle(selected.id);
  if(name==='add' || name==='sibling'){
    notice='';
    post('action',{action:'dismiss',id:selected.id});
  }
  if(name==='rename' && canEditTopic(selected))mind.editTopic(el);
  if(name==='add')await mind.addChild(el);
  if(name==='sibling' && !virtual(selected))await mind.insertSibling('after',el);
  if(name==='remove' && !virtual(selected)){
    post('action',{action:'dismiss',id:selected.id});
    await mind.removeNodes([el]);
    selected=mind.currentNode?.nodeObj || null;
    notice='已删除节点，可用左下角的撤销恢复。';
    requestSave();frame(true);
  }
  if(name==='mergeInk' && selected.metadata?.kind==='ink'){
    post('action',{action:'dismiss',id:selected.id});
    connectionSource=null;connectionTarget=null;connection.hidden=true;mergeSource=selected.id;frame(true);
  }
  if(name==='splitInk' && selected.metadata?.kind==='ink')splitInkNode(selected.id);
  if(name==='note' || name==='ai')post('action',{action:name,id:selected.id,rect:rectFor(selected.id)});
}
let menuOwner=null;
function openNodeMenu(card){
  if(!card?.nodeObj || connectionSource || mergeSource || document.getElementById('input-box'))return;
  const id=card.nodeObj.id,rect=rectFor(id);
  if(!rect)return;
  menuOwner=id;
  post('action',{action:'menu',id,rect});
}
function dismissNodeMenu(){
  if(!menuOwner)return;
  post('action',{action:'closeMenu',id:menuOwner});menuOwner=null;
}
document.getElementById('map').addEventListener('click',event=>{
  if(performance.now()-lastGroupEdit<350 || mergeSource || event.pointerType==='touch' || event.button!==0 || event.target.closest('#input-box,.me-epd,.book-node-collapse'))return;
  const card=event.target.closest('.me-tpc');
  if(card && !virtual(card.nodeObj) && selected?.id===card.nodeObj.id)action('note');
});
let blankStart, lastBlankTap;
const canvasSurface=document.getElementById('map');
canvasSurface.addEventListener('pointerdown',event=>{
  dismissNodeMenu();
  blankStart=!event.isPrimary || event.button!==0 || event.target.closest('.me-tpc,#input-box,.svg-label,.me-epd')
    ? null : {id:event.pointerId,x:event.clientX,y:event.clientY,time:performance.now(),selectedID:selected?.id};
  // Commit the inline text before starting a pan. Otherwise its invisible
  // topic remains covered by the editable overlay after blank-space dragging.
  if(blankStart)document.getElementById('input-box')?.blur();
},true);
canvasSurface.addEventListener('pointercancel',()=>{blankStart=null;lastBlankTap=null;},true);
canvasSurface.addEventListener('pointerup',event=>{
  const start=blankStart;blankStart=null;
  if(!ready || !start || start.id!==event.pointerId || connectionSource || mergeSource || performance.now()-start.time>350 || Math.hypot(event.clientX-start.x,event.clientY-start.y)>10)return;
  if(lastBlankTap && performance.now()-lastBlankTap.time<320 && Math.hypot(start.x-lastBlankTap.x,start.y-lastBlankTap.y)<24){
    const chapter=chapterForNewNode(lastBlankTap.selectedID);
    lastBlankTap=null;document.getElementById('input-box')?.blur();
    post('action',{action:'dismiss',id:selected?.id || ''});
    mind.addChild(mind.findEle(chapter.id));
  }else{
    lastBlankTap=start;
    mind.clearSelection();
    selected=null;
    toolbar();
    post('action',{action:'deselect',id:'',selectionRevision:++selectionRevision});
  }
},true);
relation.addEventListener('input',()=>{document.getElementById('save-connection').disabled=!relation.value.trim();});
document.getElementById('save-connection').addEventListener('click',()=>{
  const label=relation.value.trim();
  if(!label || !connectionSource || connectionSource==='__pick__' || !connectionTarget || connectionSource===connectionTarget)return;
  const from=connectionSource,to=connectionTarget;
  mind.createArrowFrom({from,to,label});
  connectionSource=null;connectionTarget=null;connection.hidden=true;
  notice=`已连接「${titleFor(from)}」和「${titleFor(to)}」。`;frame(true);requestSave();
});
document.getElementById('cancel-connection').addEventListener('click',cancelConnection);
document.getElementById('cancel-link').addEventListener('click',cancelConnection);
document.addEventListener('keydown',event=>{if(event.key==='Escape' && (connectionSource || mergeSource)){event.preventDefault();event.stopPropagation();cancelConnection();}},true);
window.bookMindMap = {
  async update(payload) {
    session=payload.session;editor=payload.editor;
    const expansionChanged=expandedNodeID!==(payload.expandedNode || null) || JSON.stringify(expandedSize)!==JSON.stringify(payload.expandedSize || null);
    const previousCard=expansionChanged && expandedNodeID && expandedNodeID===payload.expandedNode ? rectFor(expandedNodeID) : null;
    expandedNodeID=payload.expandedNode || null;expandedSize=payload.expandedSize || null;
    const data=payload.document;
    const initializing=!mind;
    if(!mind){
      const protectedNodes=(items)=>items.every(el=>!virtual(el.nodeObj));
      const movableNodes=(items,target,mode)=>items.every(el=>el.nodeObj.parent &&
        (!virtual(el.nodeObj) || virtual(mode==='in' ? target.nodeObj : target.nodeObj.parent)));
      // overflowHidden disables the library’s pointer handlers entirely.
      // Clip the viewport in CSS while retaining pan, pinch and branch drag.
      mind=new MindElixir({el:'#map',direction:1,alignment:'nodes',toolBar:false,editable:true,allowUndo:true,keypress:true,mouseSelectionButton:2,newTopicName:'新节点',scaleMin:.25,scaleMax:2.5,overflowHidden:false,contextMenu:false,before:{copyNodes:protectedNodes,removeNodes:protectedNodes,moveNodesIn:(items,target)=>movableNodes(items,target,'in'),moveNodesBefore:(items,target)=>movableNodes(items,target,'before'),moveNodesAfter:(items,target)=>movableNodes(items,target,'after'),insertParent:el=>!virtual((el || mind.currentNode)?.nodeObj)}});
      suppress=true;await mind.init(data);suppress=false;ready=true;lastSaved=signature(data);savedTopics=topicsIn(data);
      installTouchDragging();
      preserveTextDuringHistory();
      const editTopic=mind.editTopic.bind(mind);
      mind.editTopic=el=>{
        if(!canEditTopic(el?.nodeObj))return;
        post('action',{action:'dismiss',id:el.nodeObj.id});
        expandedNodeID=null;previews();
        document.getElementById('input-box')?.blur();
        if(mind.scaleVal<.8){mind.scale(1);mind.scrollIntoView(el,true);}
        editTopic(el);
        const input=document.getElementById('input-box');
        input?.setAttribute('aria-label','节点文字');
        if(input){
          // Reserve space in the graph for wrapped text as the card grows.
          el.classList.add('book-topic-editing');el.parentElement.classList.add('book-topic-editing');
          input.classList.add('book-topic-input');input.style.cssText='';
          el.insertBefore(input,el.text);
          let layoutFrame=null;
          const relayout=()=>{
            if(layoutFrame!==null)cancelAnimationFrame(layoutFrame);
            layoutFrame=requestAnimationFrame(()=>{layoutFrame=null;mind.linkDiv();updateEditorViewport();});
          };
          const resize=new ResizeObserver(relayout);resize.observe(input);
          input.addEventListener('blur',()=>{
            resize.disconnect();if(layoutFrame!==null)cancelAnimationFrame(layoutFrame);
            el.classList.remove('book-topic-editing');el.parentElement?.classList.remove('book-topic-editing');
            requestAnimationFrame(()=>{mind.linkDiv();frame(true);});
          },{capture:true,once:true});
          // WebKit can collapse a selection while opening the software
          // keyboard. A fresh topic starts empty so its placeholder cannot
          // accidentally become part of the user's text.
          if(!el.nodeObj.metadata && el.nodeObj.topic===mind.newTopicName){input.textContent='';input.dataset.placeholder=mind.newTopicName;}
          const initial=input.textContent;
          const selectText=()=>{
            if(!input.isConnected || input.textContent!==initial)return;
            const range=document.createRange();range.selectNodeContents(input);
            const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
          };
          input.addEventListener('focus',selectText,{once:true});
          input.focus();selectText();requestAnimationFrame(selectText);
          relayout();
        }
        frame(true);
        input?.addEventListener('blur',()=>requestAnimationFrame(()=>frame(true)),{once:true});
      };
      mind.container.addEventListener('contextmenu',event=>{
        const card=event.target.closest('.me-tpc');
        if(!card || event.target.closest('#input-box') || connectionSource || mergeSource)return;
        event.preventDefault();event.stopImmediatePropagation();
        if(touchDrag)return; // Touch uses the same timer and cancellation rules as dragging.
        if(expandedNodeID && expandedNodeID!==card.nodeObj.id){
          post('action',{action:'dismiss',id:expandedNodeID});expandedNodeID=null;previews();
        }
        if(selected?.id!==card.nodeObj.id)mind.selectNode(card);
        openNodeMenu(card);
      },true);
      canvasSurface.addEventListener('keydown',event=>{
        if(event.key==='Escape'){dismissNodeMenu();return;}
        if(event.key!=='ContextMenu' && !(event.shiftKey && event.key==='F10'))return;
        const card=event.target.closest('.me-tpc') || mind.currentNode;
        if(!card || event.target.closest('#input-box'))return;
        event.preventDefault();
        if(mind.currentNode!==card)mind.selectNode(card);
        openNodeMenu(card);
      });
      mind.bus.addListener('selectNewNode',node=>setTimeout(()=>{try{mind.scrollIntoView(mind.findEle(node.id),true);}catch{}},320));
      mind.bus.addListener('selectNodes',nodes=>{
        if(!nodes.length)return;
        // Native focus and refresh are acknowledgements, not new user selections.
        // Echoing them back can dismiss the editor opened by a newer action.
        if(suppress){selected=nodes[nodes.length-1];return;}
        select(nodes[nodes.length-1]);
      });
      mind.bus.addListener('unselectNodes',()=>{if(!suppress && !mind.currentNode){selected=null;toolbar();}});
      mind.bus.addListener('move',()=>{dismissNodeMenu();frame();});mind.bus.addListener('scale',()=>{dismissNodeMenu();previews();frame();});
      mind.bus.addListener('linkDiv',()=>{previews();frame();});
      mind.bus.addListener('operation',operation=>{if(operation.name!=='beginEdit')requestSave();requestAnimationFrame(()=>{previews();frame();});});
      mind.historyStack?.subscribe(()=>{requestSave();requestAnimationFrame(()=>frame(true));});
      mind.bus.addListener('selectArrow',arrow=>post('edge',{id:arrow.id,edgeID:arrow.edgeID}));
      previews();mind.linkDiv();
      hint.textContent='长按节点查看操作 · 双指缩放';
      post('ready');
    } else if(!saving && !unsaved && !touchDrag && !document.getElementById('input-box') && signature(data)!==signature(snapshot())) {
      const selectedID=selected?.id; suppress=true;mind.diffRefresh(data);suppress=false;
      if(selectedID){
        try{
          const el=mind.findEle(selectedID);
          if(mind.currentNode!==el){suppress=true;try{mind.selectNode(el);}finally{suppress=false;}}
          selected=el.nodeObj;
        }catch{selected=null;}
      }
      previews();mind.linkDiv();frame(true);lastSaved=signature(data);savedTopics=topicsIn(data);
    }
    documentVersion=payload.version;
    if(expansionChanged){
      previews();mind.linkDiv();
      // Resizing reflows the tree around its center. Keep the tab row under the finger.
      const current=previousCard && rectFor(expandedNodeID);
      if(current)mind.move(previousCard.x-current.x,previousCard.y-current.y);
      keepExpandedVisible();
    }
    if(lastTheme!==payload.theme){
      lastTheme=payload.theme;
      const colors=payload.colors;
      const style=document.documentElement.style;
      style.colorScheme=payload.dark?'dark':'light';
      for(const [name,value] of Object.entries(colors))style.setProperty('--'+name,value);
      mind.changeTheme({name:'BookSlide',type:payload.dark?'dark':'light',generateMainBranch:cardMainBranch,
        generateSubBranch:cardSubBranch,palette:[colors.branch],cssVar:{
          '--bgcolor':'transparent','--root-bgcolor':'transparent','--root-color':colors.ink,
          '--main-bgcolor':'transparent','--main-color':colors.ink,'--color':colors.ink,
          '--node-gap-x':'36px','--node-gap-y':'14px','--main-gap-x':'36px','--main-gap-y':'20px',
          '--map-padding':'72px 42px','--topic-padding':'13px 16px','--selected':colors.accent}},false);
      mind.linkDiv();
    }
    // Saving must not replay an older native selection over a new node's editor.
    // Only an explicit camera request may select/center a node from Swift.
    if(initializing){mind.scaleFit();if(mind.scaleVal<.65){mind.scale(.65);mind.toCenter();}}
    if(payload.selectionRevision!==selectionRevision){
      window.lastFocus=payload.focusRequest;
    }else if(payload.focus && payload.focusRequest!==window.lastFocus){
      window.lastFocus=payload.focusRequest;
      try{const el=mind.findEle(payload.focus);if(!selected || selected.id!==payload.focus){suppress=true;mind.selectNode(el);suppress=false;}if(payload.focus===expandedNodeID)keepExpandedVisible();else mind.scrollIntoView(el,true);}catch{}
    }
    frame(true);
  },
  ack(ok,error) {
    saving=false;
    if(!ok){pending=false;unsaved=true;lastSent=null;hint.textContent=error || '修改未保存，画布内容已保留';return;}
    unsaved=false;lastSaved=lastSent;savedTopics=sentTopics;
    if(pending){pending=false;requestSave();}
  },
  command(command) {
    if(!mind || command.id===lastCommand)return;lastCommand=command.id;
    if(command.name==='menu'){
      try{openNodeMenu(mind.findEle(command.target));}catch{}
      return;
    }
    // View controls finish an inline name edit, so its text overlay cannot
    // remain at the old position and swallow the next node drag.
    if(['center','zoomIn','zoomOut'].includes(command.name))document.getElementById('input-box')?.blur();
    if(command.target){try{
      mind.selectNode(mind.findEle(command.target));
      if(selected?.id!==command.target)select(mind.findEle(command.target).nodeObj);
      selected=mind.findEle(command.target).nodeObj;
    }catch{return;}}
    if(command.name==='parent' && selected && !virtual(selected))mind.insertParent();
    if(command.name==='up' && selected?.parent)mind.moveUpNode();
    if(command.name==='down' && selected?.parent)mind.moveDownNode();
    if(command.name==='summary' && selected)mind.createSummary();
    if(command.name==='content' && selected){
      if(virtual(selected))post('action',{action:'content',id:selected.id});else action('note');
    }
    if(command.name==='add')action('add');
    if(command.name==='addRoot'){document.getElementById('input-box')?.blur();mind.addChild(mind.findEle(chapterForNewNode().id));}
    if(command.name==='sibling')action('sibling');
    if(command.name==='remove')action('remove');
    if(command.name==='connect')beginConnection(command.target && selected ? selected.id : null);
    if(command.name==='connectSelection'){
      document.getElementById('input-box')?.blur();
      beginConnection(selected ? selected.id : null);
    }
    if(command.name==='undo' || command.name==='redo'){
      mind[command.name]();selected=mind.currentNode?.nodeObj || null;
    }
    if(command.name==='center')mind.scaleFit();
    if(command.name==='zoomIn')mind.scale(Math.min(2.5,mind.scaleVal+.15));
    if(command.name==='zoomOut')mind.scale(Math.max(.25,mind.scaleVal-.15));
    if(command.name==='edit')action('rename');
    if(command.name==='ai')action('ai');
    if(command.name==='mergeInk' || command.name==='splitInk')action(command.name);
    if(command.name==='retry'){lastSaved=null;lastSent=null;requestSave();}
    frame(true);
  },
  inspect(){return {ready,data:mind?snapshot():null,selected:selected?.id,editor,expandedNode:expandedNodeID,scale:mind?.scaleVal,saving,pending,unsaved,hint:hint.textContent,input:document.getElementById('input-box')?.textContent};}
};
let editorViewportFrame=null;
function updateEditorViewport() {
  if(editorViewportFrame!==null)cancelAnimationFrame(editorViewportFrame);
  editorViewportFrame=requestAnimationFrame(()=>{
    editorViewportFrame=null;
    const input=document.getElementById('input-box');
    if(mind && expandedNodeID && !input){
      previews();
      keepExpandedVisible();
    }
    if(mind && input && document.activeElement===input){
      // Rotation can narrow the companion without ending its contentEditable
      // session. Move the existing canvas just enough to retain the live input.
      mind.map.style.transition='none';
      const bounds=mind.container.getBoundingClientRect();
      const viewport=window.visualViewport;
      const left=Math.max(bounds.left,viewport?.offsetLeft || 0)+12;
      const right=Math.min(bounds.right,(viewport?.offsetLeft || 0)+(viewport?.width || innerWidth))-12;
      const top=Math.max(bounds.top,viewport?.offsetTop || 0)+Math.min(72,bounds.height*.18);
      const bottom=Math.min(bounds.bottom,(viewport?.offsetTop || 0)+(viewport?.height || innerHeight))-Math.min(76,bounds.height*.18);
      const card=input.closest('.me-tpc');
      if(card && card.getBoundingClientRect().width>right-left){mind.scale(1);mind.map.style.transition='none';}
      if(card){
        const style=getComputedStyle(card),lineHeight=parseFloat(getComputedStyle(input).lineHeight)||22.5;
        const inset=['paddingTop','paddingBottom','borderTopWidth','borderBottomWidth'].reduce((sum,key)=>sum+(parseFloat(style[key])||0),0);
        const height=Math.max(lineHeight,Math.min(160,Math.floor((bottom-top)/mind.scaleVal-inset)));
        if(input.style.maxHeight!==`${height}px`)input.style.maxHeight=`${height}px`;
      }
      const r=(card || input).getBoundingClientRect();
      const dx=r.left<left ? left-r.left : r.right>right ? right-r.right : 0;
      const dy=r.top<top ? top-r.top : r.bottom>bottom ? bottom-r.bottom : 0;
      if(dx || dy)mind.move(dx,dy);
    }
    frame(true);
  });
}
window.addEventListener('resize',updateEditorViewport);
window.visualViewport?.addEventListener('resize',updateEditorViewport);
new ResizeObserver(updateEditorViewport).observe(document.getElementById('map'));
window.addEventListener('error',e=>post('error',{message:e.message}));
post('loaded');
