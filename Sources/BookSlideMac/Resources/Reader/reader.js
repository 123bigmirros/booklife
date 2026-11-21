/* BookSlide's offline EPUB host. Imported content runs in script-disabled frames. */
(() => {
  let book, rendition, current, opening = false, revision = 0, appearance = {};
  let userDriven = false;
  let resizeAnchor = null, resizeRevision = 0, viewportAnchor = null, resizedPassage = null, appearanceOrigin = null;
  let layoutWork = Promise.resolve(), layoutQueue = Promise.resolve(), appearanceRequest = 0, readerSession;
  let cancelOwnerWork;
  let ownerCancelled = new Promise(resolve=>{ cancelOwnerWork = resolve; });
  function cancelPendingOwnerWork() {
    cancelOwnerWork();
    ownerCancelled = new Promise(resolve=>{ cancelOwnerWork = resolve; });
  }
  async function owned(promise, owner) {
    if (owner !== rendition) throw Error('阅读内容已改变');
    const value = await Promise.race([promise,ownerCancelled.then(()=>{ throw Error('阅读内容已改变'); })]);
    if (owner !== rendition) throw Error('阅读内容已改变');
    return value;
  }
  let fineScroll = null;
  function stopFineScroll() { fineScroll?.cancel(); fineScroll = null; }
  function readingInput(event) {
    if (event.type === 'pointermove' && !event.buttons) return;
    beginReadingInput();
  }
  function beginReadingInput() {
    stopFineScroll();
    // Native scrollbars, trackpads and gutter gestures target the host rather
    // than an EPUB iframe. They must invalidate a previous layout checkpoint
    // too; otherwise the next resize restores words already scrolled past.
    if (!opening && !navigating && !resizeAnchor) { userDriven = true; resizedPassage = appearanceOrigin = null; }
  }
  let outlineReady = Promise.resolve([]);
  let toc = [], metadata = {}, moving = false, serifURL, searchRevision = 0;
  const post = (type, value) => window.webkit?.messageHandlers.reader.postMessage({type, value});
  const annotations = new BookSlideAnnotations(post);
  const pageNotes = new BookSlidePageNotes(post);
  let handwritingActive = false, navigating = false, active = true, deferredLayout = false, deferredAppearance = null;
  let viewportSize = null, viewportResizeFrame = null, requestedViewportSize = null;
  let viewportRequest = 0;
  function canvasSize() {
    const rect = document.getElementById('viewer').getBoundingClientRect();
    return {width:Math.round(rect.width),height:Math.round(rect.height)};
  }
  function scheduleViewportResize() {
    const size = canvasSize(), bounds = rendition?.manager?.container?.getBoundingClientRect();
    if (requestedViewportSize?.width === size.width && requestedViewportSize?.height === size.height && bounds && Math.abs(bounds.width-size.width)<1 && Math.abs(bounds.height-size.height)<1) return;
    requestedViewportSize = size;
    stopFineScroll(); userDriven=false;
    if (!opening && !navigating && current && viewportSize && (viewportSize.width !== size.width || viewportSize.height !== size.height)) {
      resizeAnchor ||= viewportAnchor || captureViewport();
    }
    const request = ++viewportRequest, owner = rendition;
    if (viewportResizeFrame !== null) cancelAnimationFrame(viewportResizeFrame);
    viewportResizeFrame = requestAnimationFrame(() => {
      viewportResizeFrame = null;
      const work = layoutQueue.catch(()=>{}).then(async () => {
        if (request !== viewportRequest || owner !== rendition || opening || !current) return current;
        if (!active || canvasSize().width < 1 || canvasSize().height < 1) { deferredLayout = true; return current; }
        await resizeViewport(owner);
        return current;
      });
      layoutQueue = work;
      work.catch(error=>post('error',String(error?.message || error)));
    });
  }
  window.addEventListener('resize',scheduleViewportResize);
  window.visualViewport?.addEventListener('resize',scheduleViewportResize);
  // iPad keyboard + SwiftUI layout can update the actual canvas after the
  // window resize notification. Observe the owned element, not only window.
  const viewportObserver = new ResizeObserver(scheduleViewportResize);
  viewportObserver.observe(document.getElementById('viewer'));
  for (const event of ['wheel','touchstart','pointerdown']) window.addEventListener(event,stopFineScroll,{passive:true,capture:true});
  for (const event of ['wheel','touchmove','pointermove']) window.addEventListener(event,readingInput,{passive:true,capture:true});
  window.addEventListener('error', e => post('diagnostic', e.message));
  window.addEventListener('unhandledrejection', e => post('diagnostic', String(e.reason?.stack || e.reason)));
  document.addEventListener('securitypolicyviolation', e => post('diagnostic', e.violatedDirective + ': ' + e.blockedURI));
  const flatten = (items, depth = 0, prefix = 'toc') => items.flatMap((i, index) => {
    const id = `${prefix}/${index}`;
    return [{id, href:i.href || '', title:(i.label || '').trim() || '未命名章节', depth}, ...flatten(i.subitems || [], depth + 1, id)];
  });
  // Read semantic subheadings even when the publisher omitted them from the TOC.
  // CFI destinations work for headings without IDs and do not modify the EPUB.
  async function buildOutline(owner, navigation, zip, packagePath, mine) {
    const outline = [], emitted = new Set();
    const normalize = value => { try { return decodeURIComponent(value).replace(/^\.\//,''); } catch (_) { return value; } };
    const label = element => (element.textContent || '').replace(/\s+/g,' ').trim();
    for (const section of owner.spine.spineItems.filter(item => item.linear)) {
      if (mine !== revision) return null;
      const path = new URL(section.href, 'https://book.invalid/' + packagePath).pathname.slice(1);
      const file = zip.file(normalize(path)) || zip.file(path);
      const nav = navigation.filter(item => normalize(item.href.split('#')[0]) === normalize(section.href));
      if (!file) { outline.push(...nav); nav.forEach(item => emitted.add(item.id)); continue; }
      const doc = new DOMParser().parseFromString(await file.async('string'),'application/xhtml+xml');
      if (mine !== revision) return null;
      const elements = Array.from(doc.querySelectorAll('*')), order = new Map(elements.map((element,index) => [element,index]));
      const headings = Array.from(doc.querySelectorAll('h1,h2,h3,h4,h5,h6,[role="heading"],.subtitle,.subheading,.section-title')).filter(element => label(element) && label(element).length <= 240);
      const matched = new Map(), events = [];
      for (const [index,item] of nav.entries()) {
        const fragment = item.href.split('#').slice(1).join('#');
        const target = fragment ? doc.getElementById(normalize(fragment)) : null;
        const heading = headings.find(element => !matched.has(element) && (element === target || (target?.contains(element) && label(element) === item.title) || (!target && label(element) === item.title)));
        if (heading) matched.set(heading,item);
        events.push({position:order.get(heading || target) ?? (fragment ? elements.length : 0),nav:item,index});
      }
      headings.forEach((element,index) => events.push({position:order.get(element),element,index}));
      events.sort((a,b) => a.position-b.position || Number(!!b.nav)-Number(!!a.nav) || a.index-b.index);
      const stack = []; let currentNav;
      for (const event of events) {
        if (event.nav) { outline.push(event.nav); emitted.add(event.nav.id); currentNav = event.nav; continue; }
        const element = event.element, rank = Number(element.getAttribute('aria-level') || element.localName.match(/^h([1-6])$/)?.[1] || 6);
        while (stack.length && stack[stack.length-1].rank >= rank) stack.pop();
        let item = matched.get(element);
        if (!item && outline.length < 10000) {
          item = {id:`heading-${section.index}-${event.index}`,href:section.cfiFromElement(element),sourceHref:section.href,title:label(element),depth:stack.length ? stack[stack.length-1].depth+1 : currentNav ? currentNav.depth+1 : 0};
          outline.push(item);
        }
        if (item) stack.push({rank,depth:item.depth});
      }
    }
    outline.push(...navigation.filter(item => !emitted.has(item.id)));
    return outline;
  }
  let chapterAnchors = new WeakMap();
  function chapterAt(start, contents) {
    const candidates = toc.filter(i => i.href && (i.sourceHref || i.href.split('#')[0]) === start.href.split('#')[0]);
    let selected = candidates[0];
    if (!contents || candidates.length < 2) return selected;
    let anchors = chapterAnchors.get(contents.document);
    if (!anchors) {
      anchors = candidates.map(item => {
        if (item.href.startsWith('epubcfi(')) return {item,cfi:item.href};
        const fragment = item.href.split('#').slice(1).join('#');
        if (!fragment) return {item, cfi:null};
        try {
          const element = contents.document.getElementById(decodeURIComponent(fragment));
          if (!element) return {item, cfi:undefined};
          const range = contents.document.createRange(); range.selectNodeContents(element); range.collapse(true);
          return {item, cfi:contents.cfiFromRange(range)};
        } catch (_) { return {item, cfi:undefined}; }
      });
      chapterAnchors.set(contents.document, anchors);
    }
    const compare = new ePub.CFI().compare;
    for (const anchor of anchors) {
      if (anchor.cfi === null || (anchor.cfi && compare(anchor.cfi, start.cfi) <= 0)) selected = anchor.item;
    }
    return selected;
  }
  const scrolling = () => appearance.mode !== 'paged';
  const frames = () => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
  async function scrollViewport(container, distance, duration = 180) {
    const start = container.scrollTop;
    const target = Math.max(0,Math.min(container.scrollHeight-container.clientHeight,start+distance));
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) { container.scrollTop = target; return; }
    const began = performance.now(), owner = rendition;
    await new Promise(resolve => {
      function frame(now) {
        if (rendition !== owner || !container.isConnected) { resolve(); return; }
        const t = Math.min(1,(now-began)/duration);
        container.scrollTop = start + (target-start) * (1-Math.pow(1-t,3));
        if (t < 1) requestAnimationFrame(frame); else resolve();
      }
      requestAnimationFrame(frame);
    });
  }
  function state(location) {
    if (!location?.start) return null;
    const start = location.start, end = location.end;
    const contents = rendition.getContents().find(c => c.sectionIndex === start.index);
    const chapterItem = chapterAt(start, contents);
    const chapter = chapterItem?.title || `第 ${start.index + 1} 章`;
    let progress = (start.index + (start.displayed.page - 1) / Math.max(1,start.displayed.total)) / Math.max(1,book.spine.spineItems.length);
    if (book.locations.length()) progress = book.locations.percentageFromCfi(start.cfi);
    let atStart = location.atStart, atEnd = location.atEnd;
    if (scrolling() && rendition?.manager?.views) {
      const manager = rendition.manager, bounds = manager.container.getBoundingClientRect();
      const first = manager.views.first(), last = manager.views.last();
      atStart = first?.section.index === book.spine.first().index && first.element.getBoundingClientRect().top >= bounds.top - 2;
      atEnd = last?.section.index === book.spine.last().index && last.element.getBoundingClientRect().bottom <= bounds.bottom + 2;
    }
    const anchor = contents ? BookSlideProgress.capture(contents,start.cfi,start.href) : {href:start.href,quote:'',fraction:0};
    const spine = book.spine.spineItems.filter(s=>s.linear);
    progress = (Math.max(0,spine.findIndex(s=>s.index === start.index)) + anchor.fraction) / Math.max(1,spine.length);
    return {chapterHref:chapterItem?.href || start.href,viewportOffset:scrolling() ? rendition.manager.container.scrollTop : null,anchor,userDriven,mode:scrolling() ? 'scroll' : 'paged', locator:start.cfi, chapter, page:start.displayed.page, pageCount:start.displayed.total,
      progress:atEnd ? 1 : Math.max(0,Math.min(0.999,progress || 0)), canGoNext:!atEnd, canGoPrevious:!atStart};
  }
  function anchorPoint(locator) {
    try {
      const contents = rendition.getContents().find(c => c.sectionIndex === new ePub.CFI(locator).spinePos);
      const frame = contents.document.defaultView.frameElement.getBoundingClientRect(), rect = contents.range(locator).getBoundingClientRect();
      return {x:frame.left+rect.left,y:frame.top+rect.top};
    } catch { return null; }
  }
  function layoutKey(settings = appearance) {
    return JSON.stringify([canvasSize().width,canvasSize().height,...['mode','font','fontSize','lineHeight','margin','scrollSideInset','scrollMaxTextWidth','scrollMinimumInset','scrollStartInset','scrollEndInset','paragraphSpacing','headingSpacing'].map(k=>settings[k] ?? null)]);
  }
  function captureViewport() {
    if (!current) return null;
    let locator = current.locator, point = anchorPoint(locator), anchor = current.anchor;
    // EPUB.js can report the start of an entire unbroken Chinese paragraph.
    // If that point is off screen, hit-test visible text to capture a character
    // locator; carrying a paragraph's old pixel distance across fonts is wrong.
    if (!point || point.x < -1 || point.x >= innerWidth || point.y < -1 || point.y >= innerHeight) {
      const line = Math.max(12,appearance.fontSize*appearance.lineHeight);
      const contents = rendition.getContents().filter(c=>{
        const f=c.document.defaultView.frameElement.getBoundingClientRect();
        return f.bottom>0 && f.top<innerHeight && f.right>0 && f.left<innerWidth;
      });
      outer: for (const c of contents) {
        const frame = c.document.defaultView.frameElement.getBoundingClientRect();
        const inset = parseFloat(c.window.getComputedStyle(c.document.body).paddingLeft) || 0;
        for (const y of [Math.max(2,frame.top+2),Math.max(2,frame.top+2)+line/2,Math.max(2,frame.top+2)+line]) {
          for (const x of [Math.min(innerWidth-2,Math.max(2,frame.left+inset+1)),innerWidth/4,innerWidth/2]) {
            const range = c.document.caretRangeFromPoint?.(x-frame.left,y-frame.top);
            if (!range || range.startContainer.nodeType !== 3 || range.startOffset >= range.startContainer.length) continue;
            const glyph = range.cloneRange();
            const length = range.startContainer.data.codePointAt(range.startOffset)>0xffff ? 2 : 1;
            glyph.setEnd(glyph.startContainer,glyph.startOffset+length);
            const r = glyph.getBoundingClientRect();
            if (frame.left+r.left < -1 || frame.left+r.left>=innerWidth || frame.top+r.top < -1 || frame.top+r.top>=innerHeight) continue;
            locator = c.cfiFromRange(range); point = anchorPoint(locator);
            anchor = BookSlideProgress.capture(c,locator,book.spine.get(c.sectionIndex).href);
            break outer;
          }
        }
      }
    }
    return {locator,point,mode:appearance.mode,layoutKey:layoutKey(),anchor};
  }
  function notify(location) {
    // A layout/navigation transaction owns its destination. Intermediate
    // chapter-start CFIs must never reach native persistence or sync.
    if (resizeAnchor || navigating || !active || innerWidth < 1 || innerHeight < 1) return;
    // EPUB.js can deliver an old display after the resize promise has settled.
    // Keep the actual text at the committed point until reading input chooses
    // another destination. Keeping only its CFI would hide a visible jump.
    if (!userDriven && resizedPassage?.point && resizedPassage.layoutKey === layoutKey()) {
      const point = anchorPoint(resizedPassage.locator);
      if (!point || Math.abs(point.x-resizedPassage.point.x)>1 || Math.abs(point.y-resizedPassage.point.y)>1) {
        restoreViewport(rendition,resizedPassage).catch(()=>{});
        return;
      }
    }
    const actual = rendition?.currentLocation();
    if (!actual?.start) return;
    const next = state(actual);
    if (!next) return;
    current = next;
    if (current) {
      viewportSize = canvasSize();
      viewportAnchor = resizedPassage || captureViewport();
      // At the end of a short final chapter, scroll clamping can leave a few
      // pixels of the previous chapter above it. EPUB.js then reports that
      // previous section, although our visible/resumed anchor is in this one.
      if (!userDriven && scrolling() && viewportAnchor?.anchor) {
        const index = new ePub.CFI(viewportAnchor.locator).spinePos;
        if (index !== actual.start.index) {
          const section = book.spine.get(index), contents = rendition.getContents().find(c=>c.sectionIndex===index);
          const chapter = chapterAt({href:section.href,cfi:viewportAnchor.locator},contents);
          const height = rendition.manager.container.clientHeight;
          const total = Math.max(1,Math.ceil((contents?.document.documentElement.scrollHeight || height)/height));
          Object.assign(current,{locator:viewportAnchor.locator,anchor:viewportAnchor.anchor,
            chapterHref:chapter?.href || section.href,chapter:chapter?.title || `第 ${index+1} 章`,
            page:Math.min(total,Math.max(1,Math.floor(-(contents?.document.defaultView.frameElement.getBoundingClientRect().top || 0)/height)+1)),pageCount:total});
        }
      }
      current.session = readerSession;
      current.viewport = {...viewportAnchor,positionLocator:current.locator,point:anchorPoint(viewportAnchor.locator),mode:appearance.mode,layoutKey:layoutKey()};
      post('position', current);
    }
  }
  async function settledLayout() {
    let pending;
    do { pending = layoutWork; await pending; } while (pending !== layoutWork);
  }
  async function readyToNavigate() {
    const owner = rendition;
    let queue;
    do {
      if (viewportResizeFrame !== null) await frames();
      queue = layoutQueue;
      await queue;
      await settledLayout();
    } while (owner === rendition && (queue !== layoutQueue || viewportResizeFrame !== null));
    if (owner !== rendition) throw Error('阅读内容已改变');
    if (!active) throw Error('阅读器不在前台');
  }
  function restoreViewport(owner, anchor, preservePoint = true) {
    resizeAnchor = anchor;
    const generation = ++resizeRevision, viewportGeneration = viewportRequest;
    const valid = () => owner === rendition && generation === resizeRevision && viewportGeneration === viewportRequest && active && canvasSize().width > 0 && canvasSize().height > 0;
    // EPUB.js enqueues its automatic stale-location display after resized.
    // Our queued restore follows it and waits for fonts and column geometry.
    layoutWork = Promise.resolve().then(async () => {
      if (!valid()) return;
      await owned(owner.display(anchor.locator),owner);
      if (!valid()) return;
      await owned(Promise.all(owner.getContents().map(c=>c.document.fonts?.ready)),owner);
      if (!valid()) return;
      if (scrolling()) {
        await owned(owner.manager.fill(),owner);
        if (!valid()) return;
      }
      await frames();
      if (!valid()) return;
      await owned(owner.display(anchor.locator),owner);
      await frames();
      if (!valid()) return;
      const point = anchorPoint(anchor.locator), container = owner.manager.container;
      if (point && anchor.point && preservePoint) {
        if (scrolling()) container.scrollTop = Math.round(container.scrollTop+point.y-anchor.point.y);
        else {
          // EPUB.js expands a collapsed CFI to the next space. A Chinese
          // paragraph spanning columns can then resolve to the previous page.
          const pageWidth = owner.manager.layout.delta || container.clientWidth;
          const column = anchor.layoutKey === layoutKey()
            ? Math.round((point.x-anchor.point.x)/pageWidth)
            : Math.floor((point.x-container.getBoundingClientRect().left+0.5)/pageWidth);
          // With different typography, keep the character's containing page;
          // its old horizontal pixel offset must not choose the following page.
          container.scrollLeft += column*pageWidth;
        }
        await frames();
      }
      if (!valid()) return;
      resizeAnchor = null;
      resizedPassage = {...anchor,point:anchorPoint(anchor.locator),mode:appearance.mode,layoutKey:layoutKey()};
      userDriven = false;
      notify(owner.currentLocation());
      return current;
    }).catch(error => {
      if (!valid()) return;
      resizeAnchor = null;
      post('error', String(error?.message || error));
      throw error;
    });
    return layoutWork;
  }
  async function resizeViewport(owner) {
    if (owner !== rendition) return current;
    if (!active || innerWidth < 1 || innerHeight < 1) { deferredLayout = true; return current; }
    const anchor = resizeAnchor || viewportAnchor || captureViewport();
    resizeAnchor = anchor;
    const generation = resizeRevision;
    owner.resize(canvasSize().width,canvasSize().height);
    // A round trip can end at the original size without an EPUB.js event.
    if (generation === resizeRevision) restoreViewport(owner,anchor).catch(()=>{});
    await settledLayout();
  }
  function restoreAfterResize(owner) {
    if (opening || navigating || !current || owner !== rendition) return;
    stopFineScroll(); userDriven = false;
    if (!active || innerWidth < 1 || innerHeight < 1) { deferredLayout = true; return; }
    const anchor = resizeAnchor || viewportAnchor || captureViewport();
    // Errors are reported by the transaction; automatic resize has no caller.
    restoreViewport(owner,anchor).catch(()=>{});
  }
  const themes = {
    paper: {background:'#F2E3C8',color:'#382D20',link:'#706348'},
    light: {background:'#FFFFFF',color:'#242824',link:'#466650'},
    night: {background:'#202725',color:'#D9DFD8',link:'#ADCFB5'}
  };
  function style(settings) {
    appearance = settings;
    const colors = themes[settings.theme] || themes.paper;
    document.body.style.background = colors.background;
    annotations.restyle(settings.theme);
    if (!rendition) return;
    for (const contents of rendition.getContents()) contents.document.documentElement.dataset.bookslideFont = settings.font;
    const fonts = {pingfang:'"PingFang SC", -apple-system, sans-serif', serif:'"BookSlide Serif", "Iowan Old Style", "Songti SC", "Noto Serif CJK SC", Georgia, serif', sans:'-apple-system, "PingFang SC", sans-serif', publisher:'inherit'};
    // Keep the viewport edge-to-edge. Reading margins belong to the chapter
    // content, so they never become a smaller, visibly clipped web-view frame.
    const inset = Math.max(0,settings.margin / 2,settings.scrollMinimumInset || 0);
    const side = Math.max(0,Math.min(30,settings.scrollSideInset || 0));
    const textInset = settings.scrollMaxTextWidth > 0
      ? `calc(max(0px, (100vw - ${settings.scrollMaxTextWidth}px) / 2) + ${inset}px)`
      : `max(${inset}px, ${side}vw)`;
    const paragraphSpacing = settings.paragraphSpacing ?? 1;
    const headingSpacing = settings.headingSpacing ?? 1;
    rendition.themes.default({
      ...(serifURL ? {'@font-face':{'font-family':'"BookSlide Serif"','src':`url("${serifURL}") format("woff2")`,'font-weight':'400','font-style':'normal'}} : {}),
      'html': {'background':`${colors.background} !important`},
      // Chapters share one continuous sheet. Vertical padding belongs only at
      // the book's ends; repeating it at every iframe makes a blank seam.
      'body': {'background':`${colors.background} !important`, 'color':`${colors.color} !important`, 'line-height':`${settings.lineHeight} !important`, 'overflow-wrap':'break-word', '-webkit-font-smoothing':'antialiased', 'box-sizing':'border-box','margin':'0 !important','max-width':'none !important','padding':scrolling() ? `0 ${textInset} !important` : '0 !important'},
      'body[data-bookslide-first]': {'padding-top':scrolling() ? `${settings.scrollStartInset || 20}px !important` : '0 !important'},
      'body[data-bookslide-last]': {'padding-bottom':scrolling() ? `${settings.scrollEndInset || 24}px !important` : '0 !important'},
      'p, li, blockquote': {'line-height':`${settings.lineHeight} !important`},
      'html[data-bookslide-font="pingfang"] body, html[data-bookslide-font="pingfang"] p, html[data-bookslide-font="pingfang"] li, html[data-bookslide-font="pingfang"] blockquote':
        {'font-family':`${fonts.pingfang} !important`,'font-weight':'300 !important','letter-spacing':'normal !important','word-spacing':'normal !important'},
      'p': {'orphans':'2','widows':'2', ...(settings.font !== 'publisher' ? {'margin-top':'0 !important','margin-bottom':`${paragraphSpacing}em !important`,'text-align':'justify','letter-spacing':'normal !important'} : {})},
      'a': {'color':`${colors.link} !important`},
      'img, svg': {'max-width':'100% !important','object-fit':'contain'},
      'pre': {'white-space':'pre-wrap !important'},
      'h1, h2, h3': {'line-height':'1.4 !important', ...(settings.font !== 'publisher' ? {'font-size':'1.35em !important','margin-top':'0.5em !important','margin-bottom':`${headingSpacing}em !important`} : {})},
      '::selection': {'background':'#B4CBB5','color':'#1F3025'}
    });
    rendition.themes.fontSize(`${settings.fontSize}px`);
    if (settings.font === 'publisher') rendition.themes.removeOverride('font-family');
    else rendition.themes.font(fonts[settings.font] || fonts.serif);
  }
  async function display(target) {
    stopFineScroll(); resizedPassage = appearanceOrigin = null;
    annotations.dismiss(true);
    const owner = rendition;
    navigating = true;
    try {
      await owned(owner.display(target),owner);
      if (scrolling() && target) await owned(owner.manager.fill(),owner);
      await frames();
      if (owner !== rendition) throw Error('阅读内容已改变');
      if (target) await owned(owner.display(target),owner);
      await frames();
      if (owner !== rendition) throw Error('阅读内容已改变');
      if (typeof target === 'string' && target.startsWith('epubcfi(')) {
        // Navigate to the collapsed text point, not EPUB.js's expanded word or
        // Chinese paragraph bounding box, for bookmarks/search/sync as well.
        const point = anchorPoint(target), container = owner.manager.container;
        if (point) {
          const bounds = container.getBoundingClientRect();
          if (scrolling()) container.scrollTop += point.y-bounds.top;
          else {
            const width = owner.manager.layout.delta || container.clientWidth;
            container.scrollLeft += Math.floor((point.x-bounds.left+0.5)/width)*width;
          }
          await frames();
        }
      }
    } finally { if (owner === rendition) navigating = false; }
    const location = owner.currentLocation();
    if (location?.start) notify(location);
    return current;
  }
  function requestTurn(direction) {
    if (handwritingActive || opening || moving || resizeAnchor || !current || !(direction === 'next' ? current.canGoNext : current.canGoPrevious)) return;
    post('turn',direction);
  }
  window.reader = {
    beginReadingInput,
    async settledPosition() {
      const owner = rendition;
      let queue, viewportGeneration;
      do {
        viewportGeneration = viewportRequest;
        await frames();
        queue = layoutQueue;
        await queue;
        await settledLayout();
      } while (owner === rendition && (queue !== layoutQueue || viewportGeneration !== viewportRequest || viewportResizeFrame !== null));
      return owner === rendition ? current : null;
    },
    async captureReadingPosition() {
      const owner = rendition;
      await this.settledPosition();
      if (!owner || owner !== rendition) return null;
      notify(owner.currentLocation());
      await settledLayout();
      return owner === rendition ? current : null;
    },
    async setActive(value) {
      active = !!value;
      if (!active) { stopFineScroll(); if (resizeAnchor) deferredLayout = true; return current; }
      if (deferredLayout && rendition && current) {
        deferredLayout = false;
        const owner = rendition;
        const work = layoutQueue.catch(()=>{}).then(()=>resizeViewport(owner));
        layoutQueue = work;
        await work;
      }
      if (deferredAppearance) {
        const settings = deferredAppearance; deferredAppearance = null;
        return await this.appearance(settings);
      }
      return current;
    },
    pageNoteLayoutKey() {
      const key = [innerWidth,innerHeight,appearance.mode,appearance.font,appearance.fontSize,appearance.lineHeight,appearance.margin,appearance.theme,appearance.scrollSideInset || 0,appearance.scrollMaxTextWidth || 0];
      if (appearance.paragraphSpacing != null || appearance.headingSpacing != null) key.push(appearance.paragraphSpacing ?? 1,appearance.headingSpacing ?? 1);
      return JSON.stringify(key);
    },
    setPageNotes(notes,session) { if (session === pageNotes.session) pageNotes.setItems(notes); },
    pageNotesOnScreen() { pageNotes.render(); return pageNotes.visible; },
    pageNoteAnchorsOnScreen(notes) {
      if (!rendition) return [];
      return notes.filter(note => {
        try {
          const index = new ePub.CFI(note.anchor.locator).spinePos;
          const c = rendition.getContents().find(c=>c.sectionIndex === index); if (!c) return false;
          const r = c.range(note.anchor.locator).getBoundingClientRect(), f = c.document.defaultView.frameElement.getBoundingClientRect();
          return f.top+r.bottom > 0 && f.top+r.top < innerHeight && f.left+r.right > 0 && f.left+r.left < innerWidth;
        } catch (_) { return false; }
      }).map(note=>note.id);
    },
    setPageHandwriting(active, snapshot = true) {
      handwritingActive = !!active;
      // A new page snapshot must never bake existing editable ink into its paper.
      pageNotes.layer.style.visibility = active && snapshot ? 'hidden' : '';
      if (active) { stopFineScroll(); annotations.dismiss(true); }
    },
    setInlinePageInk(id) { pageNotes.edit(id); },
    setPageInkSnapshot(hidden) { pageNotes.layer.style.visibility = hidden ? 'hidden' : ''; },
    // Native PencilKit uses this same viewport as the live EPUB. No navigation,
    // scroll cancellation or layout changes are performed while polling it.
    livePageInkContext(notes) {
      if (opening || moving || resizeAnchor || handwritingActive || !rendition) return null;
      const location = rendition.currentLocation();
      if (!current || !location?.start) return null;
      const p = {...current,locator:location.start.cfi};
      const contents = rendition.getContents();
      if (!annotations.menu.hidden || contents.some(c => c.window.getSelection()?.toString())) return null;
      const c = contents.find(c => c.sectionIndex === new ePub.CFI(p.locator).spinePos);
      if (!c) return null;
      const rect = c.range(p.locator).getBoundingClientRect(), frame = c.document.defaultView.frameElement.getBoundingClientRect();
      const anchor = {locator:p.locator,chapter:p.chapter,chapterHref:p.chapterHref,progress:p.progress,
        referenceX:frame.left+rect.left,referenceY:frame.top+rect.top,
        viewportWidth:innerWidth,viewportHeight:innerHeight,layoutKey:this.pageNoteLayoutKey()};
      const textKey=JSON.stringify([anchor.locator,anchor.referenceX,anchor.referenceY,anchor.layoutKey,innerWidth,innerHeight]);
      anchor.textSpans=[];
      if(this.inkTextCache?.document===c.document && this.inkTextCache.key===textKey)anchor.textSpans=this.inkTextCache.spans;
      else {
      // Capture source words once per prepared ink viewport, never per stroke.
      // CFI identity and source offsets survive font and orientation changes.
      const segmenter=typeof Intl.Segmenter==='function' ? new Intl.Segmenter('zh',{granularity:'word'}) : null;
      const blocks=c.document.querySelectorAll('p,li,blockquote,h1,h2,h3,h4,pre,figcaption');
      for(const block of blocks){
        if(anchor.textSpans.length>=1200)break;
        const br=block.getBoundingClientRect();
        if(frame.top+br.bottom<0 || frame.top+br.top>innerHeight || frame.left+br.right<0 || frame.left+br.left>innerWidth)continue;
        try{
          const whole=c.document.createRange();whole.selectNodeContents(block);const blockID=c.cfiFromRange(whole);
          const walker=c.document.createTreeWalker(block,NodeFilter.SHOW_TEXT);let node,offset=0;
          while((node=walker.nextNode())){
            const text=node.textContent || '';
            if(node.parentElement.closest('p,li,blockquote,h1,h2,h3,h4,pre,figcaption')!==block){offset+=text.length;continue;}
            const segments=segmenter ? segmenter.segment(text) : Array.from(text.matchAll(/\S+|\s+/gu),m=>({segment:m[0],index:m.index}));
            for(const item of segments){
              if(!item.segment.trim() || anchor.textSpans.length>=1200)continue;
              const range=c.document.createRange();range.setStart(node,item.index);range.setEnd(node,item.index+item.segment.length);
              const boxes=Array.from(range.getClientRects()).map(r=>({x:frame.left+r.left,y:frame.top+r.top,width:r.width,height:r.height}))
                .filter(r=>r.width>0 && r.height>0 && r.x+r.width>0 && r.y+r.height>0 && r.x<innerWidth && r.y<innerHeight);
              if(boxes.length)anchor.textSpans.push({id:c.cfiFromRange(range),block:blockID,offset:offset+item.index,text:item.segment,boxes});
            }
            offset+=text.length;
          }
        }catch{/* A detached source range cannot prevent preserving ink. */}
      }
      this.inkTextCache={document:c.document,key:textKey,spans:anchor.textSpans};
      }
      const placements = [];
      for (const note of notes || []) {
        if (note.anchor.layoutKey !== anchor.layoutKey) continue;
        try {
          const content = contents.find(c => c.sectionIndex === new ePub.CFI(note.anchor.locator).spinePos);
          if (!content) continue;
          const r = content.range(note.anchor.locator).getBoundingClientRect(), f = content.document.defaultView.frameElement.getBoundingClientRect();
          const x = f.left+r.left-note.anchor.referenceX, y = f.top+r.top-note.anchor.referenceY;
          if (x+note.anchor.viewportWidth <= 1 || y+note.anchor.viewportHeight <= 1 || x >= innerWidth-1 || y >= innerHeight-1) continue;
          placements.push({id:note.id,x,y});
        } catch (_) {}
      }
      return {anchor,placements,token:JSON.stringify([anchor.locator,anchor.referenceX,anchor.referenceY,anchor.layoutKey])};
    },
    async capturePageNoteAnchor() {
      if (opening || moving || !rendition) throw Error('正在排版，请稍候');
      stopFineScroll(); annotations.dismiss(true); await frames();
      const p = state(rendition.currentLocation());
      if (!p) throw Error('尚未准备好书页');
      const index = new ePub.CFI(p.locator).spinePos;
      const contents = rendition.getContents().find(c=>c.sectionIndex === index);
      if (!contents) throw Error('当前书页尚未排版');
      const rect = contents.range(p.locator).getBoundingClientRect(), frame = contents.document.defaultView.frameElement.getBoundingClientRect();
      return {locator:p.locator,chapter:p.chapter,chapterHref:p.chapterHref,progress:p.progress,referenceX:frame.left+rect.left,referenceY:frame.top+rect.top,viewportWidth:innerWidth,viewportHeight:innerHeight,layoutKey:this.pageNoteLayoutKey()};
    },
    annotationChapter(cfi, contents) {
      const section = book.spine.get(contents.sectionIndex);
      return chapterAt({href:section.href,cfi},contents)?.title || current?.chapter || '';
    },
    annotationChapterHref(cfi,contents) {
      const section = book.spine.get(contents.sectionIndex);
      return chapterAt({href:section.href,cfi},contents)?.href || section.href;
    },
    outline() { return outlineReady; },
    async sourceExcerpt(locator,href) {
      if (!locator && href?.startsWith('epubcfi(')) locator = href;
      if (!book) throw Error('请先打开图书');
      if (locator?.startsWith('epubcfi(')) {
        const range = await book.getRange(locator);
        if (!range) throw Error('原文位置暂时无法读取');
        let element = range.startContainer.nodeType === 1 ? range.startContainer : range.startContainer.parentElement;
        element = element?.closest('p,li,blockquote,h1,h2,h3') || element;
        const parts = [];
        if (element?.previousElementSibling) parts.push(element.previousElementSibling.textContent);
        if (element) parts.push(element.textContent);
        if (element?.nextElementSibling) parts.push(element.nextElementSibling.textContent);
        return (parts.filter(Boolean).join('\n\n') || range.toString()).slice(0,8000);
      }
      const section = book.spine.get(href);
      if (!section) throw Error('本章原文暂时无法读取');
      const doc = await section.load(book.load.bind(book));
      return Array.from(doc.querySelectorAll('h1,h2,h3,p,li,blockquote')).map(p=>p.textContent).filter(Boolean).join('\n\n').slice(0,8000);
    },
    async discussionExcerpt(locator) {
      if (!book || !locator?.startsWith('epubcfi(')) return '';
      const range = await book.getRange(locator);
      if (!range) throw Error('原文位置暂时无法读取');
      const doc = range.startContainer.ownerDocument;
      const before = doc.createRange();
      before.selectNodeContents(doc.body || doc.documentElement);
      before.setEnd(range.startContainer,range.startOffset);
      // Loading context never advances the reading cursor or reads ahead.
      return (before.cloneContents().textContent || '').trim().slice(-3000);
    },
    async readingDiscussionExcerpts(locator,start,end) {
      const owner = book;
      if (!owner || !locator?.startsWith('epubcfi(')) return [];
      // The visible end includes the page being read, even at the beginning of a chapter.
      const visible = rendition?.location;
      const boundary = visible?.start?.cfi === locator && visible.end?.cfi ? visible.end.cfi : locator;
      const sectionFor = href => href.startsWith('epubcfi(') ? owner.spine.get(new ePub.CFI(href).spinePos) : owner.spine.get(href);
      const first = start ? sectionFor(start) : owner.spine.first();
      const cursor = sectionFor(boundary);
      const next = end ? sectionFor(end) : null;
      if (!first || !cursor || (end && !next) || first.index > cursor.index) return [];
      const last = Math.min(cursor.index,next?.index ?? cursor.index);
      const sections = owner.spine.spineItems.filter(section => section.linear && section.index >= first.index && section.index <= last);
      const count = Math.min(4,sections.length);
      const samples = [];
      const endpoint = async (href,doc,atEnd) => {
        if (href.startsWith('epubcfi(')) {
          const range = await owner.getRange(href);
          return range?.startContainer.ownerDocument === doc
            ? atEnd ? [range.endContainer,range.endOffset] : [range.startContainer,range.startOffset] : null;
        }
        const hash = href.split('#').slice(1).join('#');
        if (!hash) return [doc.body || doc.documentElement,0];
        const element = doc.getElementById(decodeURIComponent(hash));
        if (!element?.parentNode) return null;
        return [element.parentNode,Array.from(element.parentNode.childNodes).indexOf(element)];
      };
      for (let i=0; i<count; i++) {
        const section = sections[count === 1 ? 0 : Math.round(i*(sections.length-1)/(count-1))];
        if (owner !== book) return [];
        const doc = (await section.load(owner.load.bind(owner))).ownerDocument;
        const range = doc.createRange();
        range.selectNodeContents(doc.body || doc.documentElement);
        if (start && section.index === first.index) {
          const point = await endpoint(start,doc,false);
          if (!point) continue;
          range.setStart(...point);
        }
        const limits = [section.index === cursor.index ? boundary : "", section.index === next?.index ? end : ""].filter(Boolean);
        for (const href of limits) {
          const point = await endpoint(href,doc,href === boundary);
          if (!point) { range.collapse(true); break; }
          if (range.comparePoint(...point) <= 0) range.setEnd(...point);
        }
        const content = range.cloneContents();
        content.querySelectorAll('script,style,template').forEach(node=>node.remove());
        content.querySelectorAll('br,p,h1,h2,h3,h4,h5,h6,li,blockquote,div,section,article')
          .forEach(node=>node.after(doc.createTextNode('\n')));
        const text = (content.textContent || '').replace(/[^\S\n]+/g,' ').replace(/\s*\n\s*/g,'\n').trim();
        if (!text) continue;
        if (count === 1 && text.length > 2800) {
          samples.push(text.slice(0,1400),text.slice(-1400));
        } else samples.push(i === count-1 && !next ? text.slice(-1400) : text.slice(0,1400));
      }
      return samples;
    },
    setAnnotations(items,session,color) {
      if (!session || session === annotations.session) {
        annotations.setItems(items);
        if (['yellow','green','blue','pink','purple','underline'].includes(color)) annotations.lastColor = color;
      }
    },
    annotationTap(x,y) { return annotations.tap(x,y); },
    pencilSelect(x,y,phase) { return annotations.pencilSelect(x,y,phase); },
    annotationContext() { annotations.poll(true); return annotations.active ? {session:annotations.session,...annotations.active,existing:annotations.items.some(i=>i.id === annotations.active.id)} : null; },
    dismissAnnotations() { annotations.dismiss(true); },
    dismissAnnotationSelection(id,cfi,session) { return session === annotations.session && annotations.dismissSelection(id,cfi); },
    allowsReadingGesture(x, y) {
      if (handwritingActive || opening || moving || resizeAnchor || !current || !rendition) return false;
      if (!annotations.menu.hidden) return false;
      for (const contents of rendition.getContents()) {
        if (contents.window.getSelection()?.toString()) return false;
        const frame = contents.document.defaultView.frameElement;
        if (!frame) continue;
        const rect = frame.getBoundingClientRect();
        if (x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) continue;
        const target = contents.document.elementFromPoint(x-rect.left,y-rect.top);
        return !!target && !target.closest('a,button,input,textarea,select,[contenteditable="true"]');
      }
      return false;
    },
    async open(base64, locator, settings, font, viewport = null) {
      if (!serifURL && font) serifURL = URL.createObjectURL(new Blob([Uint8Array.from(atob(font), c => c.charCodeAt(0))],{type:'font/woff2'}));
      const mine = ++revision;
      cancelPendingOwnerWork();
      stopFineScroll();
      annotations.detach();
      pageNotes.detach(); handwritingActive = false;
      opening = true; navigating = false; deferredLayout = false; deferredAppearance = null; current = null; userDriven = false; readerSession = settings.annotationSession; appearanceRequest++;
      resizeAnchor = viewportAnchor = resizedPassage = appearanceOrigin = null; resizeRevision++;
      layoutWork = layoutQueue = Promise.resolve();
      if (rendition) rendition.destroy();
      if (book) book.destroy();
      document.getElementById('viewer').replaceChildren();
      post('diagnostic','opening archive');
      const bytes = Uint8Array.from(atob(base64), c => c.charCodeAt(0));
      const zip = await JSZip.loadAsync(bytes);
      const entries = Object.values(zip.files);
      let total = 0;
      if (entries.length > 15000) throw Error('书籍资源过多，暂时无法打开');
      for (const file of entries) {
        const size = file._data?.uncompressedSize || 0;
        total += size;
        if (size > 40 * 1024 * 1024 || total > 200 * 1024 * 1024) throw Error('解压后的书籍过大，暂时无法打开');
      }
      if (!zip.file('META-INF/container.xml')) throw Error('这不是有效的 EPUB 文件');
      const containerXML = new DOMParser().parseFromString(await zip.file('META-INF/container.xml').async('string'),'application/xml');
      const packagePath = containerXML.getElementsByTagName('rootfile')[0]?.getAttribute('full-path');
      if (!packagePath || !zip.file(packagePath)) throw Error('EPUB 缺少内容清单');
      const packageData = await zip.file(packagePath).async('base64');
      book = ePub(bytes.buffer, {replacements:'blobUrl'});
      await Promise.race([book.opened, new Promise((_, reject) => setTimeout(() => reject(Error("书籍载入超时，请检查 EPUB 文件")), 10000))]);
      await Promise.race([book.ready, new Promise((_, reject) => setTimeout(() => reject(Error("书籍资源不完整或无法读取")), 10000))]);
      if (mine !== revision) throw Error('已切换书籍');
      metadata = await book.loaded.metadata;
      if (metadata.layout === 'pre-paginated') throw Error('暂不支持固定版式 EPUB，请使用可重排版 EPUB');
      toc = flatten((await book.loaded.navigation).toc);
      post('diagnostic','rendering '+JSON.stringify({w:innerWidth,h:innerHeight,visibility:document.visibilityState,rect:document.getElementById('viewer').getBoundingClientRect().toJSON()}));
      // Numeric dimensions disable EPUB.js's competing debounced window
      // resizer. Native viewport changes and preferences use one host queue.
      rendition = book.renderTo('viewer', {width:canvasSize().width,height:canvasSize().height,resizeOnOrientationChange:false,manager:BookSlideContinuous,flow:settings.mode === 'paged' ? 'paginated' : 'scrolled',spread:'none',
        bookslidePreserveViewport:()=>!opening && !navigating && !resizeAnchor,
        allowScriptedContent:false,allowPopups:false,gap:Math.max(0,settings.margin ?? 64)});
      const resizeOwner = rendition;
      rendition.on('resized', () => restoreAfterResize(resizeOwner));
      rendition.on('relocated', location => { if (mine === revision) notify(location); });
      rendition.on('displayError', error => post('error', String(error?.message || error)));
      rendition.on('started', () => resizeOwner.manager.on('scrollError', error => { if (mine === revision) post('error', String(error?.message || error)); }));
      rendition.on('keydown', event => {
        if (['ArrowRight','ArrowLeft','ArrowUp','ArrowDown','PageUp','PageDown'].includes(event.key)) {
          event.preventDefault();
          requestTurn(['ArrowRight','ArrowDown','PageDown'].includes(event.key) ? 'next' : 'previous');
        }
      });
      rendition.hooks.content.register(async contents => {
        contents.document.documentElement.dataset.bookslideFont = appearance.font;
        if (contents.sectionIndex === book.spine.first().index) contents.document.body.setAttribute('data-bookslide-first','');
        if (contents.sectionIndex === book.spine.last().index) contents.document.body.setAttribute('data-bookslide-last','');
        for (const event of ['wheel','touchmove','pointermove']) contents.document.addEventListener(event,readingInput,{passive:true,capture:true});
        for (const event of ['wheel','touchstart','pointerdown']) contents.document.addEventListener(event,stopFineScroll,{passive:true,capture:true});
        if (!appearance.nativeTouchControls) BookSlideInput.install(contents.document, requestTurn, {scrolling});
        if (serifURL && appearance.font === 'serif') await contents.document.fonts.load('20px "BookSlide Serif"');
        if (appearance.font === 'pingfang') await contents.document.fonts.load(`300 ${appearance.fontSize}px "PingFang SC"`);
      });
      post('diagnostic','applying styles');
      style(settings);
      post('metadata', {packageData,title:metadata.title || '',author:metadata.creator || '',toc});
      book.coverUrl().then(async url => {
        if (!url || !url.startsWith('blob:')) return;
        const blob = await (await fetch(url)).blob();
        if (blob.size > 4 * 1024 * 1024 || !/^image\/(png|jpeg|webp|gif)$/.test(blob.type)) return;
        const file = new FileReader();
        file.onload = () => { if (mine === revision) post('cover', String(file.result).split(',')[1]); };
        file.readAsDataURL(blob);
      }).catch(() => {});
      const resume = viewport?.locator?.startsWith('epubcfi(') ? viewport : null;
      if (resume) resizeAnchor = resume;
      try { await Promise.race([display(resume?.locator || locator || undefined), new Promise((_, reject) => setTimeout(() => reject(Error("章节排版超时")), 10000))]); }
      catch (error) { if (locator) await display(); else throw error; }
      if (mine !== revision) throw Error('已取消');
      opening = false;
      if (resume) await restoreViewport(rendition,resume,resume.layoutKey === layoutKey());
      const viewportBounds = rendition.manager.container.getBoundingClientRect();
      if (Math.abs(viewportBounds.width-canvasSize().width)>1 || Math.abs(viewportBounds.height-canvasSize().height)>1) await resizeViewport(rendition);
      if (mine !== revision) throw Error('已取消');
      annotations.attach(rendition,book,settings);
      pageNotes.attach(rendition,settings.annotationSession,settings.pageNotes);
      const outlineBook = book;
      outlineReady = buildOutline(outlineBook,toc,zip,packagePath,mine).then(outline => {
        if (!outline || mine !== revision || book !== outlineBook) return;
        toc = outline; chapterAnchors = new WeakMap();
        post('outline',{session:settings.annotationSession,toc});
        notify(rendition.currentLocation());
        return toc;
      }).catch(error => { if (mine === revision) post('diagnostic','Subheadings unavailable: ' + String(error)); return []; });
      // Location generation is bounded by the import limits and doesn't block the first page.
      book.locations.generate(1500).then(() => {
        if (mine === revision && rendition) { notify(rendition.currentLocation()); post('locationsReady',true); }
      }).catch(() => {});
      return current;
    },
    cancel() {
      cancelPendingOwnerWork();
      stopFineScroll();
      annotations.detach();
      pageNotes.detach(); handwritingActive = false;
      resizeAnchor = viewportAnchor = resizedPassage = appearanceOrigin = null; resizeRevision++; appearanceRequest++;
      if (viewportResizeFrame !== null) cancelAnimationFrame(viewportResizeFrame);
      viewportResizeFrame = null;
      revision++; searchRevision++; opening = false; moving = false; current = null;
      rendition?.destroy(); rendition = null;
      book?.destroy(); book = null;
      document.getElementById('viewer').replaceChildren();
    },
    async progress(value) {
      if (handwritingActive) throw Error('正在书写，请先完成批注');
      await readyToNavigate();
      if (!book || !book.locations.length() || moving || opening) return current;
      userDriven = true;
      return await display(book.locations.cfiFromPercentage(Math.min(0.999999,Math.max(0,value))));
    },
    async turn(direction, lines = null, acceptInput = false) {
      if (handwritingActive) throw Error('正在书写，请先完成批注');
      if (lines !== null && (!Number.isFinite(lines) || lines < 1/16 || lines > 16 || !scrolling())) throw Error('滚动幅度或模式无效');
      await readyToNavigate();
      if (opening || moving || !current) throw Error('正在排版，请稍候');
      if (lines === null && (direction === 'next' ? !current.canGoNext : !current.canGoPrevious)) return current;
      moving = true; userDriven = true; resizedPassage = appearanceOrigin = null;
      annotations.dismiss(true);
      const owner = rendition;
      try {
        if (scrolling()) {
          const manager = rendition.manager;
          const container = manager.container;
          if (lines === null) stopFineScroll();
          else if (!fineScroll || fineScroll.container !== container) {
            stopFineScroll();
            const owner = rendition;
            fineScroll = new BookSlideScroll(container, () => {
              if (rendition === owner && !opening) notify(owner.currentLocation());
            });
          }
          const step = lines === null ? Math.max(40,container.clientHeight * 0.8) : Math.max(12,appearance.fontSize * appearance.lineHeight) * lines;
          const distance = step * (direction === 'next' ? 1 : -1);
          const target = fineScroll ? fineScroll.destination(distance) : container.scrollTop+distance;
          // Already laid out content can move immediately. Only a chapter edge
          // needs a fill before moving; scroll events maintain the lookahead.
          if (target <= 0 || target >= container.scrollHeight-container.clientHeight) await manager.fill();
          // Continuous EPUB views can have a height-only placeholder for the
          // next chapter. Prepare it before scrolling into it, even when the
          // container already reports enough scroll range.
          const bounds = container.getBoundingClientRect();
          const travel = fineScroll ? fineScroll.destination(distance)-container.scrollTop : distance;
          const futureTop = bounds.top + travel, futureBottom = futureTop + container.clientHeight;
          if (manager.views.all().some(view => {
            const rect = view.element.getBoundingClientRect();
            return !view.displayed && rect.bottom > futureTop && rect.top < futureBottom;
          })) await manager.update(Math.abs(travel));
          // Crown input follows the next display frame without a settling tail.
          // Stream acknowledgements do not wait for that frame.
          if (lines === null) await scrollViewport(container,distance,180);
          else if (fineScroll) await fineScroll.move(distance,acceptInput);
        } else {
          await (direction === 'next' ? rendition.next() : rendition.prev());
        }
        // currentLocation maps the actual viewport synchronously. Waiting extra
        // animation frames here delays the watch acknowledgement after motion ends.
        if (rendition !== owner) throw Error('阅读内容已改变');
        notify(rendition.currentLocation());
        return current;
      } finally { moving = false; }
    },
    async restoreReadingPosition(href, viewport = null) {
      if (handwritingActive) throw Error('正在书写，请先完成批注');
      await readyToNavigate();
      if (moving || opening) throw Error('正在排版，请稍候');
      userDriven = false;
      if (viewport?.locator?.startsWith('epubcfi(') && (viewport.locator === href || viewport.positionLocator === href)) {
        const point = anchorPoint(viewport.locator), sameLayout = viewport.layoutKey === layoutKey();
        // Layout already preserved the passage in the common case. Replaying
        // display() here needlessly jumps to a paragraph boundary and back.
        if (sameLayout && point && viewport.point && Math.abs(point.x-viewport.point.x)<=1 && Math.abs(point.y-viewport.point.y)<=1) {
          resizedPassage = viewport;
          notify(rendition.currentLocation());
          return current;
        }
        return await restoreViewport(rendition,viewport,sameLayout || viewport.mode === appearance.mode);
      }
      return await display(href);
    },
    async go(href, viewport = null) {
      if (handwritingActive) throw Error('正在书写，请先完成批注');
      await readyToNavigate();
      if (moving || opening) throw Error('正在排版，请稍候');
      if (viewport?.locator?.startsWith('epubcfi(') && (viewport.locator === href || viewport.positionLocator === href)) {
        resizedPassage = null;
        await restoreViewport(rendition,viewport,viewport.layoutKey === layoutKey());
        userDriven = true; notify(rendition.currentLocation());
        return current;
      }
      userDriven = true;
      return await display(href);
    },
    async restore(record) {
      if (handwritingActive) throw Error('正在书写，请先完成批注');
      await readyToNavigate();
      userDriven = false;
      if (record.cfi) { try { return await display(record.cfi); } catch { /* Recover using the portable text anchor. */ } }
      const href = decodeURIComponent(record.anchor.href);
      const section = book.spine.spineItems.find(s => decodeURIComponent(s.href) === href);
      if (!section) throw Error('找不到同步的章节，请确认书籍版本一致');
      await display(section.href);
      const contents = rendition.getContents().find(c => c.sectionIndex === section.index);
      if (!contents) throw Error('同步章节尚未排版');
      const range = BookSlideProgress.range(contents.document,record.anchor);
      if (range) return await display(contents.cfiFromRange(range));
      return current;
    },
    appearance(settings) {
      if (!active) { deferredAppearance = settings; return Promise.resolve(current); }
      const request = ++appearanceRequest, owner = rendition;
      const work = layoutQueue.catch(()=>{}).then(async () => {
        if (request !== appearanceRequest || owner !== rendition) return current;
        await settledLayout();
        if (request !== appearanceRequest || owner !== rendition) return current;
        if (!active) { deferredAppearance = settings; return current; }
        stopFineScroll(); userDriven = false;
        if (!rendition || !current) { style(settings); return current; }
        const geometryChanged = layoutKey(settings) !== layoutKey();
        if (!geometryChanged) {
          // Theme and UI changes must not navigate the book at all.
          style(settings);
          notify(owner.currentLocation());
          return current;
        }
        // A paginated view cannot keep a scrolling character at the same
        // vertical pixel. Retain that original point until reading resumes,
        // so switching back does not adopt the temporary column's offset.
        const anchor = appearanceOrigin || viewportAnchor || captureViewport();
        const changedMode = (settings.mode !== 'paged') !== scrolling();
        appearanceOrigin ||= anchor;
        resizeAnchor = anchor; // Suppress events before the first CSS mutation.
        style(settings);
        if (changedMode) rendition.flow(scrolling() ? 'scrolled' : 'paginated');
        rendition.settings.gap = settings.margin;
        rendition.manager.settings.gap = settings.margin;
        // Rebuild spread documents for geometry changes, as a navigator reloads
        // spreads at its pending locator. Reusing WebKit's existing columns can
        // retain stale line fragmentation/indentation after changing the gap.
        rendition.clear();
        rendition.manager.updateLayout();
        rendition.resize(canvasSize().width,canvasSize().height);
        await restoreViewport(owner,anchor);
        await settledLayout();
        return current;
      });
      layoutQueue = work;
      return work;
    },
    async search(query) {
      if (!book || !query.trim()) return [];
      const mine = revision, search = ++searchRevision, results = [];
      for (const section of book.spine.spineItems) {
        if (mine !== revision || search !== searchRevision || results.length >= 80) break;
        await section.load(book.load.bind(book));
        const matches = section.find(query);
        for (const item of matches) {
          results.push({id:item.cfi, href:item.cfi, title:item.excerpt, depth:0});
          if (results.length >= 80) break;
        }
        // Do not unload the currently displayed section.
        if (!rendition.manager.views.all().some(view => view.section.index === section.index)) section.unload();
      }
      return results;
    }
  };
  post('ready',true);
})();
