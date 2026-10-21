// Dawam Attendance - GPS readings for a punch (migration 024)
// The terminal takes a few fresh readings while the labor lines up with the oval and sends them with the punch; the DATABASE decides
// (inside a punch area, accuracy, fake-looking readings). judge() applies the same rules on the phone so the labor sees the answer at once
// (and an offline punch that the database would refuse is not kept).
const GeoCheck = {
    // up to `count` readings, one after the other, within about `totalMs`
    async collect(count = 3, totalMs = 3000) {
        const readings = [];
        if (!navigator.geolocation) return readings;
        const one = () => new Promise(resolve => {
            navigator.geolocation.getCurrentPosition(
                p => resolve({ lat: p.coords.latitude, lng: p.coords.longitude, acc: p.coords.accuracy }),
                () => resolve(null),
                { enableHighAccuracy: true, maximumAge: 0, timeout: Math.max(1500, totalMs) });
        });
        const end = Date.now() + totalMs;
        for (let i = 0; i < count; i++) {
            const r = await one();
            if (r && isFinite(r.lat) && isFinite(r.lng) && isFinite(r.acc)) readings.push(r);
            if (Date.now() > end && readings.length) break;
            if (i < count - 1) await new Promise(res => setTimeout(res, 300));
        }
        return readings;
    },

    // same rules as public._gps_check in the database. settings = the company settings the terminal received.
    judge(readings, settings) {
        const notFound = { ok: false, code: 'LOCATION_NOT_FOUND', message: 'Location not found' };
        const list = (readings || []).filter(r => r && isFinite(r.lat) && isFinite(r.lng) && isFinite(r.acc) && Math.abs(r.lat) <= 90 && Math.abs(r.lng) <= 180);
        if (!list.length) return notFound;
        const best = list.slice().sort((a, b) => a.acc - b.acc || a.lat - b.lat || a.lng - b.lng)[0];
        if (best.acc < 1) return notFound;
        const staticOn = String((settings && settings.gps_static_check) || 'true') !== 'false';
        const points = new Set(list.map(r => r.lat + ',' + r.lng)).size;
        if (staticOn && list.length >= 3 && points === 1 && best.acc <= 20) return notFound;
        const maxAcc = parseFloat(settings && settings.max_gps_accuracy) || 100;
        if (best.acc > maxAcc) return { ok: false, code: 'POOR_GPS', message: 'Weak GPS signal. Please step outside and try again.' };
        return { ok: true, best };
    }
};
