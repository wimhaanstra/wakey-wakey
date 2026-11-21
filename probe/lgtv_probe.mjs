#!/usr/bin/env node
// Probe an LG webOS TV over the local WebSocket API.
//
//   node probe/lgtv_probe.mjs --ip 10.210.15.90            # info dump (pairs on first run)
//   NODE_TLS_REJECT_UNAUTHORIZED=0 is required: the TV uses a self-signed LG certificate
//   and only wss://<ip>:3001 is accepted (port 3000 resets on webOS 24).
//   node probe/lgtv_probe.mjs --ip 10.210.15.90 --pair     # force the pairing prompt
//   node probe/lgtv_probe.mjs --ip 10.210.15.90 --request ssap://audio/setVolume '{"volume":10}'
//
// The client key is cached in .cache/lgtv-client-key.json (chmod 600) so later runs do not
// re-prompt. This file is a harness for protocol discovery only; the app speaks the same
// protocol from Swift (URLSessionWebSocketTask).

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const args = process.argv.slice(2);
const opt = (name, fallback = null) => {
  const i = args.indexOf(`--${name}`);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : fallback;
};
const ip = opt('ip', '10.210.15.90');
const port = opt('port', '3001');
const scheme = args.includes('--plain') ? 'ws' : 'wss';
const forcePair = args.includes('--pair');
const requestUri = opt('request');
const lunaUri = opt('luna');
const requestPayload = opt('payload', '{}');
const timeoutMs = Number(opt('timeout', '120000'));

const cacheDir = path.resolve('.cache');
const keyFile = path.join(cacheDir, 'lgtv-client-key.json');
fs.mkdirSync(cacheDir, { recursive: true });

let cachedKey = null;
if (fs.existsSync(keyFile) && !forcePair) {
  try { cachedKey = JSON.parse(fs.readFileSync(keyFile, 'utf8')).key; } catch {}
}

const ws = new WebSocket(`${scheme}://${ip}:${port}`);
let nextId = 1;
const pending = new Map();
let registered = false;

const send = (type, payload, id = nextId++) => {
  const msg = { id, type, payload };
  ws.send(JSON.stringify(msg));
  return id;
};

const request = (uri, payload = {}) => new Promise((resolve, reject) => {
  const id = nextId++;
  pending.set(id, { resolve, reject, uri });
  ws.send(JSON.stringify({ id, type: 'request', uri, payload }));
});

const finish = (code = 0) => {
  try { ws.close(); } catch {}
  setTimeout(() => process.exit(code), 100);
};

ws.addEventListener('open', () => {
  console.log(`connected ${scheme}://${ip}:${port}`);
  const permissions = [
    'LAUNCH', 'LAUNCH_WEBAPP', 'APP_TO_APP', 'CLOSE', 'TEST_OPEN', 'TEST_PROTECTED',
    'CONTROL_AUDIO', 'CONTROL_DISPLAY', 'CONTROL_INPUT_JOYSTICK',
    'CONTROL_INPUT_MEDIA_RECORDING', 'CONTROL_INPUT_MEDIA_PLAYBACK', 'CONTROL_INPUT_TV',
    'CONTROL_POWER', 'READ_APP_STATUS', 'READ_CURRENT_CHANNEL', 'READ_INPUT_DEVICE_LIST',
    'READ_NETWORK_STATE', 'READ_RUNNING_APPS', 'READ_TV_CHANNEL_LIST',
    'WRITE_NOTIFICATION_TOAST', 'READ_POWER_STATE', 'READ_COUNTRY_INFO', 'READ_SETTINGS',
    'CONTROL_TV_SCREEN', 'CONTROL_TV_STANBY', 'CONTROL_FAVORITE_GROUP', 'CONTROL_USER_INFO',
    'CHECK_BLUETOOTH_DEVICE', 'CONTROL_BLUETOOTH', 'CONTROL_TIMER_INFO',
    'STB_INTERNAL_CONNECTION', 'CONTROL_RECORDING', 'READ_RECORDING_STATE',
    'WRITE_RECORDING_LIST', 'READ_RECORDING_LIST', 'READ_RECORDING_SCHEDULE',
    'WRITE_RECORDING_SCHEDULE', 'READ_STORAGE_DEVICE_LIST', 'READ_TV_PROGRAM_INFO',
    'READ_TV_CURRENT_TIME', 'READ_TV_CONTENT_STATE', 'READ_UPDATE_INFO',
    'CONTROL_INPUT_TEXT', 'CONTROL_MOUSE_AND_KEYBOARD', 'WRITE_SETTINGS',
  ];
  const payload = {
    forcePairing: false,
    pairingType: 'PROMPT',
    'client-key': cachedKey || undefined,
    manifest: {
      manifestVersion: 1,
      appVersion: '1.0',
      signed: {
        created: '20261119',
        appId: 'com.sortedbits.wakey',
        vendorId: 'com.sortedbits',
        localizedAppNames: { '': 'Wakey' },
        localizedVendorNames: { '': 'Sorted Bits' },
        permissions,
      },
      permissions,
    },
  };
  if (!cachedKey) delete payload['client-key'];
  send('register', payload, 'reg');
  if (!cachedKey) console.log('PAIRING: a prompt should now be visible on the TV — accept it.');
});

ws.addEventListener('message', async (event) => {
  let msg;
  try { msg = JSON.parse(event.data); } catch { return; }
  if (msg.type === 'registered') {
    registered = true;
    const key = msg.payload['client-key'];
    console.log('registered; client-key', key ? `${key.slice(0, 8)}…` : '(none)');
    if (key && key !== cachedKey) {
      fs.writeFileSync(keyFile, JSON.stringify({ ip, key }, null, 2), { mode: 0o600 });
      console.log('saved key to', keyFile);
    }
    await runInfoDump();
    finish(0);
  } else if (msg.type === 'error') {
    console.log('ERROR', JSON.stringify(msg));
    const p = pending.get(msg.id);
    if (p) { pending.delete(msg.id); p.reject(new Error(JSON.stringify(msg))); }
  } else if (msg.type === 'response') {
    const p = pending.get(msg.id);
    if (p) {
      pending.delete(msg.id);
      p.resolve(msg.payload);
      console.log(`\n### ${p.uri}\n${JSON.stringify(msg.payload, null, 2)}`);
    }
  } else {
    console.log('EVENT', JSON.stringify(msg));
  }
});

ws.addEventListener('error', (e) => {
  console.error('websocket error', e.message || e);
  finish(1);
});

ws.addEventListener('close', () => {
  if (!registered) {
    console.error('closed before registration');
    process.exit(1);
  }
});

async function lunaRequest(uri, params) {
  // webOS 24 rejects ssap://settings/setSystemSettings with 401. The documented workaround
  // is an on-screen alert whose onclose/onfail handlers point at the internal luna URI;
  // closing the alert ourselves fires the luna call.
  const target = `luna://${uri}`;
  const alert = await request('ssap://system.notifications/createAlert', {
    message: ' ',
    buttons: [{ label: '', onClick: target, params }],
    onclose: { uri: target, params },
    onfail: { uri: target, params },
  });
  console.log('alert', JSON.stringify(alert));
  const closed = await request('ssap://system.notifications/closeAlert', { alertId: alert.alertId });
  console.log('closed', JSON.stringify(closed));
}

async function runInfoDump() {
  const queries = [
    ['ssap://system/getSystemInfo'],
    ['ssap://com.webos.service.update/getCurrentSWInformation'],
    ['ssap://audio/getVolume'],
    ['ssap://audio/getMute'],
    ['ssap://tv/getExternalInputList'],
    ['ssap://com.webos.applicationManager/getForegroundAppInfo'],
    ['ssap://com.webos.service.tvpower/power/getPowerState'],
    ['ssap://com.webos.settingsservice/getSystemSettings', { category: 'picture', keys: ['backlight', 'brightness', 'contrast', 'color', 'oledLight'] }],
    ['ssap://com.webos.service.settings/getSystemSettings', { category: 'picture', keys: ['backlight', 'brightness', 'contrast', 'color', 'oledLight'] }],
  ];
  if (lunaUri) {
    let payload = {};
    try { payload = JSON.parse(requestPayload); } catch (e) { console.error('bad --payload JSON:', e.message); }
    queries.length = 0;
    await lunaRequest(lunaUri, payload);
    return;
  }
  if (requestUri) {
    let payload = {};
    try { payload = JSON.parse(requestPayload); } catch (e) { console.error('bad --payload JSON:', e.message); }
    queries.length = 0;
    queries.push([requestUri, payload]);
  }
  for (const [uri, payload] of queries) {
    try {
      await Promise.race([
        request(uri, payload),
        new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), 8000)),
      ]);
    } catch (e) {
      console.log(`\n### ${uri}\nFAILED: ${e.message}`);
    }
  }
}

setTimeout(() => {
  console.error(`timed out after ${timeoutMs} ms (registered=${registered})`);
  finish(1);
}, timeoutMs).unref();
