// Mastodon plugin for SwiftMaestro.
//
// Uses only window.swiftMaestro.fetch (native URLSession proxy, sidesteps
// CORS - most Mastodon instances don't set permissive CORS for arbitrary
// origins) and window.swiftMaestro.getSecret/setSecret (Keychain-backed,
// namespaced to this plugin - see PluginBridge.swift). The instance URL
// itself isn't secret, so it lives in localStorage; the access token never
// touches localStorage/JS-persistent storage - only the Keychain via the
// bridge, refetched each time the page loads.

const REFRESH_INTERVAL_MS = 30_000;
const INSTANCE_KEY = "mastodon.instanceURL";

const setupEl = document.getElementById("setup");
const appEl = document.getElementById("app");
const instanceInput = document.getElementById("instanceInput");
const tokenInput = document.getElementById("tokenInput");
const connectButton = document.getElementById("connectButton");
const setupError = document.getElementById("setupError");
const accountLabel = document.getElementById("accountLabel");
const refreshButton = document.getElementById("refreshButton");
const disconnectButton = document.getElementById("disconnectButton");
const composeText = document.getElementById("composeText");
const composeCount = document.getElementById("composeCount");
const postButton = document.getElementById("postButton");
const timelineError = document.getElementById("timelineError");
const timelineEl = document.getElementById("timeline");

let instanceURL = null;
let accessToken = null;
let refreshTimer = null;

init();

async function init() {
  instanceURL = localStorage.getItem(INSTANCE_KEY);
  if (instanceURL) {
    try {
      accessToken = await window.swiftMaestro.getSecret("accessToken");
    } catch (err) {
      console.error("getSecret failed:", err);
    }
  }

  if (instanceURL && accessToken) {
    showApp();
    await loadAccount();
    await loadTimeline();
    scheduleRefresh();
  } else {
    showSetup();
  }
}

function showSetup() {
  setupEl.classList.remove("hidden");
  appEl.classList.add("hidden");
}

function showApp() {
  setupEl.classList.add("hidden");
  appEl.classList.remove("hidden");
}

// MARK: - Setup

connectButton.addEventListener("click", async () => {
  const url = normalizeInstanceURL(instanceInput.value.trim());
  const token = tokenInput.value.trim();
  if (!url || !token) {
    showSetupError("Both fields are required.");
    return;
  }

  connectButton.disabled = true;
  setupError.classList.add("hidden");
  try {
    const account = await mastodonGET(url, token, "/api/v1/accounts/verify_credentials");
    instanceURL = url;
    accessToken = token;
    localStorage.setItem(INSTANCE_KEY, url);
    await window.swiftMaestro.setSecret("accessToken", token);
    renderAccountLabel(account);
    showApp();
    await loadTimeline();
    scheduleRefresh();
  } catch (err) {
    showSetupError(describeError(err));
  } finally {
    connectButton.disabled = false;
  }
});

function showSetupError(message) {
  setupError.textContent = message;
  setupError.classList.remove("hidden");
}

function normalizeInstanceURL(value) {
  if (!value) return null;
  let url = value;
  if (!/^https?:\/\//i.test(url)) url = "https://" + url;
  return url.replace(/\/+$/, "");
}

// MARK: - Account / timeline

async function loadAccount() {
  try {
    const account = await mastodonGET(instanceURL, accessToken, "/api/v1/accounts/verify_credentials");
    renderAccountLabel(account);
  } catch (err) {
    console.error("loadAccount failed:", err);
  }
}

function renderAccountLabel(account) {
  accountLabel.textContent = "@" + account.username;
}

refreshButton.addEventListener("click", () => loadTimeline());
disconnectButton.addEventListener("click", () => {
  localStorage.removeItem(INSTANCE_KEY);
  instanceURL = null;
  accessToken = null;
  if (refreshTimer) clearInterval(refreshTimer);
  timelineEl.innerHTML = "";
  instanceInput.value = "";
  tokenInput.value = "";
  showSetup();
});

function scheduleRefresh() {
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = setInterval(() => loadTimeline(), REFRESH_INTERVAL_MS);
}

async function loadTimeline() {
  timelineError.classList.add("hidden");
  try {
    const statuses = await mastodonGET(instanceURL, accessToken, "/api/v1/timelines/home?limit=30");
    renderTimeline(statuses);
  } catch (err) {
    timelineError.textContent = describeError(err);
    timelineError.classList.remove("hidden");
  }
}

function renderTimeline(statuses) {
  if (!statuses.length) {
    timelineEl.innerHTML = '<div class="empty-state">No posts yet.</div>';
    return;
  }
  timelineEl.innerHTML = statuses.map(renderStatus).join("");
}

function renderStatus(status) {
  // Boosts (reblogs) show the original post; keep the booster's name out of
  // scope for this simple view and just render what was actually posted.
  const target = status.reblog || status;
  const account = target.account;
  const time = formatTime(target.created_at);
  return `
    <div class="status">
      <img class="avatar" src="${escapeAttr(account.avatar)}" loading="lazy">
      <div class="status-body">
        <div class="status-header">
          <span class="display-name">${escapeHTML(account.display_name || account.username)}</span>
          <span class="handle">@${escapeHTML(account.acct)}</span>
          <span class="time">${time}</span>
        </div>
        <div class="status-content">${target.content}</div>
        <div class="status-stats">
          <span>↩ ${target.replies_count ?? 0}</span>
          <span>⟲ ${target.reblogs_count ?? 0}</span>
          <span>★ ${target.favourites_count ?? 0}</span>
        </div>
      </div>
    </div>`;
}

// MARK: - Compose

composeText.addEventListener("input", () => {
  const remaining = 500 - composeText.value.length;
  composeCount.textContent = String(remaining);
  composeCount.style.color = remaining < 0 ? "var(--error)" : "";
});

postButton.addEventListener("click", async () => {
  const text = composeText.value.trim();
  if (!text || text.length > 500) return;

  postButton.disabled = true;
  try {
    await mastodonPOST(instanceURL, accessToken, "/api/v1/statuses", { status: text });
    composeText.value = "";
    composeCount.textContent = "500";
    await loadTimeline();
  } catch (err) {
    timelineError.textContent = "Post failed: " + describeError(err);
    timelineError.classList.remove("hidden");
  } finally {
    postButton.disabled = false;
  }
});

// MARK: - HTTP helpers (via the native fetch bridge, not the browser's own fetch)

async function mastodonGET(instance, token, path) {
  const result = await window.swiftMaestro.fetch(instance + path, {
    method: "GET",
    headers: { Authorization: "Bearer " + token },
  });
  return parseMastodonResponse(result);
}

async function mastodonPOST(instance, token, path, jsonBody) {
  const result = await window.swiftMaestro.fetch(instance + path, {
    method: "POST",
    headers: {
      Authorization: "Bearer " + token,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(jsonBody),
  });
  return parseMastodonResponse(result);
}

function parseMastodonResponse(result) {
  let parsed = null;
  try {
    parsed = result.body ? JSON.parse(result.body) : null;
  } catch (e) {
    // fall through - a non-JSON body on a non-2xx response still surfaces
    // the raw status below.
  }
  if (result.status < 200 || result.status >= 300) {
    const message = (parsed && parsed.error) || `HTTP ${result.status}`;
    throw new Error(message);
  }
  return parsed;
}

function describeError(err) {
  return err && err.message ? err.message : String(err);
}

// MARK: - Formatting

function formatTime(iso) {
  const date = new Date(iso);
  const diffMs = Date.now() - date.getTime();
  const diffMin = Math.round(diffMs / 60000);
  if (diffMin < 1) return "now";
  if (diffMin < 60) return diffMin + "m";
  const diffHr = Math.round(diffMin / 60);
  if (diffHr < 24) return diffHr + "h";
  const diffDay = Math.round(diffHr / 24);
  return diffDay + "d";
}

function escapeHTML(text) {
  const div = document.createElement("div");
  div.textContent = text ?? "";
  return div.innerHTML;
}

function escapeAttr(text) {
  return (text ?? "").replace(/"/g, "&quot;");
}
