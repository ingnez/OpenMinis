// 云电脑画面页 window.om 的真浏览器端到端测试（Node 22+，无第三方依赖）。
// 被控端：Xvfb + x11vnc + websockify，桌面上开一个带输入框的假页面（Chrome --remote-debugging-port=TARGET_CDP）。
// 观看端：headless Chrome 打开 render_novnc_page.py 渲染的 App 画面页（VIEWER_CDP），通过 window.om 操作远端。
// 用法：node scripts/desktop_bridge_e2e.mjs <viewerCDP端口> <画面页URL> <被控端CDP端口> <DISPLAY>
import { execFileSync } from 'node:child_process';

const [viewerPort, pageURL, targetPort, display] = process.argv.slice(2);
const sleep = ms => new Promise(r => setTimeout(r, ms));
let failed = 0;
const check = (ok, msg) => { console.log((ok ? 'ok   ' : 'FAIL ') + msg); if (!ok) failed++; };

async function cdp(port, match) {
  for (let i = 0; i < 150; i++) {
    try {
      const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
      const t = list.find(p => p.type === 'page' && match(p));
      if (t) {
        const ws = new WebSocket(t.webSocketDebuggerUrl);
        await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; });
        let id = 0; const waits = new Map();
        ws.onmessage = e => { const m = JSON.parse(e.data); if (m.id && waits.has(m.id)) { waits.get(m.id)(m); waits.delete(m.id); } };
        const call = (method, params = {}) => new Promise(r => { const i = ++id; waits.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
        const ev = async expr => { const r = await call('Runtime.evaluate', { expression: expr, returnByValue: true, awaitPromise: true }); return r.result && r.result.result ? r.result.result.value : undefined; };
        return { call, ev, close: () => ws.close() };
      }
    } catch (e) {}
    await sleep(200);
  }
  throw new Error('no CDP page on ' + port);
}

const mouse = () => execFileSync('xdotool', ['getmouselocation'], { env: { ...process.env, DISPLAY: display } }).toString();
const until = async (fn, ms = 8000) => { const end = Date.now() + ms; while (Date.now() < end) { if (await fn()) return true; await sleep(100); } return false; };

const viewer = await cdp(viewerPort, () => true);
await viewer.call('Page.navigate', { url: pageURL });
const target = await cdp(targetPort, p => p.url.includes('input.html'));
await target.ev("document.getElementById('t').value='';scrollTo(0,0);document.getElementById('log').textContent=''");

check(await until(() => viewer.ev("(window.__st||[]).includes('connected')"), 15000), '画面页连上 VNC');
await sleep(300);
await viewer.ev('om.fb()');
const fb = await viewer.ev("(__msgs.filter(m=>m.type==='fb').pop()||{})");
check(fb.w === 1280 && fb.h === 800 && fb.cw > 0, `报告远端尺寸 ${fb.w}x${fb.h}`);

await viewer.ev('om.ptr(321,234,0)');
check(await until(() => /x:321 y:234/.test(mouse())), '触控板指针移动到远端 (321,234)：' + mouse().trim());

await viewer.ev('om.ptr(300,130,0);om.ptr(300,130,1);om.ptr(300,130,0)');
check(await until(() => target.ev("/^down 0 \\d+,\\d+/.test(document.getElementById('log').textContent)")), '左键点到远端页面：' + await target.ev("document.getElementById('log').textContent"));
// 没有窗口管理器的 Xvfb 上，Chrome 点击后不一定把焦点给输入框（和 VNC 无关，xdotool 点也一样），这里直接聚焦
await target.ev("document.getElementById('t').focus()");

// App 的 CloudModifiers 在 Shift 下发大写 keysym（Shift + 0x62 在 x11vnc 上仍是小写 b）
await viewer.ev('om.keys([[0x61,1],[0x61,0],[0xffe1,1],[0x42,1],[0x42,0],[0xffe1,0],[0x31,1],[0x31,0]])');
check(await until(() => target.ev("document.getElementById('t').value==='aB1'")), '按键（含 Shift）输入 aB1');

await viewer.ev('om.keys([[0xffe3,1],[0x61,1],[0x61,0],[0xffe3,0],[0xffe3,1],[0x63,1],[0x63,0],[0xffe3,0]])');
// 远端复制 → 画面页 clipboard 事件靠 x11vnc 轮询选区推送，本机实测偶发收不到（3 次里 1 次），所以只记警告不算失败；
// App 另有「取回云电脑剪贴板」走服务器 xclip，稳定。
let gotClip = await until(() => viewer.ev("__msgs.some(m=>m.type==='clipboard'&&m.text==='aB1')"), 5000);
if (!gotClip) {
  await viewer.ev('om.keys([[0xffe3,1],[0x63,1],[0x63,0],[0xffe3,0]])');
  gotClip = await until(() => viewer.ev("__msgs.some(m=>m.type==='clipboard'&&m.text==='aB1')"), 5000);
}
console.log((gotClip ? 'ok   ' : 'warn ') + '远端 Ctrl+A Ctrl+C → 画面页收到剪贴板事件（尽力而为）');

await viewer.ev("om.clip('zz9')");
await sleep(400);
await viewer.ev('om.keys([[0xffe3,1],[0x76,1],[0x76,0],[0xffe3,0]])');
check(await until(() => target.ev("document.getElementById('t').value==='zz9'")), '手机剪贴板 → 远端 Ctrl+V');

await viewer.ev('om.keys([[0xff08,1],[0xff08,0]])');
check(await until(() => target.ev("document.getElementById('t').value==='zz'")), '退格');

await viewer.ev('om.ptr(500,400,0);om.ptr(500,400,4);om.ptr(500,400,0)');
check(await until(() => target.ev("document.getElementById('log').textContent.includes('down 2')")), '双指点 = 右键');

await viewer.ev('om.wheel(500,400,5,0,0)');
check(await until(() => target.ev('scrollY>0')), '双指拖 = 滚轮向下');

await viewer.ev('om.quality(7,4);om.viewOnly(false);om.cursor(true);om.view(2,-100,-50)');
check(await until(() => viewer.ev("document.getElementById('screen').style.transform==='translate3d(-100px, -50px, 0px) scale(2)'"), 3000),
  '缩放平移作用在画面层（下一帧落地）：' + await viewer.ev("document.getElementById('screen').style.transform"));
// App 的点按映射用 om.fb 报的画布矩形（未缩放坐标）：放大平移之后报的必须和放大前一样，不然放大后点偏
await viewer.ev('om.fb()');
const fbZoomed = await viewer.ev("(__msgs.filter(m=>m.type==='fb').pop()||{})");
const near = (a, b) => Math.abs(a - b) < 0.5;
check(near(fbZoomed.x, fb.x) && near(fbZoomed.y, fb.y) && near(fbZoomed.cw, fb.cw) && near(fbZoomed.ch, fb.ch),
  `放大 2 倍后画布矩形不变（${JSON.stringify(fb)} → ${JSON.stringify(fbZoomed)}）`);
await viewer.ev('om.view(1,0,0)');
check(await viewer.ev("__omRFB.qualityLevel===7&&__omRFB.compressionLevel===4"), '画质切换');

await viewer.ev('om.shot()');
check(await until(() => viewer.ev("__msgs.some(m=>m.type==='shot'&&(m.data||'').startsWith('data:image/png')&&m.data.length>10000)")), '截图拿到 PNG');

await viewer.ev('om.rec(true)');
const recStart = await until(() => viewer.ev("__msgs.some(m=>m.type==='rec')"), 3000);
const recMsg = await viewer.ev("(__msgs.filter(m=>m.type==='rec').pop()||{})");
if (recStart && recMsg.started) {
  await viewer.ev('om.ptr(10,10,0)');
  await sleep(1500);
  await viewer.ev('om.rec(false)');
  const recOk = await until(() => viewer.ev("__msgs.some(m=>m.type==='rec'&&(m.data||'').indexOf('data:video')===0&&m.data.length>100)"), 6000);
  let recDetail = '';
  if (!recOk) recDetail = '（' + await viewer.ev("JSON.stringify((__msgs.filter(m=>m.type==='rec')||[]).map(m=>({started:!!m.started,error:m.error||'',mime:m.mime||'',len:(m.data||'').length})))") + '）';
  check(recOk, '录屏拿到视频数据' + recDetail);
} else {
  console.log('skip 录屏：这个浏览器没有 MediaRecorder（' + JSON.stringify(recMsg) + '）');
}

viewer.close(); target.close();
console.log(failed ? `${failed} 项失败` : 'desktop bridge e2e OK');
process.exit(failed ? 1 : 0);
