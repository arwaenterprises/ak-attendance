// Dawam Attendance - blink check before the punch photo (a printed photo or a photo on another phone cannot blink)
// Uses the 68 face points face-api.js already finds. Eye openness = "eye aspect ratio" (height of the eye / width of the eye):
// about 0.25-0.35 open, below about 0.2 closed. A blink = the eyes were seen open, then closed, then open again.
const Liveness = {
    // eye = the 6 points of one eye from face-api (getLeftEye() / getRightEye())
    ear(eye) {
        const d = (a, b) => Math.hypot(a.x - b.x, a.y - b.y);
        const w = d(eye[0], eye[3]);
        return w > 0 ? (d(eye[1], eye[5]) + d(eye[2], eye[4])) / (2 * w) : 0;
    },

    // feed it one eye value per camera frame; push() returns true once a full blink was seen
    blinkDetector() {
        let open = null;          // typical open-eye value of this face (highest values seen)
        let closedSeen = false;
        return {
            push(value) {
                if (!isFinite(value) || value <= 0) return false;
                if (open === null || value > open) open = value;
                const closedBelow = Math.min(0.21, open * 0.72), openAbove = open * 0.85;
                if (!closedSeen) { if (open >= 0.22 && value < closedBelow) closedSeen = true; return false; }
                return value > openAbove;
            }
        };
    },

    // watch the video until a blink is seen or the time runs out. onFace(seen) lets the page tell the labor what to do.
    async waitForBlink(video, timeoutMs = 8000, onFace) {
        const det = this.blinkDetector();
        const end = Date.now() + timeoutMs;
        const opts = new faceapi.TinyFaceDetectorOptions({ inputSize: 224 });
        while (Date.now() < end) {
            const f = await faceapi.detectSingleFace(video, opts).withFaceLandmarks();
            if (onFace) onFace(!!f);
            if (f) {
                const v = (this.ear(f.landmarks.getLeftEye()) + this.ear(f.landmarks.getRightEye())) / 2;
                if (det.push(v)) return true;
            }
            await new Promise(r => setTimeout(r, 30));
        }
        return false;
    }
};
