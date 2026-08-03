#!/usr/bin/env node
// SwiftMaestro Tracking Relay Server
//
// A self-hostable email open/click tracking relay compatible with
// SwiftMaestro's embedded OwnTrack relay. Receives tracking pixel
// requests from recipients' email clients and logs open/click events
// to a local JSON store.
//
// Usage:
//   node server.js                        # default: port 3000
//   PORT=8087 node server.js              # custom port
//   STORE=/path/to/relay-store.json node server.js
//
// Endpoints:
//   GET /t/open/{token}.gif   — log open event, return 1x1 GIF
//   GET /t/c/{token}?url=...  — log click event, redirect to URL
//   GET /health               — 200 OK
//   GET /events?messageID=... — query events for a message
//   GET /events               — query all events (optional ?since=ISO)
//
// Store format matches SwiftMaestro's relay-store.json so events
// can be shared between the embedded relay and this server.

const http = require("http");
const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const url = require("url");

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const PORT = parseInt(process.env.PORT || "3000", 10);
const STORE_PATH = process.env.STORE_PATH || path.join(__dirname, "relay-store.json");

// 1x1 transparent GIF (smallest valid GIF)
const PIXEL_GIF = Buffer.from(
  "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7",
  "base64"
);

// ---------------------------------------------------------------------------
// Event store (same JSON format as SwiftMaestro's RelayEventStore)
// ---------------------------------------------------------------------------

let store = { messages: {}, events: [] };

function loadStore() {
  try {
    if (fs.existsSync(STORE_PATH)) {
      const data = fs.readFileSync(STORE_PATH, "utf-8");
      store = JSON.parse(data);
      if (!store.messages) store.messages = {};
      if (!store.events) store.events = [];
      console.log(`Loaded ${store.events.length} events from ${STORE_PATH}`);
    }
  } catch (err) {
    console.warn(`Could not load store: ${err.message}. Starting fresh.`);
  }
}

function saveStore() {
  try {
    const dir = path.dirname(STORE_PATH);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(STORE_PATH, JSON.stringify(store, null, 2));
  } catch (err) {
    console.error(`Failed to save store: ${err.message}`);
  }
}

// Debounced save — batch rapid writes (e.g. a flurry of opens)
let saveTimer = null;
function scheduleSave() {
  if (saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    saveStore();
  }, 1000);
}

function appendEvent(event) {
  store.events.push(event);
  scheduleSave();
}

function upsertMessage(message) {
  store.messages[message.messageID] = message;
  scheduleSave();
}

// ---------------------------------------------------------------------------
// Token decoding
//
// SwiftMaestro's HeaderEnvelopeIssuer generates opaque tokens that encode
// the message ID, recipient, and an HMAC signature. For the standalone relay
// we accept the raw token and use it as the event identifier — signature
// verification is optional (set VERIFY_TOKENS=1 + SIGNING_SECRET to enable).
// ---------------------------------------------------------------------------

const SIGNING_SECRET = process.env.SIGNING_SECRET || "";
const VERIFY_TOKENS = process.env.VERIFY_TOKENS === "1" && SIGNING_SECRET;

function decodeToken(token) {
  // Tokens from SwiftMaestro are base64url-encoded JSON envelopes.
  // Fallback: treat the token as an opaque string if decoding fails.
  try {
    const decoded = Buffer.from(token, "base64url").toString("utf-8");
    const payload = JSON.parse(decoded);

    if (VERIFY_TOKENS && payload.sig) {
      const expected = crypto
        .createHmac("sha256", SIGNING_SECRET)
        .update(`${payload.mid}:${payload.rcp}`)
        .digest("base64url");
      if (payload.sig !== expected) {
        return null; // invalid signature
      }
    }

    return {
      messageID: payload.mid || "unknown",
      recipient: payload.rcp || null,
    };
  } catch {
    return { messageID: token, recipient: null };
  }
}

// ---------------------------------------------------------------------------
// Request handling
// ---------------------------------------------------------------------------

function handleRequest(req, res) {
  const parsed = url.parse(req.url, true);
  const pathname = parsed.pathname;

  // CORS — allow the SwiftMaestro app to query events
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  // --- Health check ---
  if (pathname === "/health") {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("OK");
    return;
  }

  // --- Query events ---
  if (pathname === "/events") {
    const messageID = parsed.query.messageID;
    const since = parsed.query.since;
    let events = store.events;

    if (messageID) {
      events = events.filter((e) => e.messageID === messageID);
    }
    if (since) {
      const sinceDate = new Date(since).getTime();
      events = events.filter((e) => new Date(e.timestamp).getTime() >= sinceDate);
    }

    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify({ events }));
    return;
  }

  // --- Tracking pixel: /t/open/{token}.gif ---
  const openMatch = pathname.match(/^\/t\/open\/(.+)\.gif$/);
  if (openMatch) {
    const token = openMatch[1];
    const decoded = decodeToken(token);

    const event = {
      id: crypto.randomUUID(),
      messageID: decoded?.messageID || token,
      type: "open",
      timestamp: new Date().toISOString(),
      recipient: decoded?.recipient || null,
      sourceIP: req.headers["x-forwarded-for"] || req.socket.remoteAddress || null,
      userAgent: req.headers["user-agent"] || null,
      attributes: {},
    };

    appendEvent(event);
    console.log(`OPEN  ${event.messageID} from ${event.sourceIP}`);

    res.writeHead(200, {
      "Content-Type": "image/gif",
      "Cache-Control": "no-store, no-cache, must-revalidate",
      Pragma: "no-cache",
      Expires: "0",
    });
    res.end(PIXEL_GIF);
    return;
  }

  // --- Click redirect: /t/c/{token}?url=... ---
  const clickMatch = pathname.match(/^\/t\/c\/(.+)$/);
  if (clickMatch) {
    const token = clickMatch[1];
    const decoded = decodeToken(token);
    const destination = parsed.query.url || "/";

    const event = {
      id: crypto.randomUUID(),
      messageID: decoded?.messageID || token,
      type: "click",
      timestamp: new Date().toISOString(),
      recipient: decoded?.recipient || null,
      sourceIP: req.headers["x-forwarded-for"] || req.socket.remoteAddress || null,
      userAgent: req.headers["user-agent"] || null,
      attributes: { url: destination },
    };

    appendEvent(event);
    console.log(`CLICK ${event.messageID} → ${destination}`);

    res.writeHead(302, { Location: destination });
    res.end();
    return;
  }

  // --- 404 ---
  res.writeHead(404, { "Content-Type": "text/plain" });
  res.end("Not found");
}

// ---------------------------------------------------------------------------
// Start server
// ---------------------------------------------------------------------------

loadStore();

const server = http.createServer(handleRequest);
server.listen(PORT, () => {
  console.log(`SwiftMaestro Tracking Relay listening on http://localhost:${PORT}`);
  console.log(`Store: ${STORE_PATH}`);
  if (VERIFY_TOKENS) {
    console.log("Token verification: ENABLED");
  } else {
    console.log("Token verification: disabled (set VERIFY_TOKENS=1 + SIGNING_SECRET to enable)");
  }
});
