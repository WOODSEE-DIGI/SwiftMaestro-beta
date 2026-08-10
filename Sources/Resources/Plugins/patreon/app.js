// Patreon plugin for SwiftMaestro.
//
// Two modes:
//   1. Creator — paste a Creator's Access Token from a registered v2 client
//      (patreon.com/portal). Dashboard, members (with tiers/status), posts.
//      Optional client id/secret + refresh token enable auto-refresh.
//   2. Patron — full OAuth login (via the native startOAuth bridge: system
//      browser + loopback callback) against the user's own registered client.
//      Shows the user's identity + memberships. Note: Patreon does not expose
//      other creators' *posts* to ordinary OAuth clients, so patron mode is a
//      memberships view, not a content feed.
//
// API notes: JSON:API with explicit fields[]/include params; a User-Agent
// header is MANDATORY (403 without); 100 req/min per token with
// retry_after_seconds on 429. Tokens live in the Keychain via the bridge
// (plugin.patreon.*) — the native MaestroTools Patreon tools reuse them.

const API_BASE = "https://www.patreon.com/api/oauth2/v2";
const TOKEN_URL = "https://www.patreon.com/api/oauth2/token";
const AUTHORIZE_URL = "https://www.patreon.com/oauth2/authorize";
const USER_AGENT = "SwiftMaestro - Patreon Plugin";
const OAUTH_PORT = 53124;
const REDIRECT_URI = "http://127.0.0.1:53124/callback";

// Secrets (Keychain): accessToken, refreshToken, clientId, clientSecret, mode
const SECRET_KEYS = ["accessToken", "refreshToken", "clientId", "clientSecret", "mode"];
const LS_MODE = "patreon.mode";

const setupEl = document.getElementById("setup");
const appEl = document.getElementById("app");
const modeCreatorBtn = document.getElementById("modeCreatorBtn");
const modePatronBtn = document.getElementById("modePatronBtn");
const creatorSetup = document.getElementById("creatorSetup");
const patronSetup = document.getElementById("patronSetup");
const creatorTokenInput = document.getElementById("creatorTokenInput");
const creatorClientIdInput = document.getElementById("creatorClientIdInput");
const creatorClientSecretInput = document.getElementById("creatorClientSecretInput");
const creatorRefreshInput = document.getElementById("creatorRefreshInput");
const creatorConnectButton = document.getElementById("creatorConnectButton");
const patronClientIdInput = document.getElementById("patronClientIdInput");
const patronClientSecretInput = document.getElementById("patronClientSecretInput");
const patronConnectButton = document.getElementById("patronConnectButton");
const setupError = document.getElementById("setupError");
const headerAvatar = document.getElementById("headerAvatar");
const accountLabel = document.getElementById("accountLabel");
const refreshButton = document.getElementById("refreshButton");
const settingsWrap = document.getElementById("settingsWrap");
const settingsButton = document.getElementById("settingsButton");
const settingsMenu = document.getElementById("settingsMenu");
const settingsAccount = document.getElementById("settingsAccount");
const disconnectButton = document.getElementById("disconnectButton");
const tabsEl = document.getElementById("tabs");
const viewError = document.getElementById("viewError");
const contentEl = document.getElementById("content");

let auth = null; // { accessToken, refreshToken, clientId, clientSecret, mode }
let campaignId = null;
let campaignCurrency = "USD";
let currentTab = null;
let pagination = {}; // per-tab cursor

init();

async function init() {
  const saved = await readSecrets();
  if (saved && saved.accessToken) {
    auth = saved;
    enterApp();
  } else {
    showSetup();
  }
}

// MARK: - Secrets

async function readSecrets() {
  try {
    const values = {};
    for (const key of SECRET_KEYS) {
      values[key] = await window.swiftMaestro.getSecret(key);
    }
    return values;
  } catch (err) {
    console.error("readSecrets failed:", err);
    return null;
  }
}

async function writeSecret(key, value) {
  await window.swiftMaestro.setSecret(key, value || "");
}

// MARK: - Setup UI

function showSetup() {
  setupEl.classList.remove("hidden");
  appEl.classList.add("hidden");
  const mode = localStorage.getItem(LS_MODE) || "creator";
  selectMode(mode);
}

function selectMode(mode) {
  modeCreatorBtn.classList.toggle("active", mode === "creator");
  modePatronBtn.classList.toggle("active", mode === "patron");
  creatorSetup.classList.toggle("hidden", mode !== "creator");
  patronSetup.classList.toggle("hidden", mode !== "patron");
}

modeCreatorBtn.addEventListener("click", () => selectMode("creator"));
modePatronBtn.addEventListener("click", () => selectMode("patron"));

function showSetupError(message) {
  setupError.textContent = message;
  setupError.classList.remove("hidden");
}

// MARK: - Creator connect

creatorConnectButton.addEventListener("click", async () => {
  const token = creatorTokenInput.value.trim();
  if (!token) {
    showSetupError("The Creator's Access Token is required.");
    return;
  }
  creatorConnectButton.disabled = true;
  setupError.classList.add("hidden");
  auth = {
    accessToken: token,
    refreshToken: creatorRefreshInput.value.trim(),
    clientId: creatorClientIdInput.value.trim(),
    clientSecret: creatorClientSecretInput.value.trim(),
    mode: "creator",
  };
  try {
    const identity = await apiGET("/identity", {
      "include": "campaign",
      "fields[user]": "full_name,image_url",
      "fields[campaign]": "name",
    });
    const campaign = identity.data && identity.data.relationships
      && identity.data.relationships.campaign && identity.data.relationships.campaign.data;
    if (!campaign) {
      throw new Error("This token's account has no campaign. Use patron mode, or a token from a creator account.");
    }
    campaignId = String(campaign.id);
    await persistAuth();
    localStorage.setItem(LS_MODE, "creator");
    creatorTokenInput.value = "";
    creatorRefreshInput.value = "";
    creatorClientIdInput.value = "";
    creatorClientSecretInput.value = "";
    enterApp();
  } catch (err) {
    auth = null;
    campaignId = null;
    showSetupError(describeError(err));
  } finally {
    creatorConnectButton.disabled = false;
  }
});

// MARK: - Patron OAuth connect

patronConnectButton.addEventListener("click", async () => {
  const clientId = patronClientIdInput.value.trim();
  const clientSecret = patronClientSecretInput.value.trim();
  if (!clientId || !clientSecret) {
    showSetupError("Client ID and Client Secret are required.");
    return;
  }
  patronConnectButton.disabled = true;
  setupError.classList.add("hidden");
  try {
    const state = randomState();
    const params = new URLSearchParams({
      response_type: "code",
      client_id: clientId,
      redirect_uri: REDIRECT_URI,
      scope: "identity identity.memberships campaigns",
      state,
    });
    const callback = await window.swiftMaestro.startOAuth({
      authorizeURL: AUTHORIZE_URL + "?" + params.toString(),
      state,
      port: OAUTH_PORT,
      timeoutSeconds: 180,
    });
    if (!callback || !callback.code) {
      throw new Error("Patreon sign-in didn't return an authorization code.");
    }
    const tokens = await tokenRequest({
      grant_type: "authorization_code",
      code: callback.code,
      client_id: clientId,
      client_secret: clientSecret,
      redirect_uri: REDIRECT_URI,
    });
    auth = {
      accessToken: tokens.access_token,
      refreshToken: tokens.refresh_token || "",
      clientId,
      clientSecret,
      mode: "patron",
    };
    campaignId = null;
    await persistAuth();
    localStorage.setItem(LS_MODE, "patron");
    patronClientIdInput.value = "";
    patronClientSecretInput.value = "";
    enterApp();
  } catch (err) {
    auth = null;
    showSetupError(describeError(err));
  } finally {
    patronConnectButton.disabled = false;
  }
});

async function persistAuth() {
  await writeSecret("accessToken", auth.accessToken);
  await writeSecret("refreshToken", auth.refreshToken);
  await writeSecret("clientId", auth.clientId);
  await writeSecret("clientSecret", auth.clientSecret);
  await writeSecret("mode", auth.mode);
}

function randomState() {
  const bytes = new Uint8Array(16);
  crypto.getRandomValues(bytes);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

// MARK: - HTTP / token lifecycle

async function tokenRequest(fields) {
  const result = await window.swiftMaestro.fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      "User-Agent": USER_AGENT,
    },
    body: new URLSearchParams(fields).toString(),
  });
  let parsed = null;
  try { parsed = result.body ? JSON.parse(result.body) : null; } catch (_) { /* non-JSON */ }
  if (result.status < 200 || result.status >= 300 || !parsed || !parsed.access_token) {
    const detail = parsed && parsed.error_description ? parsed.error_description : `HTTP ${result.status}`;
    throw new Error("Token request failed: " + detail);
  }
  return parsed;
}

async function refreshAuth() {
  if (!auth || !auth.refreshToken || !auth.clientId || !auth.clientSecret) return false;
  try {
    const tokens = await tokenRequest({
      grant_type: "refresh_token",
      refresh_token: auth.refreshToken,
      client_id: auth.clientId,
      client_secret: auth.clientSecret,
    });
    auth.accessToken = tokens.access_token;
    auth.refreshToken = tokens.refresh_token || auth.refreshToken;
    await writeSecret("accessToken", auth.accessToken);
    await writeSecret("refreshToken", auth.refreshToken);
    return true;
  } catch (_) {
    return false;
  }
}

// JSON:API GET with 401-refresh and 429-retry handling (one retry each).
async function apiGET(path, params, retried) {
  const query = params ? "?" + new URLSearchParams(params).toString() : "";
  const result = await window.swiftMaestro.fetch(API_BASE + path + query, {
    method: "GET",
    headers: {
      "Authorization": "Bearer " + auth.accessToken,
      "User-Agent": USER_AGENT,
    },
  });

  if (result.status === 401 && !retried) {
    const refreshed = await refreshAuth();
    if (refreshed) return apiGET(path, params, true);
    throw new Error("Patreon token expired and couldn't be refreshed — reconnect.");
  }
  if (result.status === 429 && !retried) {
    let waitSeconds = 5;
    try {
      const body = JSON.parse(result.body || "{}");
      const retryAfter = body.errors && body.errors[0] && body.errors[0].retry_after_seconds;
      if (retryAfter) waitSeconds = Math.min(Number(retryAfter) || 5, 10);
    } catch (_) { /* keep default */ }
    await new Promise((resolve) => setTimeout(resolve, waitSeconds * 1000));
    return apiGET(path, params, true);
  }

  let parsed = null;
  try { parsed = result.body ? JSON.parse(result.body) : null; } catch (_) { /* non-JSON */ }
  if (result.status < 200 || result.status >= 300) {
    const detail = parsed && parsed.errors && parsed.errors[0]
      ? (parsed.errors[0].detail || parsed.errors[0].title)
      : null;
    throw new Error(detail || `Patreon API returned HTTP ${result.status}`);
  }
  return parsed;
}

// MARK: - App shell

function enterApp() {
  setupEl.classList.add("hidden");
  appEl.classList.remove("hidden");
  // Connected: disconnect lives in the settings menu, away from refresh.
  settingsWrap.classList.remove("hidden");
  settingsAccount.textContent = auth.mode === "creator"
    ? "Connected as Creator"
    : "Connected as Patron";
  tabsEl.innerHTML = "";
  pagination = {};
  const tabs = auth.mode === "creator"
    ? [["dashboard", "Dashboard"], ["members", "Members"], ["posts", "Posts"]]
    : [["memberships", "Memberships"]];
  for (const [id, label] of tabs) {
    const btn = document.createElement("button");
    btn.className = "tab";
    btn.id = "tab-" + id;
    btn.textContent = label;
    btn.addEventListener("click", () => showTab(id));
    tabsEl.appendChild(btn);
  }
  loadAccountLabel();
  showTab(tabs[0][0]);
}

async function loadAccountLabel() {
  try {
    const identity = await apiGET("/identity", {
      "fields[user]": "full_name,image_url",
    });
    const attrs = (identity.data && identity.data.attributes) || {};
    accountLabel.textContent = (attrs.full_name || "Patreon account")
      + (auth.mode === "creator" ? "  ·  Creator" : "  ·  Patron");
    if (attrs.image_url) {
      headerAvatar.src = attrs.image_url;
      headerAvatar.classList.remove("hidden");
    }
  } catch (err) {
    accountLabel.textContent = "Patreon";
    showError(describeError(err));
  }
}

refreshButton.addEventListener("click", () => {
  if (currentTab) showTab(currentTab);
});

settingsButton.addEventListener("click", (e) => {
  e.stopPropagation();
  settingsMenu.classList.toggle("hidden");
});

// Close the settings menu on any click elsewhere in the panel.
document.addEventListener("click", (e) => {
  if (!settingsMenu.classList.contains("hidden") && !settingsWrap.contains(e.target)) {
    settingsMenu.classList.add("hidden");
  }
});

disconnectButton.addEventListener("click", async () => {
  settingsMenu.classList.add("hidden");
  settingsWrap.classList.add("hidden");
  for (const key of SECRET_KEYS) {
    try { await writeSecret(key, ""); } catch (_) { /* best effort */ }
  }
  auth = null;
  campaignId = null;
  showSetup();
});

function showTab(id) {
  currentTab = id;
  pagination = {};
  for (const btn of tabsEl.querySelectorAll(".tab")) {
    btn.classList.toggle("active", btn.id === "tab-" + id);
  }
  hideError();
  contentEl.innerHTML = '<div class="empty-state">Loading…</div>';
  switch (id) {
    case "dashboard": loadDashboard(); break;
    case "members": loadMembers(true); break;
    case "posts": loadPosts(true); break;
    case "memberships": loadMemberships(); break;
  }
}

function showError(message) {
  viewError.textContent = message;
  viewError.classList.remove("hidden");
}
function hideError() {
  viewError.classList.add("hidden");
}

// MARK: - Dashboard

async function loadDashboard() {
  try {
    const data = await apiGET("/campaigns", {
      "include": "tiers",
      "fields[campaign]": "name,summary,patron_count,creation_name,pay_per_name,url,image_url,currency,is_monthly",
      "fields[tier]": "title,amount_cents,patron_count",
    });
    const campaigns = data.data || [];
    if (!campaigns.length) {
      contentEl.innerHTML = '<div class="empty-state">No campaigns on this account.</div>';
      return;
    }
    const campaign = campaigns.find((c) => String(c.id) === campaignId) || campaigns[0];
    campaignId = String(campaign.id);
    const attrs = campaign.attributes || {};
    campaignCurrency = attrs.currency || "USD";
    const tiers = (data.included || []).filter((i) => i.type === "tier");

    contentEl.innerHTML = `
      <div class="stat-grid">
        <div class="stat-card"><div class="stat-value">${attrs.patron_count ?? "—"}</div><div class="stat-label">Patrons</div></div>
        <div class="stat-card"><div class="stat-value">${tiers.length}</div><div class="stat-label">Tiers</div></div>
        <div class="stat-card"><div class="stat-value">${attrs.is_monthly ? "Monthly" : "Per " + escapeHTML(attrs.pay_per_name || "creation")}</div><div class="stat-label">Billing</div></div>
      </div>
      <div class="section-title">${escapeHTML(attrs.name || "Campaign")}</div>
      <p class="hint" style="color:var(--text-secondary)">${escapeHTML(attrs.summary || "")}</p>
      <div class="section-title">Tiers</div>
      ${tiers.map(renderTier).join("") || '<div class="empty-state">No published tiers.</div>'}`;
  } catch (err) {
    contentEl.innerHTML = "";
    showError(describeError(err));
  }
}

function renderTier(tier) {
  const attrs = tier.attributes || {};
  const price = attrs.amount_cents != null ? formatMoney(attrs.amount_cents) : "—";
  const count = attrs.patron_count != null ? `${attrs.patron_count} patrons` : "";
  return `<div class="tier-row">
    <span>${escapeHTML(attrs.title || "Tier")}</span>
    <span class="tier-count">${count}</span>
    <span class="tier-price">${price}</span>
  </div>`;
}

// MARK: - Members

async function loadMembers(reset) {
  try {
    const params = {
      "include": "currently_entitled_tiers",
      "fields[member]": "full_name,patron_status,currently_entitled_amount_cents,campaign_lifetime_support_cents,last_charge_date,last_charge_status,pledge_relationship_start",
      "fields[tier]": "title",
      "page[count]": "50",
    };
    if (!reset && pagination.members) params["page[cursor]"] = pagination.members;
    const data = await apiGET("/campaigns/" + campaignId + "/members", params);

    const tierTitles = {};
    for (const inc of data.included || []) {
      if (inc.type === "tier") tierTitles[inc.id] = (inc.attributes && inc.attributes.title) || "";
    }
    const members = data.data || [];
    pagination.members = data.meta && data.meta.pagination
      && data.meta.pagination.cursors && data.meta.pagination.cursors.next;

    if (reset) contentEl.innerHTML = "";
    document.querySelector(".load-more-wrap")?.remove();
    if (!members.length && reset) {
      contentEl.innerHTML = '<div class="empty-state">No members yet.</div>';
      return;
    }
    contentEl.insertAdjacentHTML("beforeend",
      members.map((m) => renderMember(m, tierTitles)).join(""));
    appendLoadMore("members", () => loadMembers(false));
  } catch (err) {
    if (reset) contentEl.innerHTML = "";
    showError(describeError(err));
  }
}

function renderMember(member, tierTitles) {
  const attrs = member.attributes || {};
  // Patreon's 2026 identity masking: hidden members arrive with null fields.
  const name = attrs.full_name || "Hidden member";
  const status = attrs.patron_status || "unknown";
  const tiers = member.relationships && member.relationships.currently_entitled_tiers
    ? (member.relationships.currently_entitled_tiers.data || []).map((t) => tierTitles[t.id]).filter(Boolean)
    : [];
  const amount = attrs.currently_entitled_amount_cents != null
    ? formatMoney(attrs.currently_entitled_amount_cents) : "Free";
  const lifetime = attrs.campaign_lifetime_support_cents != null
    ? formatMoney(attrs.campaign_lifetime_support_cents) + " lifetime" : "";
  const charge = attrs.last_charge_status
    ? `Last charge ${String(attrs.last_charge_status).toLowerCase()} ${formatDate(attrs.last_charge_date)}`
    : "";
  return `<div class="member-row">
    <div>
      <div class="member-name">${escapeHTML(name)}</div>
      <div class="member-meta">
        <span class="badge ${escapeAttr(status)}">${escapeHTML(status.replace(/_/g, " "))}</span>
        ${tiers.length ? " · " + escapeHTML(tiers.join(", ")) : ""}
        ${charge ? "<br>" + escapeHTML(charge) : ""}
      </div>
    </div>
    <div class="member-amount">
      <div class="amount">${escapeHTML(amount)}</div>
      <div class="member-meta">${escapeHTML(lifetime)}</div>
    </div>
  </div>`;
}

// MARK: - Posts

async function loadPosts(reset) {
  try {
    const params = {
      "fields[post]": "title,published_at,content,url,is_paid",
      "page[count]": "25",
    };
    if (!reset && pagination.posts) params["page[cursor]"] = pagination.posts;
    const data = await apiGET("/campaigns/" + campaignId + "/posts", params);

    const posts = data.data || [];
    pagination.posts = data.meta && data.meta.pagination
      && data.meta.pagination.cursors && data.meta.pagination.cursors.next;

    if (reset) contentEl.innerHTML = "";
    document.querySelector(".load-more-wrap")?.remove();
    if (!posts.length && reset) {
      contentEl.innerHTML = '<div class="empty-state">No posts yet.</div>';
      return;
    }
    contentEl.insertAdjacentHTML("beforeend", posts.map(renderPost).join(""));
    appendLoadMore("posts", () => loadPosts(false));
  } catch (err) {
    if (reset) contentEl.innerHTML = "";
    showError(describeError(err));
  }
}

function renderPost(post) {
  const attrs = post.attributes || {};
  const paid = !!attrs.is_paid;
  const snippet = stripHTML(attrs.content || "").slice(0, 220);
  return `<div class="post-row">
    <div class="post-title">${escapeHTML(attrs.title || "Untitled")}</div>
    <div class="post-meta">
      <span>${formatDate(attrs.published_at)}</span>
      <span class="badge ${paid ? "paid" : "free"}">${paid ? "patrons" : "public"}</span>
    </div>
    ${snippet ? `<div class="post-snippet">${escapeHTML(snippet)}${(attrs.content || "").length > 220 ? "…" : ""}</div>` : ""}
  </div>`;
}

// MARK: - Memberships (patron mode)

async function loadMemberships() {
  try {
    const data = await apiGET("/identity", {
      "include": "memberships.currently_entitled_tiers,memberships.campaign",
      "fields[user]": "full_name",
      "fields[member]": "patron_status,currently_entitled_amount_cents,last_charge_date,campaign_lifetime_support_cents",
      "fields[campaign]": "name,image_url,url",
      "fields[tier]": "title",
    });
    const included = data.included || [];
    const campaigns = {};
    const tiers = {};
    for (const inc of included) {
      if (inc.type === "campaign") campaigns[inc.id] = inc.attributes || {};
      if (inc.type === "tier") tiers[inc.id] = inc.attributes || {};
    }
    const memberships = included.filter((i) => i.type === "member");
    if (!memberships.length) {
      contentEl.innerHTML = '<div class="empty-state">No memberships found.<br>' +
        'Patreon only exposes memberships to clients approved for the identity.memberships scope.</div>';
      return;
    }
    contentEl.innerHTML = memberships.map((m) => renderMembership(m, campaigns, tiers)).join("");
  } catch (err) {
    contentEl.innerHTML = "";
    showError(describeError(err));
  }
}

function renderMembership(member, campaigns, tiers) {
  const attrs = member.attributes || {};
  const rel = member.relationships || {};
  const campaignRef = rel.campaign && rel.campaign.data;
  const campaign = campaignRef ? campaigns[campaignRef.id] || {} : {};
  const tierRefs = rel.currently_entitled_tiers ? rel.currently_entitled_tiers.data || [] : [];
  const tierNames = tierRefs.map((t) => (tiers[t.id] || {}).title).filter(Boolean);
  const amount = attrs.currently_entitled_amount_cents != null
    ? formatMoney(attrs.currently_entitled_amount_cents) : "Free";
  const status = attrs.patron_status || "member";
  return `<div class="membership-row">
    ${campaign.image_url ? `<img src="${escapeAttr(campaign.image_url)}" alt="">` : "<img alt=\"\">"}
    <div>
      <div class="membership-name">${escapeHTML(campaign.name || "Campaign")}</div>
      <div class="membership-meta">
        <span class="badge ${escapeAttr(status)}">${escapeHTML(status.replace(/_/g, " "))}</span>
        ${tierNames.length ? " · " + escapeHTML(tierNames.join(", ")) : ""}
      </div>
    </div>
    <div class="membership-amount">${escapeHTML(amount)}</div>
  </div>`;
}

// MARK: - Shared UI helpers

function appendLoadMore(key, loader) {
  if (!pagination[key]) return;
  contentEl.insertAdjacentHTML("beforeend",
    '<div class="load-more-wrap"><button>Load more</button></div>');
  contentEl.querySelector(".load-more-wrap button").addEventListener("click", loader);
}

function formatMoney(cents) {
  const amount = (cents / 100).toFixed(2).replace(/\.00$/, "");
  try {
    return new Intl.NumberFormat(undefined, {
      style: "currency", currency: campaignCurrency,
    }).format(cents / 100);
  } catch (_) {
    return campaignCurrency + " " + amount;
  }
}

function formatDate(iso) {
  if (!iso) return "";
  const date = new Date(iso);
  return isNaN(date) ? "" : date.toLocaleDateString();
}

function stripHTML(html) {
  const div = document.createElement("div");
  div.innerHTML = html;
  return (div.textContent || "").replace(/\s+/g, " ").trim();
}

function describeError(err) {
  return err && err.message ? err.message : String(err);
}

function escapeHTML(text) {
  const div = document.createElement("div");
  div.textContent = text ?? "";
  return div.innerHTML;
}

function escapeAttr(text) {
  return (text ?? "").replace(/"/g, "&quot;");
}
