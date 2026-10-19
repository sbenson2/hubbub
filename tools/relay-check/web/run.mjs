// Headless Chrome (libwebrtc, the engine under flutter_webrtc) joins the real LiveKit through
// a Hubbub member's tunnel and TURN shim, publishes a fake microphone (real Opus) and, with
// VIDEO=1, a fake camera, and reports what the other participant received.
//
//   1. cargo run -p hubbub-core --features test-util --example relay_check -- relay.json
//   2. npm ci        (once, in this folder)
//   3. node run.mjs relay.json [seconds=12] [chrome.exe]      (POLICY=all|relay, default relay)
//   4. create relay.json.stop to end the example
import puppeteer from 'puppeteer-core';
import fs from 'fs';
const cfg = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const secs = +(process.argv[3] ?? 12);
const browser = process.argv[4] ?? 'C:/Program Files/Google/Chrome/Application/chrome.exe';
const policy = process.env.POLICY ?? 'relay';
const b = await puppeteer.launch({ executablePath: browser, headless: 'new',
  args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--no-sandbox', '--disable-features=LocalNetworkAccessChecks,BlockInsecurePrivateNetworkRequests,PrivateNetworkAccessSendPreflights,LocalNetworkAccessChecksWebSockets', '--allow-running-insecure-content', '--autoplay-policy=no-user-gesture-required'] });
const page = await b.newPage();
page.on('console', m => console.log('[page]', m.text().replace(/access_token=[^&']*/g, 'TOK').slice(0, 300)));
// A blank page on an http origin lets the page open ws://127.0.0.1 without mixed-content blocks.
await page.setRequestInterception(true);
page.on('request', r => r.url().startsWith('http://127.0.0.1:7899') ? r.respond({ status: 200, contentType: 'text/html', body: '<html></html>' }) : r.continue());
await page.goto('http://127.0.0.1:7899/');
await page.addScriptTag({ content: fs.readFileSync('node_modules/livekit-client/dist/livekit-client.umd.js', 'utf8') });
const res = await page.evaluate(async (c, secs, policy, wantVideo) => {
  const L = window.LivekitClient, t0 = performance.now(), ms = () => Math.round(performance.now() - t0);
  const opts = { rtcConfig: { iceServers: [{ urls: c.ice_url, username: c.ice_user, credential: c.ice_pass }], iceTransportPolicy: policy } };
  const sub = new L.Room(); let remote = null, firstAt = null; const vids = [];
  sub.on(L.RoomEvent.TrackSubscribed, t => { if (t.kind === 'video') vids.push(t); else { remote = t; console.log('sub: audio track subscribed at ' + ms() + 'ms'); } });
  await sub.connect(c.url, c.tok_sub, opts); console.log('sub joined ' + ms() + 'ms');
  const pub = new L.Room(); await pub.connect(c.url, c.tok_pub, opts); console.log('pub joined ' + ms() + 'ms');
  if (wantVideo) await pub.localParticipant.setCameraEnabled(true, { resolution: { width: 1920, height: 1080, frameRate: 30 } }, { videoEncoding: { maxBitrate: 6000000, maxFramerate: 30 }, simulcast: false });
  await pub.localParticipant.setMicrophoneEnabled(true); console.log('mic published ' + ms() + 'ms');
  const out = []; let last = 0;
  for (let i = 0; i < secs; i++) {
    await new Promise(r => setTimeout(r, 1000));
    let rx = 0, sent = 0, rtt = 0, vb = 0, vp = 0;
    if (remote) { (await remote.receiver.getStats()).forEach(s => { if (s.type === 'inbound-rtp') rx = s.packetsReceived; }); if (rx > 0 && firstAt === null) firstAt = ms(); }
    const ps = await pub.localParticipant.getTrackPublications()[0]?.track?.sender?.getStats();
    if (ps) ps.forEach(s => { if (s.type === 'outbound-rtp') sent = s.packetsSent; if (s.type === 'remote-inbound-rtp') rtt = s.roundTripTime; });
    for (const v of vids) (await v.receiver.getStats()).forEach(s => { if (s.type === 'inbound-rtp') { vb = s.bytesReceived; vp = s.packetsReceived; } });
    out.push({ sent, rx, delta: rx - last, rtt, vb, vp }); last = rx;
  }
  const kinds = [];
  (await pub.engine.pcManager.publisher.getStats()).forEach(s => { if (s.type === 'local-candidate') kinds.push(s.candidateType + ' ' + s.address + ':' + s.port); });
  return { out, firstAt, kinds };
}, cfg, secs, policy, !!process.env.VIDEO).catch(e => ({ error: String(e) }));
if (res.out) {
  const l = res.out.at(-1);
  console.log(`SUMMARY policy=${policy} audio_sent=${l.sent} audio_received=${l.rx} first_audio_ms=${res.firstAt} media_rtt_s=${l.rtt} video_pkts=${l.vp} video_Mbps_avg=${(l.vb * 8 / res.out.length / 1e6).toFixed(2)}`);
  console.log('local candidates: ' + res.kinds.join(' | '));
} else console.log(JSON.stringify(res));
await b.close();
