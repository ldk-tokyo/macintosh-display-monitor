'use strict';
(() => {
  const $ = selector => document.querySelector(selector);
  const keys = ['cpu', 'gpu', 'memory'];
  const dials = [...document.querySelectorAll('.dial')];
  const svgNS = 'http://www.w3.org/2000/svg';
  const coordinates = (value, radius) => {
    const angle = Math.PI * (1 - value / 100);
    return [120 + radius * Math.cos(angle), 115 - radius * Math.sin(angle)].join(' ');
  };
  const arc = (value, r) => 'M' + coordinates(0, r) + ' A' + r + ' ' + r + ' 0 0 1 ' + coordinates(value, r);
  function draw(svg, tag, attributes) {
    const node = document.createElementNS(svgNS, tag);
    Object.entries(attributes).forEach(([k, v]) => node.setAttribute(k, v));
    svg.append(node);
    return node;
  }
  const needles = dials.map(dial => {
    const svg = dial.querySelector('svg');
    draw(svg, 'path', {d:arc(100,98),stroke:'var(--track)','stroke-width':7,fill:'none'});
    const progress = draw(svg, 'path', {stroke:'var(--arc)','stroke-width':7,fill:'none'});
    for (let i=0;i<=100;i+=2) {
      draw(svg,'path',{d:'M'+coordinates(i,91)+' L'+coordinates(i,i%10===0?81:86),stroke:'var(--ink)','stroke-width':i%10===0?1.8:.9});
    }
    for (const n of [0,50,100]) {
      const [x,y] = coordinates(n,69).split(' ').map(Number);
      draw(svg,'text',{x,y:y+4,'text-anchor':'middle','font-size':17,fill:'var(--mark)'}).textContent=n;
    }
    const hand = draw(svg,'path',{stroke:'var(--needle)','stroke-width':3.5});
    draw(svg,'circle',{cx:120,cy:115,r:7,fill:'var(--ink)'});
    draw(svg,'circle',{cx:120,cy:115,r:2,fill:'var(--paper)'});
    return [progress,hand];
  });
  const clock = new Intl.DateTimeFormat('zh-CN',{hour:'2-digit',minute:'2-digit',hourCycle:'h23'});
  const dateLabel = new Intl.DateTimeFormat('zh-CN',{month:'2-digit',day:'2-digit'});
  const headerDate = new Intl.DateTimeFormat('zh-CN',{month:'long',day:'numeric',weekday:'short'});
  const glue = (tag, text, cls) => {
    const el = document.createElement(tag);
    if (text != null) el.textContent = text;
    if (cls) el.className = cls;
    return el;
  };
  function appendRow(body,row,now,next) {
    const tr = body.insertRow();
    const date = row.reset ? new Date(row.reset*1000) : null;
    tr.className = next ? 'soon' : '';
    tr.insertCell().textContent = date ? (date.toDateString()===now.toDateString()?'今天':dateLabel.format(date)) : '—';
    if(next) tr.cells[0].append(glue('span',date-now<=7200000?'即将重置':'下次重置','next'));
    const time = tr.insertCell(), flip=glue('span',null,'flip');
    if(date) {
      const str=clock.format(date);
      for(const ch of str) flip.append(glue('span',ch,ch===':'?'colon':'flap'));
      time.append(flip);
    } else time.textContent='—';
    tr.insertCell().textContent=row.provider;
    tr.cells[2].className='service';
    tr.insertCell().textContent=row.window;
    const balance=glue('div',null,'balance'), meter=glue('div',null,'meter'), fill=glue('i');
    fill.style.width=row.remaining+'%';meter.append(fill);balance.append(meter,glue('strong',Math.round(row.remaining)+'%'));
    tr.insertCell().append(balance);
  }
  function statusRow(body,provider,message) {
    const tr=body.insertRow();
    tr.className='unavailable';
    const name=tr.insertCell();name.colSpan=2;name.textContent=provider;
    const cell=tr.insertCell();cell.colSpan=3;cell.textContent=message;
  }
  let previousLedger='', visiblePage=-1, pages=[];
  function paginate(entries, now, fit) {
    const body=$('tbody');
    body.replaceChildren();
    for (const item of entries) {
      if (item.note) statusRow(body,...item.note);
      else appendRow(body,item.row,now,item.next);
    }
    const capacity=$('.ledger-space').getBoundingClientRect().height-$('thead').getBoundingClientRect().height-2*fit;
    const groups=[[]];
    let used=0;
    for (const row of body.rows) {
      const height=row.getBoundingClientRect().height;
      if (used+height>capacity && groups[groups.length-1].length) {
        groups.push([]);
        used=0;
      }
      groups[groups.length-1].push(row);
      used+=height;
    }
    return groups;
  }
  let latestState;
  function render(s) {
    latestState=s;
    const now=new Date(), modules=new Set(s.modules);
    const root=document.documentElement;
    const width=s.canvas?.width ?? innerWidth, height=s.canvas?.height ?? innerHeight;
    if (!width || !height || !innerWidth || !innerHeight) return;
    const fit=Math.min(innerWidth/width,innerHeight/height);
    root.style.setProperty('--canvas-w',width+'px');
    root.style.setProperty('--canvas-h',height+'px');
    root.style.setProperty('--fit',fit);
    root.dataset.mode=s.dark?'dark':'classic';
    const extent=100-2*(s.margin??0);
    root.style.setProperty('--safe-extent',extent+'%');
    root.style.setProperty('--type',(s.textSize??125)/100);
    $('.clock').textContent=clock.format(now);
    $('.context span').textContent=headerDate.format(now);
    $('.time-zone').textContent=Intl.DateTimeFormat().resolvedOptions().timeZone;
    keys.forEach((key,i)=>{
      const value=s.metrics[key],valid=Number.isFinite(value);
      dials[i].hidden=!modules.has(key);
      dials[i].querySelector('.number').firstChild.nodeValue=valid?Math.round(value):'—';
      const [ring,hand]=needles[i];
      ring.setAttribute('d',valid?arc(value,98):'');
      hand.setAttribute('d',valid?'M120 115 L'+coordinates(value,85):'');
    });
    $('.faces').hidden=!keys.some(k=>modules.has(k));
    $('.instrument').hidden=$('.faces').hidden&&!modules.has('network');
    dials[2].querySelector('small').textContent=Number.isFinite(s.metrics.usedGB)?s.metrics.usedGB.toFixed(1)+' / '+Math.round(s.metrics.totalGB)+' GB':'—';
    $('.network').hidden=!modules.has('network');
    [...document.querySelectorAll('.network b')].forEach((node,i)=>{
      const v=s.metrics[i?'upload':'download'];node.textContent=Number.isFinite(v)?v.toFixed(1)+' MB/s':'—';
    });
    const sources=s.sources.filter(p=>modules.has(p.provider));
    $('.board').hidden=!sources.length;
    const ordered=[],notes=[];
    for(const p of sources) {
      const valid=p.rows.filter(r=>!r.reset||r.reset*1000>now.getTime());
      ordered.push(...valid);
      if(!valid.length)notes.push([p.provider,p.rows.length?'窗口已结束，等待读取新额度':p.message]);
    }
    ordered.sort((a,b)=>(a.reset??Infinity)-(b.reset??Infinity)||a.provider.localeCompare(b.provider));
    if(!sources.length) { previousLedger='';return; }
    const entries=[...ordered.map((row,i)=>({row,next:i===0&&!!row.reset})),...notes.map(note=>({note}))];
    const sync=sources.filter(x=>x.updated).map(x=>x.provider+' '+clock.format(new Date(x.updated*1000)));
    const label=sync.length?'同步　'+sync.join('　·　'):'等待读取';
    const space=$('.ledger-space');
    const sig=JSON.stringify([entries,label,now.toDateString(),extent,s.textSize,space.clientWidth,space.clientHeight]);
    if(sig!==previousLedger) {
      previousLedger=sig;
      pages=paginate(entries,now,fit);
      visiblePage=-1;
    }
    const page=Math.floor(now.getTime()/12000)%pages.length;
    if(visiblePage!==page) {
      visiblePage=page;
      $('tbody').replaceChildren(...pages[page]);
      $('.board-title span').textContent=pages.length>1?(page+1)+' / '+pages.length+'　·　'+label:label;
    }
  }
  window.addEventListener('resize',()=>{ if (latestState) render(latestState); });
  window.monitor={render};
})();
