from fastapi import APIRouter
from fastapi.responses import HTMLResponse

router = APIRouter()

PAGE = r"""<!doctype html>
<html><head><meta charset="utf-8"><title>Mock AI Platform</title>
<style>
body{font-family:system-ui;max-width:800px;margin:30px auto}.banner{padding:12px;background:#fee;display:none}
#response{white-space:pre-wrap;border:1px solid #ccc;padding:12px;min-height:80px}
textarea{width:100%;height:80px}.hidden{display:none}
</style></head>
<body>
<h1>Mock AI Platform</h1>
<div id="login-expired" class="banner" data-testid="login-expired">LOGIN_EXPIRED</div>
<div id="captcha" class="banner" data-testid="captcha">CAPTCHA</div>
<div id="security" class="banner" data-testid="security-challenge">SECURITY_CHALLENGE</div>
<div id="rate-limit" class="banner" data-testid="rate-limit">RATE_LIMITED</div>
<div id="restricted" class="banner" data-testid="account-restricted">ACCOUNT_RESTRICTED</div>
<div id="chat" data-testid="chat">
 <div id="queries" data-testid="queries"></div>
 <div id="response" data-testid="response" data-final="false"></div>
 <button id="stop" data-testid="stop" class="hidden">Stop</button>
 <textarea id="prompt" data-testid="prompt"></textarea>
 <button id="send" data-testid="send">Send</button>
 <button id="delete" data-testid="delete-chat">Delete chat</button>
</div>
<script>
const params=new URLSearchParams(location.search),mode=params.get('mode')||'normal';
const key='geo-mock-'+mode,load=()=>{try{return JSON.parse(localStorage.getItem(key)||'{}')}catch(e){return {}}};
let state=load(),timer=null;
const save=()=>localStorage.setItem(key,JSON.stringify(state));
const show=id=>document.getElementById(id).style.display='block';
if(mode==='login_expired')show('login-expired');if(mode==='captcha')show('captcha');
if(mode==='security')show('security');if(mode==='rate_limit')show('rate-limit');
if(mode==='restricted')show('restricted');
const prompt=document.getElementById('prompt'),send=document.getElementById('send');
const stop=document.getElementById('stop'),response=document.getElementById('response');
const queries=document.getElementById('queries'),chat=document.getElementById('chat');
function render(){
 queries.textContent='';
 (state.queries||[]).forEach(value=>{const n=document.createElement('div');n.dataset.testid='user-query';n.textContent=value;queries.appendChild(n)});
 response.textContent=state.response||'';response.dataset.final=state.final?'true':'false';
 if(state.deleted)chat.dataset.deleted='true';else delete chat.dataset.deleted;
 const active=!!state.streaming;stop.classList.toggle('hidden',!active);
 prompt.disabled=active;send.disabled=active;
}
function tick(){
 if(!state.streaming)return;
 if(state.index>=state.answer.length){
   if(mode==='never'){save();return}
   clearInterval(timer);timer=null;state.streaming=false;state.final=true;save();render();return;
 }
 state.response+=state.answer[state.index++];
 if(mode==='pause'&&state.index===12&&!state.pauseApplied){
   state.pauseApplied=true;save();render();clearInterval(timer);timer=null;
   setTimeout(()=>{timer=setInterval(tick,40)},1200);return;
 }
 if(mode==='page_refresh'&&state.index===15&&!state.refreshed){
   state.refreshed=true;save();location.reload();return;
 }
 save();render();
}
function start(){
 const interval=mode==='slow'?180:(mode==='long'?2:40);
 timer=setInterval(tick,interval);
}
function streamAnswer(question){
 let answer='Mock answer for: '+question+'。这是用于验证状态机、实时保存和断点恢复的流式回答。';
 if(mode==='long')answer=answer.repeat(20);
 state={queries:(state.queries||[]).concat([question]),response:'',answer:answer,index:0,
        streaming:true,final:false,deleted:false,sendCount:(state.sendCount||0)+1,
        refreshed:false,pauseApplied:false};
 save();render();start();
}
send.onclick=()=>{if(!prompt.value||send.disabled)return;const value=prompt.value;prompt.value='';streamAnswer(value)};
document.getElementById('delete').onclick=()=>{
 if(mode==='delete_fail')return;
 if(timer)clearInterval(timer);timer=null;
 state={queries:[],response:'',answer:'',index:0,streaming:false,final:false,
        deleted:true,sendCount:state.sendCount||0};save();render();
};
render();
if(mode==='dom_change')response.removeAttribute('data-testid');
if(state.streaming)setTimeout(start,10);
window.mockState=()=>load();
</script></body></html>"""


@router.get("/mock-ai", response_class=HTMLResponse)
def mock_ai() -> HTMLResponse:
    return HTMLResponse(PAGE)
