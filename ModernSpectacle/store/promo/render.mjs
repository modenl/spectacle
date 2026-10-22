// Renders scene.html to promo.mp4: headless Chrome draws each frame with render(t), ffmpeg encodes them.
//   node render.mjs [out.mp4] [--fps 30] [--only 3.2,5.5]   (--only writes PNG stills at those times instead)
// Needs Google Chrome and ffmpeg; no npm packages (Chrome DevTools Protocol over Node's built-in WebSocket).
import { spawn } from 'node:child_process';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const args = process.argv.slice(2);
const option = (name, fallback) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : fallback; };
const out = path.resolve(args.find((a, i) => !a.startsWith('--') && !args[i - 1]?.startsWith('--')) ?? path.join(here, 'promo.mp4'));
const fps = Number(option('--fps', 30));
const only = option('--only', null)?.split(',').map(Number);
const duration = 15;

const profile = await mkdtemp(path.join(tmpdir(), 'promo-chrome-'));
const port = 9300 + Math.floor(Math.random() * 500);
const chrome = spawn('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, '--window-size=1920,1080',
  '--force-device-scale-factor=1', '--hide-scrollbars', '--allow-file-access-from-files', 'about:blank',
], { stdio: 'ignore' });

let target;
for (let i = 0; i < 50 && !target; i++) {
  await new Promise((r) => setTimeout(r, 200));
  try { target = (await (await fetch(`http://127.0.0.1:${port}/json/list`)).json()).find((t) => t.type === 'page'); } catch {}
}
if (!target) throw new Error('Chrome did not start');

const ws = new WebSocket(target.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r, { once: true }));
let nextId = 1;
const pending = new Map();
ws.addEventListener('message', (e) => {
  const msg = JSON.parse(e.data);
  if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
});
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const id = nextId++;
  pending.set(id, (m) => (m.error ? reject(new Error(`${method}: ${m.error.message}`)) : resolve(m.result)));
  ws.send(JSON.stringify({ id, method, params }));
});

await send('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
await send('Page.enable');
await send('Page.navigate', { url: 'file://' + path.join(here, 'scene.html') });
await new Promise((r) => setTimeout(r, 1500)); // fonts and the icon

async function frameAt(t, format) {
  await send('Runtime.evaluate', { expression: `render(${t})` });
  // Two animation frames so backdrop blurs are drawn before the capture.
  await send('Runtime.evaluate', { expression: 'new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))', awaitPromise: true });
  const { data } = await send('Page.captureScreenshot', { format, ...(format === 'jpeg' ? { quality: 95 } : {}) });
  return Buffer.from(data, 'base64');
}

try {
  if (only) {
    for (const t of only) {
      const file = out.replace(/\.mp4$/, '') + `-${t.toFixed(2)}.png`;
      await writeFile(file, await frameAt(t, 'png'));
      console.log(file);
    }
  } else {
    const ffmpeg = spawn('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'image2pipe', '-framerate', String(fps), '-c:v', 'mjpeg', '-i', '-',
      '-c:v', 'libx264', '-preset', 'slow', '-crf', '18', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { stdio: ['pipe', 'inherit', 'inherit'] });
    const total = Math.round(duration * fps);
    for (let f = 0; f < total; f++) {
      const jpg = await frameAt(f / fps, 'jpeg');
      if (!ffmpeg.stdin.write(jpg)) await new Promise((r) => ffmpeg.stdin.once('drain', r));
      if (f % fps === 0) process.stdout.write(`\r${Math.round((f / total) * 100)}%`);
    }
    ffmpeg.stdin.end();
    await new Promise((r, j) => ffmpeg.on('close', (c) => (c === 0 ? r() : j(new Error('ffmpeg failed')))));
    console.log(`\r${out}`);
  }
} finally {
  ws.close();
  const exited = new Promise((r) => chrome.once('exit', r));
  chrome.kill();
  await exited; // Chrome writes to its profile until it has quit
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
}
