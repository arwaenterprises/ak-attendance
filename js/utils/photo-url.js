// Dawam Attendance - photo links (new login only)
//
// With the new login the photo bucket is PRIVATE. A photo is stored as a file PATH (<company id>/punches/..., <company id>/enrollment/...)
// and shown through a short-lived signed link that the database only gives to the company's own staff / terminal.
// Photos taken before the change are stored as full web addresses: this file turns those into paths too, so both kinds work.
// With the old login (live site until the cutover) nothing changes: the stored web address is used as it is.
const PhotoURL = {
    BUCKET: 'punch-photos',
    SECONDS: 3600,
    _cache: {},                          // path -> { url, until }
    TRANSPARENT: 'data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7',

    isPrivate() { return true; },                       // photos are always private (signed links)

    // the file path inside the bucket, from a stored value (path or old public web address)
    pathOf(ref) {
        if (!ref) return null;
        const s = String(ref);
        if (/^https?:\/\//i.test(s)) {
            const m = s.match(/\/punch-photos\/([^?#]+)/);
            return m ? decodeURIComponent(m[1]) : null;
        }
        return s;
    },

    // a link that works for the next hour (null when the photo cannot be shown)
    async resolve(ref) {
        if (!ref) return null;
        if (!this.isPrivate()) return String(ref);
        const path = this.pathOf(ref);
        if (!path) return null;
        const hit = this._cache[path];
        if (hit && hit.until > Date.now()) return hit.url;
        try {
            const { data, error } = await supabaseClient.storage.from(this.BUCKET).createSignedUrl(path, this.SECONDS);
            if (error || !data || !data.signedUrl) return null;
            this._cache[path] = { url: data.signedUrl, until: Date.now() + (this.SECONDS - 300) * 1000 };
            return data.signedUrl;
        } catch (e) {
            return null;
        }
    },

    // for templates: <img src="${PhotoURL.src(url)}" data-photo="${url}"> then PhotoURL.hydrate(container)
    src(ref) { return this.isPrivate() ? this.TRANSPARENT : ref; },

    async hydrate(root) {
        if (!root || !this.isPrivate()) return;
        const imgs = Array.from(root.querySelectorAll('img[data-photo]'));
        await Promise.all(imgs.map(async img => {
            const url = await this.resolve(img.getAttribute('data-photo'));
            if (url) img.src = url; else img.alt = 'Photo not available';
        }));
    },

    // open a photo in a new tab (the tab is opened first so the browser does not block it)
    async open(ref) {
        if (!ref) return;
        const w = window.open('', '_blank');
        const url = await this.resolve(ref);
        if (w && url) w.location = url; else if (w) w.close();
    }
};
