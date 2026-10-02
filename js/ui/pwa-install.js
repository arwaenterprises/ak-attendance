// Dawam Attendance - "install this app" prompt for the punch terminal.
// Android / desktop Chrome and Edge: shows an Install button when the browser says the app can be installed.
// iPhone / iPad (Safari has no install prompt): shows a short "Add to Home Screen" hint instead.
(function () {
    'use strict';

    var deferredPrompt = null;
    var HINT_KEY = 'dawam_ios_hint_dismissed';

    function isStandalone() {
        return (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) || window.navigator.standalone === true;
    }
    function isIos() { return /iphone|ipad|ipod/i.test(navigator.userAgent) && !window.MSStream; }
    function storageGet(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
    function storageSet(k, v) { try { localStorage.setItem(k, v); } catch (e) { /* ignore */ } }

    var bar = null;
    function ensureBar() {
        if (bar) return bar;
        var style = document.createElement('style');
        style.textContent =
            '.dawam-install{position:fixed;left:12px;bottom:calc(12px + env(safe-area-inset-bottom,0px));z-index:9000;display:none;align-items:center;gap:10px;' +
            'background:#2d3748;color:#fff;padding:10px 14px;border-radius:999px;box-shadow:0 6px 20px rgba(0,0,0,.35);font:14px/1.3 sans-serif;max-width:calc(100vw - 84px)}' +
            '.dawam-install.show{display:flex}' +
            '.dawam-install button{border:0;border-radius:999px;padding:7px 14px;font-size:14px;cursor:pointer}' +
            '.dawam-install .go{background:#667eea;color:#fff}' +
            '.dawam-install .no{background:transparent;color:#cbd5e0;padding:7px 8px}';
        document.head.appendChild(style);
        bar = document.createElement('div');
        bar.className = 'dawam-install'; bar.id = 'dawamInstallBar';
        document.body.appendChild(bar);
        return bar;
    }
    function hide() { if (bar) bar.classList.remove('show'); }

    function showInstallButton() {
        if (isStandalone()) return;
        var b = ensureBar();
        b.innerHTML = '<span>Install Dawam Attendance on this device</span><button type="button" class="go" id="dawamInstallGo">Install</button><button type="button" class="no" id="dawamInstallNo" aria-label="Dismiss">✕</button>';
        b.classList.add('show');
        b.querySelector('#dawamInstallGo').addEventListener('click', function () {
            if (!deferredPrompt) return;
            var p = deferredPrompt; deferredPrompt = null;
            hide();
            p.prompt();
            if (p.userChoice && p.userChoice.then) p.userChoice.then(function () { /* accepted or dismissed: nothing more to do */ });
        });
        b.querySelector('#dawamInstallNo').addEventListener('click', hide);
    }

    function showIosHint() {
        if (isStandalone() || storageGet(HINT_KEY)) return;
        var b = ensureBar();
        b.innerHTML = '<span>To install: tap <strong>Share</strong>, then <strong>Add to Home Screen</strong></span><button type="button" class="no" id="dawamInstallNo" aria-label="Dismiss">✕</button>';
        b.classList.add('show');
        b.querySelector('#dawamInstallNo').addEventListener('click', function () { storageSet(HINT_KEY, '1'); hide(); });
    }

    window.addEventListener('beforeinstallprompt', function (e) {
        e.preventDefault();                  // keep the browser's own mini-bar away; we show our button instead
        deferredPrompt = e;
        showInstallButton();
    });
    window.addEventListener('appinstalled', function () { deferredPrompt = null; hide(); });

    if (isIos()) {
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', showIosHint); else showIosHint();
    }
})();
