// Dawam Attendance - Punch terminal API (new login only)
//
// With the new login the terminal is a "user" of its company with the role "terminal":
//     email  terminal@<company code>.<login domain>     password = the TERMINAL KEY
// A terminal cannot read or change any table. It can only call the terminal_* database functions (migration 004),
// which return exactly what a terminal needs and apply the punch rules (night-shift date, duplicates, attendance).
// The old login (live site, until the cutover) does not use this file.
const TerminalAPI = {
    active: false,                 // true on the punch page when the new login is in use
    KEY_STORAGE: 'dawam_terminal_key',
    _cache: null,                  // last bootstrap result {time, data}

    isNewLogin() { return typeof DAWAM_AUTH_MODE !== 'undefined' && DAWAM_AUTH_MODE === 'supabase'; },

    emailFor(clientCode) { return `terminal@${String(clientCode).toLowerCase().trim()}.${DAWAM_LOGIN_EMAIL_DOMAIN}`; },

    _storage(op, key, value) {
        try { return op === 'get' ? localStorage.getItem(key) : localStorage.setItem(key, value); } catch (e) { return null; }
    },

    // The terminal link looks like  punch/?client=CODE#key=TERMINALKEY . The key is read once, kept on this device
    // and removed from the address bar (a "#" part is never sent to the website's server).
    takeKeyFromAddress() {
        const m = (window.location.hash || '').match(/[#&]key=([^&]+)/);
        if (!m) return;
        this._storage('set', this.KEY_STORAGE, decodeURIComponent(m[1]));
        try { window.history.replaceState(null, '', window.location.pathname + window.location.search); } catch (e) { /* ignore */ }
    },

    // Make sure this device has a terminal session for the company; sign in with the stored key when needed.
    async ensureSession(clientCode) {
        const code = clientCode || this._storage('get', 'pwa_client_code');
        if (!code || !/^[a-z0-9._-]+$/i.test(code)) return { ok: false, error: 'Missing or invalid client code.' };
        const email = this.emailFor(code);
        try {
            const { data } = await supabaseClient.auth.getSession();
            if (data && data.session && (data.session.user.email || '').toLowerCase() === email) return { ok: true };
            const key = this._storage('get', this.KEY_STORAGE);
            if (!key) return { ok: false, error: 'This terminal needs its terminal key. Open the terminal link your administrator gave you.' };
            const { error } = await supabaseClient.auth.signInWithPassword({ email, password: key });
            if (error) {
                if (error.status === 429) return { ok: false, error: 'Too many attempts. Please wait a few minutes and try again.' };
                if (/fetch|network/i.test(error.message || '')) return { ok: false, error: 'Cannot connect to server. Check internet connection.' };
                return { ok: false, error: 'Terminal key not accepted. Ask your administrator for the current terminal link.' };
            }
            return { ok: true };
        } catch (e) {
            return { ok: false, error: 'Cannot connect to server. Check internet connection.' };
        }
    },

    // Called once when the punch page starts online.
    async start(clientCode) {
        this.takeKeyFromAddress();
        const s = await this.ensureSession(clientCode);
        if (s.ok) this.active = true;
        return s;
    },

    async _rpc(name, args) {
        const s = await this.ensureSession();
        if (!s.ok) return { error: { message: s.error } };
        return supabaseClient.rpc(name, args);
    },
    _fail(error) {
        const msg = (error && error.message) || 'Request failed';
        if (/not allowed/i.test(msg)) return 'This terminal is not allowed (account inactive or expired, or the terminal login is wrong).';
        return msg;
    },

    // Everything the terminal keeps for offline use. Cached for a few seconds so one start-up asks only once.
    async bootstrap(opts) {
        if (!(opts && opts.fresh) && this._cache && Date.now() - this._cache.time < 15000) return { ok: true, data: this._cache.data };
        const { data, error } = await this._rpc('terminal_bootstrap', {});
        if (error) return { ok: false, error: this._fail(error) };
        this._cache = { time: Date.now(), data };
        return { ok: true, data };
    },

    async getPunchState(laborId, date) {
        const { data, error } = await this._rpc('terminal_punch_state', { p_labor_id: laborId, p_date: date || DateUtils.today() });
        return error ? { success: false, error: this._fail(error) } : { success: true, data };
    },
    async checkPunchLimit(laborId) {
        const r = await this.getPunchState(laborId);
        if (!r.success) return r;
        return { success: true, allowed: Number(r.data.count) < Number(r.data.max), current: Number(r.data.count), max: Number(r.data.max) };
    },
    async getNextPunchType(laborId) {
        const r = await this.getPunchState(laborId);
        if (!r.success) return 'login';                 // same fallback as before
        return r.data.last_type === 'login' ? 'logout' : 'login';
    },

    async todayPunches(laborId, date) {
        const { data, error } = await this._rpc('terminal_today_punches', { p_labor_id: laborId, p_date: date || DateUtils.today() });
        return error ? { data: null, error: { message: this._fail(error) } } : { data: data || [], error: null };
    },

    // the page calls this name for both systems (old: PunchAPI.savePunch)
    async savePunchCompat(punch) { return this.recordPunch(punch); },

    async recordPunch(punch) {
        const { data, error } = await this._rpc('terminal_record_punch', { p: {
            labor_id: punch.laborId, type: punch.type, date: punch.date, time: punch.time,
            location_id: punch.locationId || null, location_name: punch.locationName || null,
            confidence: punch.confidence == null ? null : Math.round(punch.confidence), photo_url: punch.photoUrl || null
        } });
        return error ? { success: false, error: this._fail(error) } : { success: true, data };
    },

    async lowConfidence(laborId) {
        const { data, error } = await this._rpc('terminal_low_confidence', { p_labor_id: laborId });
        return error ? { success: false, error: this._fail(error) } : { success: true, needsReenrollment: !!(data && data.needs_reenrollment) };
    },

    // Locations come from the copy kept on the device (loaded at start-up and on every sync)
    async findNearestLocation(userLat, userLng, departmentId) {
        const locations = await OfflineStorage.getPunchLocations();
        const dept = locations.filter(l => l.department_id === departmentId && l.status === 'active');
        if (dept.length === 0) return { success: false, error: 'No locations configured for department' };
        let nearest = null, min = Infinity;
        for (const loc of dept) {
            const d = PunchAPI.calculateDistance(userLat, userLng, parseFloat(loc.latitude), parseFloat(loc.longitude));
            if (d <= loc.radius && d < min) { min = d; nearest = { ...loc, distance: Math.round(d) }; }
        }
        return nearest ? { success: true, location: nearest } : { success: false, error: 'Outside punch area' };
    }
};
