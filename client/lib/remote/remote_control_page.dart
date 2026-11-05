/// Served from the same local origin as pairing/control. No third-party assets,
/// tracking, remote fonts or browser polling are used.
const remoteControlHtml = '''<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>映库遥控</title><link rel="stylesheet" href="/style.css"></head>
<body><main><header><h1>映库</h1><span id="status" role="status">正在连接…</span></header>
<section class="pad" aria-label="方向控制">
<button class="up" data-command="up" aria-label="向上">↑</button>
<button class="left" data-command="left" aria-label="向左">←</button>
<button class="ok" data-command="select">确定</button>
<button class="right" data-command="right" aria-label="向右">→</button>
<button class="down" data-command="down" aria-label="向下">↓</button></section>
<div class="row"><button data-command="back">返回</button>
<button data-command="previous">上一项</button><button data-command="next">下一项</button></div>
<div class="row"><button data-command="seekBackward">后退</button>
<button data-command="toggle" id="play">播放 / 暂停</button>
<button data-command="seekForward">前进</button></div>
<div class="row"><button data-command="zoomOut">缩小</button>
<button data-command="zoomIn">放大</button><button data-command="rotate">旋转</button></div>
<section class="typing"><label for="text">输入到当前输入框</label>
<textarea id="text" rows="3" maxlength="4096" placeholder="先在电视上选中输入框"></textarea>
<div class="row"><button id="send">发送文字</button><button id="submit">确认输入</button></div></section>
<p id="feedback" role="status"></p><button id="retry" hidden>重新连接</button>
</main><script src="/app.js" defer></script></body></html>''';

const remoteControlCss = '''
:root{color-scheme:light dark;font-family:system-ui,-apple-system,sans-serif;color:#172133;background:#f2f4f8}
*{box-sizing:border-box}body{margin:0;padding:20px max(16px,env(safe-area-inset-right)) 28px max(16px,env(safe-area-inset-left))}
main{max-width:420px;margin:auto}header{display:flex;align-items:center;justify-content:space-between;margin-bottom:20px}
h1{font-size:22px;margin:0}#status{font-size:14px;color:#5d6a7d}button,textarea{font:inherit;color:inherit}
button{border:0;background:white;border-radius:12px;min-height:54px;padding:12px;touch-action:manipulation}
button:active{background:#d9e7ff}button:disabled{opacity:.42}button:focus-visible,textarea:focus{outline:3px solid #176be8;outline-offset:2px}
.pad{display:grid;grid-template:repeat(3,64px)/repeat(3,1fr);gap:6px;margin-bottom:12px}
.up{grid-area:1/2}.left{grid-area:2/1}.ok{grid-area:2/2;background:#176be8;color:white}.right{grid-area:2/3}.down{grid-area:3/2}
.row{display:flex;gap:6px;margin:6px 0}.row button{flex:1}.typing{margin-top:24px}label{display:block;font-size:14px;margin-bottom:8px}
textarea{width:100%;resize:vertical;border:1px solid #cbd3df;border-radius:10px;padding:12px;background:white}
#feedback{min-height:24px;color:#5d6a7d;font-size:14px}#retry{width:100%}
@media(prefers-color-scheme:dark){:root{background:#111822;color:#edf2f9}button,textarea{background:#253043}#status,#feedback{color:#b1bfd1}button:active{background:#344b6a}.ok{background:#176be8}}
''';

const remoteControlJs = r'''
(() => {
  'use strict';
  const status=document.getElementById('status'), feedback=document.getElementById('feedback');
  const text=document.getElementById('text'), send=document.getElementById('send');
  const submit=document.getElementById('submit'), retry=document.getElementById('retry');
  let socket=null, sequence=0, editing=false, editSession=0, attempts=0, reconnect=null;
  const pending=new Set();
  const token=location.hash.slice(1); history.replaceState(null,'',location.pathname);
  function controls(connected){document.querySelectorAll('[data-command]').forEach(b=>b.disabled=!connected);
    send.disabled=!connected||!editing;submit.disabled=send.disabled;}
  function command(action,extra={}){
    if(!socket||socket.readyState!==WebSocket.OPEN||pending.size>=8)return;
    const id=++sequence;pending.add(id);socket.send(JSON.stringify({id,action,...extra}));
  }
  document.querySelectorAll('[data-command]').forEach(b=>b.addEventListener('click',()=>command(b.dataset.command)));
  send.addEventListener('click',()=>{if(!text.matches(':disabled'))command('text',{text:text.value,editSession});});
  submit.addEventListener('click',()=>command('submit',{editSession}));
  retry.addEventListener('click',()=>{attempts=0;connect();});
  function connect(){
    clearTimeout(reconnect);retry.hidden=true;controls(false);status.textContent='正在连接…';
    const current=socket=new WebSocket((location.protocol==='https:'?'wss:':'ws:')+'//'+location.host+'/control');
    current.onopen=()=>{if(socket!==current)return;attempts=0;status.textContent='已连接';controls(true);};
    current.onmessage=event=>{
      if(socket!==current)return;
      let value;try{value=JSON.parse(event.data);}catch(_){return;}
      if(value.type==='status'){
        editing=value.editing===true;editSession=value.editSession||0;
        status.textContent=value.playing?'正在播放':'已连接';
        document.getElementById('play').textContent=value.playing?'暂停':'播放';
        text.placeholder=editing?'在手机输入文字后发送':'先在电视上选中输入框';controls(true);
      }else if(value.type==='result'){
        pending.delete(value.id);feedback.textContent=value.ok?'':(value.message||'当前操作不可用');
      }
    };
    current.onclose=()=>{
      if(socket!==current)return;pending.clear();controls(false);status.textContent='连接已断开';
      if(!document.hidden&&attempts<3){const delay=800*Math.pow(2,attempts++);reconnect=setTimeout(connect,delay);}
      else retry.hidden=false;
    };
    current.onerror=()=>{};
  }
  document.addEventListener('visibilitychange',()=>{
    if(document.hidden){clearTimeout(reconnect);reconnect=null;}
    else if(!socket||socket.readyState===WebSocket.CLOSED){attempts=0;connect();}
  });
  window.addEventListener('pagehide',()=>{clearTimeout(reconnect);const old=socket;socket=null;old?.close();});
  controls(false);
  (async()=>{
    if(token){try{
      const controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),5000);
      let response;try{response=await fetch('/pair',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({token}),signal:controller.signal});}finally{clearTimeout(timeout);}
      if(!response.ok)throw new Error();
    }catch(_){status.textContent='配对已过期';feedback.textContent='请在电视重新打开二维码';return;}}
    connect();
  })();
})();
''';
