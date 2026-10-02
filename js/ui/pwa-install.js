// Dawam Attendance - "install this app" prompt for the punch terminal.
// Android / desktop Chrome and Edge: when the browser says the app can be installed, a card appears in the
// MIDDLE of the screen with an Install button (shown on every start until the app is installed).
// iPhone / iPad (Safari has no install prompt): the same card explains "Share > Add to Home Screen".
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

    var overlay = null;
    function ensureOverlay() {
        if (overlay) return overlay;
        var style = document.createElement('style');
        style.textContent =
            '.dawam-install{position:fixed;inset:0;z-index:99990;background:rgba(0,0,0,.6);display:none;align-items:center;justify-content:center;padding:16px}' +
            '.dawam-install.show{display:flex}' +
            '.dawam-install-box{background:#fff;color:#2d3748;border-radius:16px;max-width:340px;width:100%;padding:24px 20px;text-align:center;box-shadow:0 12px 40px rgba(0,0,0,.4);font:15px/1.4 sans-serif}' +
            '.dawam-install-box img{width:72px;height:72px;border-radius:16px;display:block;margin:0 auto 10px}' +
            '.dawam-install-box h3{margin:0 0 8px;font-size:19px}' +
            '.dawam-install-box p{margin:0 0 6px}' +
            '.dawam-install-actions{display:flex;gap:10px;justify-content:center;margin-top:16px}' +
            '.dawam-install-actions button{min-width:110px;padding:11px 14px;border-radius:8px;border:1px solid #cbd5e0;background:#edf2f7;color:#2d3748;font-size:15px;cursor:pointer}' +
            '.dawam-install-actions button.go{background:#667eea;border-color:#667eea;color:#fff}';
        document.head.appendChild(style);
        overlay = document.createElement('div');
        overlay.className = 'dawam-install'; overlay.id = 'dawamInstallBar';
        overlay.setAttribute('role', 'dialog'); overlay.setAttribute('aria-modal', 'true');
        document.body.appendChild(overlay);
        return overlay;
    }
    function hide() { if (overlay) overlay.classList.remove('show'); }

    function card(body, buttons) {
        var o = ensureOverlay();
        o.innerHTML = '<div class="dawam-install-box"><img src="/icons/icon-192.png" alt="">' +
            '<h3>Install Dawam Attendance</h3>' + body + '<div class="dawam-install-actions">' + buttons + '</div></div>';
        o.classList.add('show');
        return o;
    }

    function showInstallCard() {
        if (isStandalone()) return;
        var o = card('<p>Install the app on this device for faster start and offline use.</p>',
            '<button type="button" class="go" id="dawamInstallGo">Install</button><button type="button" id="dawamInstallNo">Not now</button>');
        o.querySelector('#dawamInstallGo').addEventListener('click', function () {
            if (!deferredPrompt) return;
            var p = deferredPrompt; deferredPrompt = null;
            hide();
            p.prompt();
            if (p.userChoice && p.userChoice.then) p.userChoice.then(function () { /* accepted or dismissed: nothing more to do */ });
        });
        o.querySelector('#dawamInstallNo').addEventListener('click', hide);
    }

    function showIosCard() {
        if (isStandalone() || storageGet(HINT_KEY)) return;
        var o = card('<p>Tap <strong>Share</strong>, then <strong>Add to Home Screen</strong>.</p>',
            '<button type="button" class="go" id="dawamInstallNo">Got it</button>');
        o.querySelector('#dawamInstallNo').addEventListener('click', function () { storageSet(HINT_KEY, '1'); hide(); });
    }

    window.addEventListener('beforeinstallprompt', function (e) {
        e.preventDefault();                  // keep the browser's own mini-bar away; we show our card instead
        deferredPrompt = e;
        showInstallCard();
    });
    window.addEventListener('appinstalled', function () { deferredPrompt = null; hide(); });

    if (isIos()) {
        if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', showIosCard); else showIosCard();
    }
})();
