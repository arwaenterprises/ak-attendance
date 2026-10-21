// Dawam Attendance - "is this a live person?" check before the punch photo (a printed photo or a photo on another phone fails it)
// Uses the 68 face points face-api.js already finds, on the live camera, while the camera stays on screen.
// Accepted: a BLINK (eyes clearly less open than this person's own normal, then open again) or a small HEAD TURN and back
// (the nose moves sideways compared with the eyes; on a flat photo that is tilted or turned the nose stays in the same place
// between the eyes, so a photo does not pass).
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

    // one eye value per camera frame; push() returns true once a blink was seen.
    // "normal open" = the higher values seen so far (this person's own eyes, not a fixed number); a blink = at least 25 % less, then back.
    blinkDetector() {
        const seen = [];
        let closed = false;
        const normal = () => { const s = seen.slice().sort((a, b) => b - a); return s[Math.min(1, s.length - 1)]; };   // 2nd highest: one odd frame does not count
        return {
            push(value) {
                if (!isFinite(value) || value <= 0) return false;
                seen.push(value);
                if (seen.length > 30) seen.shift();
                if (seen.length < 3) return false;
                const open = normal();
                if (open < 0.12) return false;                      // eyes never really seen open
                if (!closed) { if (value < open * 0.75) closed = true; return false; }
                return value > open * 0.88;
            }
        };
    },

    // one nose offset per frame; push() returns true once the head turned (about 15 degrees) and came back towards the middle
    turnDetector() {
        const first = [];
        let turned = false;
        return {
            push(value) {
                if (!isFinite(value)) return false;
                if (first.length < 3) { first.push(value); return false; }
                const base = first.slice().sort((a, b) => a - b)[1];
                if (!turned) { if (Math.abs(value - base) > 0.12) turned = true; return false; }
                return Math.abs(value - base) < 0.06;
            }
        };
    },

    // watch the live camera until a blink or a head turn is seen, the time runs out, or opts.stop() says stop.
    // opts.onFace(seen) tells the page whether a face is in view (the oval changes colour).
    async waitForLive(video, timeoutMs = 10000, opts = {}) {
        const blink = this.blinkDetector(), turn = this.turnDetector();
        const end = Date.now() + timeoutMs;
        const detector = new faceapi.TinyFaceDetectorOptions({ inputSize: 160, scoreThreshold: 0.4 });
        // a smaller copy of the frame is faster on slow phones (more frames per second = a quick blink is not missed)
        const small = document.createElement('canvas');
        while (Date.now() < end) {
            if (opts.stop && opts.stop()) return false;
            const vw = video.videoWidth || 640, vh = video.videoHeight || 480, k = Math.min(1, 480 / vw);
            small.width = Math.round(vw * k); small.height = Math.round(vh * k);
            small.getContext('2d').drawImage(video, 0, 0, small.width, small.height);
            const f = await faceapi.detectSingleFace(small, detector).withFaceLandmarks();
            if (opts.onFace) opts.onFace(!!f);
            if (f) {
                const v = (this.ear(f.landmarks.getLeftEye()) + this.ear(f.landmarks.getRightEye())) / 2;
                const blinked = blink.push(v);
                const turned = turn.push(this.noseOffset(f.landmarks.positions));
                if (blinked || turned) return true;
            }
            await new Promise(r => setTimeout(r, 0));
        }
        return false;
    }
};
