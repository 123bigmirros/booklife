/* Portable anchors bridge EPUB CFI readers and the plain-text terminal. */
(function(root) {
  const ignored = /[\s\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]/u;
  const canonical = text => [...text].filter(c=>!ignored.test(c)).join('');
  const cache = new WeakMap();
  function mapping(doc) {
    if (cache.has(doc)) return cache.get(doc);
    const chars=[], points=[], walker=doc.createTreeWalker(doc.body,NodeFilter.SHOW_TEXT);
    let node;
    while ((node=walker.nextNode())) {
      if (node.parentElement?.closest('script,style,head')) continue;
      let offset=0;
      for (const char of node.data) {
        if (!ignored.test(char)) { chars.push(char); points.push({node,offset}); }
        offset+=char.length;
      }
    }
    const result={chars,points,text:chars.join('')}; cache.set(doc,result); return result;
  }
  function locate(chars,quote,fraction) {
    const wanted=[...canonical(quote)], expected=Math.floor(Math.max(0,Math.min(1,fraction))*chars.length);
    let best=-1;
    if (wanted.length) for(let i=0;i<=chars.length-wanted.length;i++) {
      if (chars[i]===wanted[0] && wanted.every((c,j)=>chars[i+j]===c) && (best<0 || Math.abs(i-expected)<Math.abs(best-expected))) best=i;
    }
    return Math.min(Math.max(0,chars.length-1),best<0 ? expected : best);
  }
  function capture(contents,cfi,href) {
    try {
      const range=contents.range(cfi), map=mapping(contents.document);
      let index=map.points.findIndex(p=>p.node===range.startContainer && p.offset>=range.startOffset);
      if(index<0) {
        index=map.points.findIndex(p=>{ try{return range.comparePoint(p.node,p.offset)>=0;}catch{return false;} });
      }
      index=Math.max(0,index);
      return {href,quote:map.chars.slice(index,index+96).join(''),fraction:index/Math.max(1,map.chars.length)};
    } catch { return {href,quote:'',fraction:0}; }
  }
  function range(doc,anchor) {
    const map=mapping(doc); if(!map.points.length) return null;
    const point=map.points[locate(map.chars,anchor.quote,anchor.fraction)], range=doc.createRange();
    range.setStart(point.node,point.offset); range.collapse(true); return range;
  }
  const api={canonical,locate,capture,range}; root.BookSlideProgress=api;
  if(typeof module!=='undefined') module.exports=api;
})(typeof window!=='undefined'?window:globalThis);
