// WebHID capture for Keychron Launcher — paste into Chrome DevTools console on launcher.keychron.com
//
// It wraps every WebHID call the page makes (sendReport, sendFeatureReport, receiveFeatureReport)
// and logs incoming input reports, so we can see the exact bytes Launcher asks for and what the
// keyboard/dongle answers.
//
// 1. Open https://launcher.keychron.com in Chrome with the keyboard on its 2.4 GHz dongle.
// 2. Open DevTools (⌥⌘I) → Console. If Chrome refuses a paste, type: allow pasting
// 3. Paste this whole file, press return.
// 4. In Launcher, open whatever shows the battery. Watch the console.
// 5. Copy the [HID] lines here, and say what percentage Launcher displayed.

(() => {
  if (window.__hidCaptureInstalled) {
    console.log('[HID] already installed');
    return;
  }
  window.__hidCaptureInstalled = true;

  const hex = (data) => {
    const bytes = data instanceof DataView
      ? new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
      : new Uint8Array(data || []);
    return Array.from(bytes).map((b) => b.toString(16).padStart(2, '0')).join(' ');
  };
  const tag = (dev) => dev.productName || dev.productId || 'device';
  const log = (dir, ...rest) => console.log('%c[HID]', 'color:#0aa;font-weight:bold', dir, ...rest);

  const patch = (name, render) => {
    const original = HIDDevice.prototype[name];
    if (!original || original.__wrapped) return;
    HIDDevice.prototype[name] = function (...args) {
      try { log('→ ' + name, render(this, args)); } catch (e) { log('→ ' + name, e.message); }
      return original.apply(this, args);
    };
    HIDDevice.prototype[name].__wrapped = true;
  };

  patch('sendReport', (dev, [reportId, data]) =>
    `${tag(dev)} reportId=0x${reportId.toString(16)} ${hex(data)}`);
  patch('sendFeatureReport', (dev, [reportId, data]) =>
    `${tag(dev)} reportId=0x${reportId.toString(16)} ${hex(data)}`);
  patch('receiveFeatureReport', (dev, [reportId]) =>
    `${tag(dev)} reportId=0x${reportId.toString(16)}`);

  const watch = (dev) => {
    if (!dev || dev.__watched) return;
    dev.__watched = true;
    dev.addEventListener('inputreport', (event) => {
      log('← inputreport', `${tag(dev)} reportId=0x${event.reportId.toString(16)} ${hex(event.data)}`);
    });
    log('watching', tag(dev));
  };

  const originalOpen = HIDDevice.prototype.open;
  HIDDevice.prototype.open = function () {
    watch(this);
    return originalOpen.apply(this, arguments);
  };

  if (navigator.hid) {
    navigator.hid.getDevices().then((devices) => devices.forEach(watch));
    navigator.hid.addEventListener('connect', (e) => watch(e.device));
  }

  log('installed — now open the battery display in Launcher');
})();
