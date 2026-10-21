// Dawam Attendance - "is this a live person?" check before the punch photo, with NO instruction to the labor
// (owner 2026-10-21: no blink; let the camera see the natural movement of the face).
// Any movement is not enough: a printed photo held in a hand also moves. What only a real head does is move in 3D:
// when it turns even a little, the nose shifts against the eyes. On a flat photo (moved, tilted or turned) the nose
// stays at the same place between the eyes. So the check watches the nose position between the outer eye corners
// over the frames; a natural sway of a few degrees is enough. A blink, seen without being asked for, also counts.
const Liveness = {
    // eye openness = "eye aspect ratio" (height / width of the eye) from the 6 points of one eye
    ear(eye) {
        const d = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
        const w = d(eye[0], eye[3]);
        return w > 0 ? (d(eye[1], eye[5]) + d(eye[2], eye[4])) / (2 * w) : 0;
    },
    // where the nose tip is between the outer eye corners: about 0 looking straight, + / - when the head turns
    noseOffset(points) {
        const l = points[36], r = points[45], n = points[30];
        const w = Math.hypot(r.x - l.x, r.y - l.y);
        return w > 0 ? ((n.x - (l.x + r.x) / 2) * (r.x - l.x) + (n.y - (l.y + r.y) / 2) * (r.y - l.y)) / (w * w) : 0;
    },

    // natural head movement: one nose offset per frame; push() returns true once the (smoothed) offset has moved by
    // MOVE (0.035, a few degrees) or more. Smoothing over 3 frames removes most of the frame-to-frame jitter of the face points.
    MOVE: 0.035,
    motionDetector() {
        const raw = [], smooth = [];
        return {
            push(value) {
                if (!isFinite(value)) return false;
                raw.push(value);
                if (raw.length < 3) return false;
                const last = raw.slice(-3);
                smooth.push((last[0] + last[1] + last[2]) / 3);
                return Math.max(...smooth) - Math.min(...smooth) >= Liveness.MOVE;
            }
        };
    },

    // a blink that happens anyway (not asked for): eyes at least 25 % less open than this person's normal, then open again
    blinkDetector() {
        const seen = [];
        let closed = false;
        const normal = () => { const s = seen.slice().sort((a, b) => b - a); return s[Math.min(1, s.length - 1)]; };
        return {
            push(value) {
                if (!isFinite(value) || value <= 0) return false;
                seen.push(value);
                if (seen.length > 30) seen.shift();
                if (seen.length < 3) return false;
                const open = normal();
                if (open < 0.12) return false;
                if (!closed) { if (value < open * 0.75) closed = true; return false; }
                return value > open * 0.88;
            }
        };
    },

    // Watch the live camera until a live face is seen, the time runs out, or opts.stop() says stop.
    // opts.onFace(seen) - is a face in view (the oval colour); opts.onSlow() - called once after hintMs without a live sign.
    // Returns { live, faceFrames, frames } so the page can say WHY it failed (face not seen / no movement).
    async waitForLive(video, timeoutMs = 8000, opts = {}) {
        const motion = this.motionDetector(), blink = this.blinkDetector();
        const start = Date.now(), end = start + timeoutMs;
        // the same face finder as the face match (it works there); a medium size keeps it quick on phones
        const detector = new faceapi.TinyFaceDetectorOptions({ inputSize: 320, scoreThreshold: 0.4 });
        let frames = 0, faceFrames = 0, hinted = false;
        while (Date.now() < end) {
            if (opts.stop && opts.stop()) return { live: false, faceFrames, frames, stopped: true };
            if (!hinted && opts.onSlow && Date.now() - start > (opts.hintMs || 3500)) { hinted = true; opts.onSlow(); }
            frames++;
            const f = await faceapi.detectSingleFace(video, detector).withFaceLandmarks();
            if (opts.onFace) opts.onFace(!!f);
            if (f) {
                faceFrames++;
                const p = f.landmarks.positions;
                const moved = motion.push(this.noseOffset(p));
                const blinked = blink.push((this.ear(f.landmarks.getLeftEye()) + this.ear(f.landmarks.getRightEye())) / 2);
                if (moved || blinked) return { live: true, faceFrames, frames };
            }
            await new Promise(r => setTimeout(r, 0));
        }
        return { live: false, faceFrames, frames };
    }
};
