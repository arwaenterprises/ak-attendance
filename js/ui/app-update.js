// Dawam Attendance - app update check (loaded on every page)
//
// An installed app (PWA) that stays open keeps running the page it loaded, so a new deploy could go
// unnoticed for days. Every deploy bumps ONE version number (the ?v= on all script tags and
// CACHE_VERSION in sw.js, see tools/bump-version.js). This file compares the version the page is
// running with the one on the server and shows a red dot + a centred popup. It NEVER reloads the page
// by itself: a reload in the middle of a punch or an admin's work would lose their place.
//
// Also registers the service worker (once, for every page).
(function () {
    'use strict';

    var VERSION_RE = /CACHE_VERSION\s*=\s*'dawam-attendance-v(\d+)'/;
    var CHECK_AFTER_OPEN_MS = 4000;
    var CHECK_AFTER_ONLINE_MS = 2000;
    var MIN_GAP_MS = 5 * 60 * 1000;

    var state = { updatePending: null, lastCheck: 0 };
    var els = {};

    function isOnline() { return navigator.onLine !== false; }

    // The version this page is running = the ?v=N on this very script tag.
    function runningVersion() {
        var tag = document.querySelector('script[src*="app-update.js"]');
        var m = tag && tag.getAttribute('src').match(/[?&]v=(\d+)/);
        return m ? Number(m[1]) : 0;
    }

    // The version on the server = CACHE_VERSION inside sw.js. "?check=" keeps the service worker from caching it.
    function fetchServerVersion() {
        return window.fetch('/sw.js?check=' + Date.now(), { cache: 'no-store' }).then(function (res) {
            if (!res.ok) throw new Error('HTTP ' + res.status);
            return res.text();
        }).then(function (text) {
            var m = text.match(VERSION_RE);
            return m ? Number(m[1]) : 0;
        });
    }

    // Another window is open, or the page says it is busy (e.g. a punch in progress): do not pop up on top of it.
    function somethingElseOpen() {
        if (document.querySelector('.modal-overlay.active, .status-overlay.active, .verifying-overlay.active')) return true;
        try { if (window.DawamUpdate && typeof window.DawamUpdate.isBusy === 'function' && window.DawamUpdate.isBusy()) return true; } catch (e) { /* ignore */ }
        return false;
    }

    // Returns 'newer' | 'current' | 'offline' | 'unknown'.
    // 'newer' lights the red dot; with { popup: true } it also opens the popup (unless something else is open).
    function checkForAppUpdate(opts) {
        if (!isOnline()) return Promise.resolve('offline');
        return fetchServerVersion().then(function (server) {
            var running = runningVersion();
            if (!server || !running) return 'unknown';
            if (server > running) {
                state.updatePending = server;
                if (els.dot) els.dot.hidden = false;
                if (opts && opts.popup && !somethingElseOpen()) showModal('newer');
                return 'newer';
            }
            state.updatePending = null;
            if (els.dot) els.dot.hidden = true;
            return 'current';
        }).catch(function () { return 'unknown'; });
    }

    // ---------- popup ----------
    var TEXT = {
        checking: 'Checking for a new version…',
        current: 'You have the latest version.',
        offline: 'You are offline. Connect to the internet to check for updates.',
        unknown: 'Could not check right now. Please try again in a moment.',
        offlineUpdate: 'You are offline. Connect to the internet to update the app.'
    };

    function showModal(kind) {
        if (!els.overlay) return;
        els.text.textContent = kind === 'newer'
            ? 'A new version (v' + state.updatePending + ') is ready. Tap Update now to install it.'
            : (TEXT[kind] || TEXT.unknown);
        els.version.textContent = 'v' + runningVersion();
        els.now.style.display = kind === 'newer' ? '' : 'none';
        els.later.textContent = kind === 'newer' ? 'Later' : 'OK';
        els.overlay.classList.add('open');
        (kind === 'newer' ? els.now : els.later).focus();
    }
    function hideModal() { if (els.overlay) els.overlay.classList.remove('open'); }

    function onIconTap() {
        if (state.updatePending) { showModal('newer'); return; }
        showModal('checking');
        checkForAppUpdate().then(showModal);
    }

    // Forget the offline copy of the app files and the old service worker. IndexedDB / localStorage are NOT touched,
    // so offline punches waiting to sync and the saved login stay safe.
    function clearAppCaches() {
        var jobs = [];
        try {
            if ('serviceWorker' in navigator) {
                jobs.push(navigator.serviceWorker.getRegistrations().then(function (regs) {
                    return Promise.all(regs.map(function (r) { return r.unregister(); }));
                }));
            }
            if (window.caches) {
                jobs.push(caches.keys().then(function (keys) { return Promise.all(keys.map(function (k) { return caches.delete(k); })); }));
            }
        } catch (e) { /* reload anyway */ }
        return Promise.all(jobs).catch(function () { /* reload anyway */ });
    }

    function updateNow() {
        if (!isOnline()) { showModal('offlineUpdate'); return; }
        els.now.disabled = true;
        clearAppCaches().then(function () { window.location.reload(); });
    }

    // ---------- DOM ----------
    var CSS = '' +
        '.dawam-upd-btn{position:relative;width:34px;height:34px;padding:5px;border-radius:50%;border:1px solid rgba(120,120,120,.45);background:rgba(255,255,255,.92);color:#4a5568;display:inline-flex;align-items:center;justify-content:center;cursor:pointer;flex:0 0 auto;vertical-align:middle}' +
        '.dawam-upd-btn svg{width:20px;height:20px;display:block}' +
        '.dawam-upd-btn.floating{position:fixed;top:8px;right:8px;z-index:9000}' +
        '.dawam-upd-btn.floating-br{position:fixed;bottom:calc(14px + env(safe-area-inset-bottom,0px));right:14px;z-index:9000}' +
        '.dawam-upd-dot{position:absolute;top:0;right:0;width:11px;height:11px;border-radius:50%;background:#ff3b30;border:2px solid #fff}' +
        '.dawam-upd-dot[hidden]{display:none}' +
        '.dawam-upd-overlay{position:fixed;inset:0;z-index:100000;background:rgba(0,0,0,.55);display:none;align-items:center;justify-content:center;padding:16px}' +
        '.dawam-upd-overlay.open{display:flex}' +
        '.dawam-upd-box{background:#fff;color:#2d3748;border-radius:14px;max-width:360px;width:100%;padding:22px 20px;text-align:center;box-shadow:0 12px 40px rgba(0,0,0,.35);font-family:inherit}' +
        '.dawam-upd-box h3{margin:8px 0 10px;font-size:18px}' +
        '.dawam-upd-box p{margin:0 0 6px;font-size:15px;line-height:1.4}' +
        '.dawam-upd-ver{font-size:12px;color:#718096;margin-top:6px}' +
        '.dawam-upd-actions{display:flex;gap:10px;justify-content:center;margin-top:16px}' +
        '.dawam-upd-actions button{min-width:110px;padding:10px 14px;border-radius:8px;border:1px solid #cbd5e0;background:#edf2f7;color:#2d3748;font-size:15px;cursor:pointer}' +
        '.dawam-upd-actions button.primary{background:#667eea;border-color:#667eea;color:#fff}';

    var ICON = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' +
        '<path d="M21 8l-9-5-9 5v8l9 5 9-5z"/><path d="M3 8l9 5 9-5"/><path d="M12 13v8"/></svg>';

    function build() {
        var style = document.createElement('style');
        style.textContent = CSS;
        document.head.appendChild(style);

        var btn = document.createElement('button');
        btn.type = 'button'; btn.id = 'dawamUpdateBtn'; btn.className = 'dawam-upd-btn';
        btn.title = 'App updates'; btn.setAttribute('aria-label', 'App updates');
        btn.innerHTML = ICON + '<span class="dawam-upd-dot" id="dawamUpdateDot" hidden></span>';
        var host = document.querySelector('.header-actions');
        if (host) { host.insertBefore(btn, host.firstChild); }
        else {
            // Punch terminal: the top-right holds the clock, so the icon sits bottom-right. Other pages without a header: top-right.
            btn.className += document.querySelector('.top-bar') ? ' floating-br' : ' floating';
            document.body.appendChild(btn);
        }

        var overlay = document.createElement('div');
        overlay.className = 'dawam-upd-overlay'; overlay.id = 'dawamUpdateModal';
        overlay.setAttribute('role', 'dialog'); overlay.setAttribute('aria-modal', 'true'); overlay.setAttribute('aria-labelledby', 'dawamUpdateTitle');
        overlay.innerHTML =
            '<div class="dawam-upd-box">' + ICON.replace('<svg ', '<svg style="width:48px;height:48px;color:#667eea" ') +
            '<h3 id="dawamUpdateTitle">App update</h3>' +
            '<p id="dawamUpdateText"></p>' +
            '<p class="dawam-upd-ver">Running version <strong id="dawamUpdateVer">v?</strong></p>' +
            '<div class="dawam-upd-actions"><button type="button" class="primary" id="dawamUpdateNow">Update now</button>' +
            '<button type="button" id="dawamUpdateLater">Later</button></div></div>';
        document.body.appendChild(overlay);

        els = {
            btn: btn, dot: btn.querySelector('.dawam-upd-dot'), overlay: overlay,
            text: overlay.querySelector('#dawamUpdateText'), version: overlay.querySelector('#dawamUpdateVer'),
            now: overlay.querySelector('#dawamUpdateNow'), later: overlay.querySelector('#dawamUpdateLater')
        };
        btn.addEventListener('click', onIconTap);
        els.now.addEventListener('click', updateNow);
        els.later.addEventListener('click', hideModal);
    }

    // ---------- scheduling ----------
    function scheduleChecks() {
        function run() { state.lastCheck = Date.now(); checkForAppUpdate({ popup: true }); }
        setTimeout(run, CHECK_AFTER_OPEN_MS);                                       // shortly after opening
        document.addEventListener('visibilitychange', function () {                // coming back to the foreground
            if (document.visibilityState === 'visible' && Date.now() - state.lastCheck > MIN_GAP_MS) run();
        });
        window.addEventListener('online', function () { setTimeout(run, CHECK_AFTER_ONLINE_MS); });   // connection returned
    }

    function registerServiceWorker() {
        if (!('serviceWorker' in navigator)) return;
        var hadController = !!navigator.serviceWorker.controller;
        window.addEventListener('load', function () {
            navigator.serviceWorker.register('/sw.js').catch(function (err) { console.error('SW registration failed:', err); });
        });
        // A different service worker took over a page that already had one: a deploy happened, check right away.
        // (No automatic reload: see the note at the top of this file.)
        navigator.serviceWorker.addEventListener('controllerchange', function () {
            if (hadController) checkForAppUpdate({ popup: true });
        });
    }

    function start() {
        build();
        scheduleChecks();
    }
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
    registerServiceWorker();

    // Small public surface: page hooks (isBusy) and tests.
    window.DawamUpdate = {
        isBusy: null,
        check: checkForAppUpdate,
        runningVersion: runningVersion,
        showModal: showModal,
        _clearAppCaches: clearAppCaches,   // exposed for tests
        _state: state
    };
})();
