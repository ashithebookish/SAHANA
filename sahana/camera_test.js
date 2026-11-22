"use strict";

const form = document.querySelector("#camera-form");
const tokenInput = document.querySelector("#camera-token");
const startButton = document.querySelector("#start-camera");
const stopButton = document.querySelector("#stop-camera");
const status = document.querySelector("#camera-status");
const video = document.querySelector("#local-video");
const returnedFrame = document.querySelector("#returned-frame");
const localPlaceholder = document.querySelector("#local-placeholder");
const remotePlaceholder = document.querySelector("#remote-placeholder");
const frameCount = document.querySelector("#frame-count");

let current = null;

function announce(message, isError = false) {
    status.textContent = message;
    status.dataset.error = String(isError);
}

function authenticated(session, headers) {
    return { Authorization: "Bearer " + session.token, ...headers };
}

async function request(session, path, { headers, ...options } = {}) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 5000);
    try {
        const result = await fetch(path, {
            ...options,
            headers: authenticated(session, headers),
            cache: "no-store",
            redirect: "error",
            signal: controller.signal,
        });
        if (result.status === 401) {
            throw new Error("The local token did not match. Copy it again from the launcher.");
        }
        if (!result.ok) {
            const data = await result.json().catch(() => null);
            const detail = typeof data?.detail === "string" ? data.detail : "The local API rejected this request.";
            throw new Error(detail);
        }
        if (result.status === 204) return null;
        return result.headers.get("content-type")?.startsWith("image/jpeg")
            ? await result.blob()
            : await result.json();
    } catch (error) {
        if (error.name === "AbortError" || error instanceof TypeError) {
            throw new Error("The local API stopped responding. Check the launcher and try again.");
        }
        throw error;
    } finally {
        clearTimeout(timer);
    }
}

function json(method, body) {
    return { method, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) };
}

function assertCurrent(session) {
    if (session !== current) throw new DOMException("Camera stopped", "AbortError");
}

function stopTracks(session) {
    for (const track of session.stream?.getTracks() ?? []) track.stop();
    session.stream = null;
}

function releaseRemote(session) {
    // Take ownership of these IDs so overlapping cleanup cannot release a newer session.
    const lease = session.lease;
    const profilePath = session.profilePath;
    session.lease = null;
    const send = (path, options) => fetch(path, {
        ...options,
        headers: authenticated(session, options.headers),
        cache: "no-store",
        redirect: "error",
        keepalive: true,
    }).catch(() => null);
    if (lease) {
        void send(profilePath + "/camera/session", {
            method: "DELETE", headers: { "X-SAHANA-Camera-Session": lease },
        });
    }
    if (session.allowed) {
        session.allowed = false;
        void send(profilePath + "/monitoring", json("PATCH", { camera: false }));
    }
}

function finish(session, message, isError = false) {
    stopTracks(session);
    releaseRemote(session);
    if (current !== session) return;
    current = null;
    video.srcObject = null;
    video.hidden = true;
    localPlaceholder.hidden = false;
    if (session.frameURL) URL.revokeObjectURL(session.frameURL);
    returnedFrame.removeAttribute("src");
    returnedFrame.hidden = true;
    remotePlaceholder.hidden = false;
    startButton.disabled = false;
    stopButton.disabled = true;
    tokenInput.disabled = false;
    announce(message, isError);
}

function cameraMessage(error) {
    switch (error.name) {
        case "NotAllowedError":
            return "Camera access was denied. Allow this site to use the camera in the browser and system settings, then try again.";
        case "NotFoundError":
            return "The browser could not find a camera. Connect one or try the supplied camera-free example.";
        case "NotReadableError":
            return "The browser could not open the camera. Close other applications using it and try again.";
        default:
            return error.message || "The camera test stopped unexpectedly.";
    }
}

function capture(canvas, context) {
    context.drawImage(video, 0, 0, canvas.width, canvas.height);
    return new Promise((resolve) => canvas.toBlob(resolve, "image/jpeg", 0.72));
}

async function relay(session) {
    const canvas = document.createElement("canvas");
    const scale = Math.min(1, 640 / Math.max(video.videoWidth, video.videoHeight));
    canvas.width = Math.max(1, Math.round(video.videoWidth * scale));
    canvas.height = Math.max(1, Math.round(video.videoHeight * scale));
    const context = canvas.getContext("2d", { alpha: false });
    if (!context) throw new Error("This browser could not create a JPEG camera frame.");
    let count = 0;
    while (current === session) {
        const frame = await capture(canvas, context);
        assertCurrent(session);
        if (!frame || frame.type !== "image/jpeg" || frame.size > 512 * 1024) {
            throw new Error("The browser could not produce a JPEG under 512 KiB.");
        }
        await request(session, session.profilePath + "/camera/frame", {
            method: "PUT",
            headers: { "Content-Type": "image/jpeg", "X-SAHANA-Camera-Session": session.lease },
            body: frame,
        });
        assertCurrent(session);
        const received = await request(session, session.profilePath + "/camera/frame");
        assertCurrent(session);
        if (received) {
            if (session.frameURL) URL.revokeObjectURL(session.frameURL);
            session.frameURL = URL.createObjectURL(received);
            returnedFrame.src = session.frameURL;
            returnedFrame.hidden = false;
            remotePlaceholder.hidden = true;
            count += 1;
            frameCount.textContent = String(count);
            if (count === 1) announce("Camera is on. SAHANA returned the first frame.");
        }
        await new Promise((resolve) => setTimeout(resolve, 300));
    }
}

form.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (current) return;
    if (!navigator.mediaDevices?.getUserMedia) {
        announce("Open the printed loopback URL in a regular browser with camera support.", true);
        return;
    }
    const token = tokenInput.value.trim();
    if (!token) return;
    if (!/^[A-Za-z0-9_-]{24,200}$/.test(token)) {
        announce("Copy the complete local token from the launcher.", true);
        return;
    }
    const session = { token, stream: null, profilePath: null, lease: null, allowed: false, frameURL: null };
    current = session;
    startButton.disabled = true;
    stopButton.disabled = false;
    tokenInput.disabled = true;
    frameCount.textContent = "0";
    announce("Checking the local API.");
    try {
        await request(session, "/people");
        assertCurrent(session);
        announce("Waiting for browser camera permission.");
        session.stream = await navigator.mediaDevices.getUserMedia({
            audio: false,
            video: { width: { ideal: 640 }, height: { ideal: 480 } },
        });
        assertCurrent(session);
        for (const track of session.stream.getVideoTracks()) {
            track.addEventListener("ended", () => finish(session, "The camera disconnected.", true), { once: true });
        }
        video.srcObject = session.stream;
        video.hidden = false;
        localPlaceholder.hidden = true;
        await video.play();
        assertCurrent(session);
        if (!video.videoWidth || !video.videoHeight) throw new Error("The camera did not return a usable image.");
        announce("Connecting the camera to SAHANA.");
        const profile = await request(session, "/people", json("POST", { name: "Browser camera test" }));
        session.profilePath = "/people/" + encodeURIComponent(profile.id);
        assertCurrent(session);
        await request(session, session.profilePath + "/monitoring", json("PATCH", { camera: true }));
        session.allowed = true;
        assertCurrent(session);
        const lease = await request(session, session.profilePath + "/camera/session", json("POST", {
            setting: "shared_space",
        }));
        session.lease = lease.session_id;
        assertCurrent(session);
        await relay(session);
    } catch (error) {
        finish(session, cameraMessage(error), true);
    }
});

stopButton.addEventListener("click", () => {
    if (current) finish(current, "Camera off. The API feed was closed.");
});
window.addEventListener("pagehide", () => {
    if (current) finish(current, "Camera off.");
});
