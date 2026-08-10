// Bluesky plugin for SwiftMaestro.
//
// Two modes:
//   1. Anonymous — public browsing via https://api.bsky.app (no auth):
//      search posts/people, view profiles, author feeds, threads.
//   2. Signed in — handle + app password via com.atproto.server.createSession.
//      Unlocks home timeline, posting, like/repost. Reads then go through the
//      user's PDS with the access token (which also enables viewer state).
//
// Uses window.swiftMaestro.fetch (native URLSession proxy — sidesteps CORS)
// and window.swiftMaestro.getSecret/setSecret (Keychain, namespaced
// plugin.bluesky.*). Session tokens never touch localStorage. The native
// MaestroTools Bluesky tools read these same Keychain entries, so signing in
// here also enables agent tools (post_bluesky etc.).

const PUBLIC_API = "https://api.bsky.app";
const DEFAULT_PDS = "https://bsky.social";
const REFRESH_INTERVAL_MS = 60_000;
const FEED_PAGE_SIZE = 30;

// Secrets (Keychain): accessJwt, refreshJwt, did, handle, pds
const SECRET_KEYS = ["accessJwt", "refreshJwt", "did", "handle", "pds"];
const LS_HANDLE = "bluesky.handle";
const LS_PDS = "bluesky.pds";

const setupEl = document.getElementById("setup");
const appEl = document.getElementById("app");
const handleInput = document.getElementById("handleInput");
const passwordInput = document.getElementById("passwordInput");
const pdsInput = document.getElementById("pdsInput");
const connectButton = document.getElementById("connectButton");
const anonButton = document.getElementById("anonButton");
const setupError = document.getElementById("setupError");
const backButton = document.getElementById("backButton");
const headerAvatar = document.getElementById("headerAvatar");
const accountLabel = document.getElementById("accountLabel");
const refreshButton = document.getElementById("refreshButton");
const signInButton = document.getElementById("signInButton");
const settingsWrap = document.getElementById("settingsWrap");
const settingsButton = document.getElementById("settingsButton");
const settingsMenu = document.getElementById("settingsMenu");
const settingsAccount = document.getElementById("settingsAccount");
const signOutButton = document.getElementById("signOutButton");
const tabTimeline = document.getElementById("tabTimeline");
const tabSearch = document.getElementById("tabSearch");
const composeBox = document.getElementById("composeBox");
const composeText = document.getElementById("composeText");
const composeCount = document.getElementById("composeCount");
const postButton = document.getElementById("postButton");
const searchBox = document.getElementById("searchBox");
const searchInput = document.getElementById("searchInput");
const searchType = document.getElementById("searchType");
const searchSort = document.getElementById("searchSort");
const searchButton = document.getElementById("searchButton");
const viewError = document.getElementById("viewError");
const feedEl = document.getElementById("feed");

let session = null; // { pds, handle, did, accessJwt, refreshJwt }
let refreshTimer = null;
let viewStack = []; // stack of view descriptors
let currentPosts = []; // posts rendered in the current feed, index-aligned

init();

async function init() {
  handleInput.value = localStorage.getItem(LS_HANDLE) || "";
  pdsInput.value = localStorage.getItem(LS_PDS) || "";

  const saved = await readSessionSecrets();
  if (saved) {
    session = saved;
    const ok = await validateSession();
    if (!ok) {
      const refreshed = await refreshSession();
      if (!refreshed) {
        await clearSessionSecrets();
        session = null;
      }
    }
  }
  enterApp();
}

// MARK: - Session secrets

async function readSessionSecrets() {
  try {
    const values = {};
    for (const key of SECRET_KEYS) {
      values[key] = await window.swiftMaestro.getSecret(key);
    }
    if (values.accessJwt && values.refreshJwt && values.did && values.handle) {
      return {
        pds: values.pds || DEFAULT_PDS,
        handle: values.handle,
        did: values.did,
        accessJwt: values.accessJwt,
        refreshJwt: values.refreshJwt,
      };
    }
  } catch (err) {
    console.error("readSessionSecrets failed:", err);
  }
  return null;
}

async function writeSessionSecrets() {
  await window.swiftMaestro.setSecret("accessJwt", session.accessJwt);
  await window.swiftMaestro.setSecret("refreshJwt", session.refreshJwt);
  await window.swiftMaestro.setSecret("did", session.did);
  await window.swiftMaestro.setSecret("handle", session.handle);
  await window.swiftMaestro.setSecret("pds", session.pds);
}

async function clearSessionSecrets() {
  for (const key of SECRET_KEYS) {
    try { await window.swiftMaestro.setSecret(key, ""); } catch (_) { /* best effort */ }
  }
}

// MARK: - XRPC helpers

function apiHost() {
  return session ? session.pds : PUBLIC_API;
}

async function xrpc(path, params, useAuth) {
  const query = params ? "?" + new URLSearchParams(params).toString() : "";
  const headers = {};
  if (useAuth && session) headers["Authorization"] = "Bearer " + session.accessJwt;
  const result = await window.swiftMaestro.fetch(apiHost() + "/xrpc/" + path + query, {
    method: "GET",
    headers,
  });
  return parseXrpc(result, path, params, useAuth, "GET", null);
}

async function xrpcPost(path, body, useAuth) {
  const headers = { "Content-Type": "application/json" };
  if (useAuth && session) headers["Authorization"] = "Bearer " + session.accessJwt;
  const result = await window.swiftMaestro.fetch(apiHost() + "/xrpc/" + path, {
    method: "POST",
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  return parseXrpc(result, path, null, useAuth, "POST", body);
}

// Handles token expiry: refreshes once and retries the original call.
async function parseXrpc(result, path, params, useAuth, method, body) {
  let parsed = null;
  try { parsed = result.body ? JSON.parse(result.body) : null; } catch (_) { /* non-JSON */ }

  if (result.status >= 200 && result.status < 300) return parsed;

  const errName = (parsed && parsed.error) || "";
  if (useAuth && session && errName === "ExpiredToken") {
    const refreshed = await refreshSession();
    if (refreshed) {
      if (method === "GET") return xrpc(path, params, useAuth);
      return xrpcPost(path, body, useAuth);
    }
    await signOut();
    throw new Error("Session expired — sign in again.");
  }
  const message = (parsed && parsed.message) || errName || `HTTP ${result.status}`;
  throw new Error(message);
}

// MARK: - Auth

connectButton.addEventListener("click", async () => {
  const handle = handleInput.value.trim().replace(/^@/, "");
  const password = passwordInput.value.trim();
  const pds = normalizeURL(pdsInput.value.trim()) || DEFAULT_PDS;
  if (!handle || !password) {
    showSetupError("Handle and app password are required.");
    return;
  }
  connectButton.disabled = true;
  setupError.classList.add("hidden");
  try {
    const headers = { "Content-Type": "application/json" };
    const result = await window.swiftMaestro.fetch(pds + "/xrpc/com.atproto.server.createSession", {
      method: "POST",
      headers,
      body: JSON.stringify({ identifier: handle, password }),
    });
    const parsed = result.body ? JSON.parse(result.body) : null;
    if (result.status < 200 || result.status >= 300 || !parsed || !parsed.accessJwt) {
      throw new Error((parsed && parsed.message) || `Sign-in failed (HTTP ${result.status})`);
    }
    session = {
      pds,
      handle: parsed.handle || handle,
      did: parsed.did,
      accessJwt: parsed.accessJwt,
      refreshJwt: parsed.refreshJwt,
    };
    await writeSessionSecrets();
    localStorage.setItem(LS_HANDLE, session.handle);
    localStorage.setItem(LS_PDS, pds === DEFAULT_PDS ? "" : pds);
    passwordInput.value = "";
    enterApp();
  } catch (err) {
    showSetupError(describeError(err));
  } finally {
    connectButton.disabled = false;
  }
});

anonButton.addEventListener("click", () => {
  session = null;
  enterApp();
});

async function validateSession() {
  try {
    await xrpc("app.bsky.feed.getTimeline", { limit: "1" }, true);
    return true;
  } catch (err) {
    return err && err.message !== "Session expired — sign in again." ? false : false;
  }
}

async function refreshSession() {
  if (!session || !session.refreshJwt) return false;
  try {
    const result = await window.swiftMaestro.fetch(
      session.pds + "/xrpc/com.atproto.server.refreshSession",
      { method: "POST", headers: { Authorization: "Bearer " + session.refreshJwt } }
    );
    const parsed = result.body ? JSON.parse(result.body) : null;
    if (result.status < 200 || result.status >= 300 || !parsed || !parsed.accessJwt) return false;
    session.accessJwt = parsed.accessJwt;
    session.refreshJwt = parsed.refreshJwt || session.refreshJwt;
    session.did = parsed.did || session.did;
    session.handle = parsed.handle || session.handle;
    await writeSessionSecrets();
    return true;
  } catch (_) {
    return false;
  }
}

signInButton.addEventListener("click", () => showSetup());

settingsButton.addEventListener("click", (e) => {
  e.stopPropagation();
  settingsMenu.classList.toggle("hidden");
});

signOutButton.addEventListener("click", async () => {
  settingsMenu.classList.add("hidden");
  await signOut();
});

// Close the settings menu on any click elsewhere in the panel.
document.addEventListener("click", (e) => {
  if (!settingsMenu.classList.contains("hidden") && !settingsWrap.contains(e.target)) {
    settingsMenu.classList.add("hidden");
  }
});

async function signOut() {
  if (session && session.refreshJwt) {
    try {
      await window.swiftMaestro.fetch(session.pds + "/xrpc/com.atproto.server.deleteSession", {
        method: "POST",
        headers: { Authorization: "Bearer " + session.refreshJwt },
      });
    } catch (_) { /* best effort */ }
  }
  await clearSessionSecrets();
  session = null;
  if (refreshTimer) clearInterval(refreshTimer);
  showSetup();
}

function showSetup() {
  handleInput.value = localStorage.getItem(LS_HANDLE) || "";
  pdsInput.value = localStorage.getItem(LS_PDS) || "";
  setupEl.classList.remove("hidden");
  appEl.classList.add("hidden");
}

function showSetupError(message) {
  setupError.textContent = message;
  setupError.classList.remove("hidden");
}

// MARK: - App shell / navigation

function enterApp() {
  setupEl.classList.add("hidden");
  appEl.classList.remove("hidden");
  accountLabel.textContent = session ? "@" + session.handle : "Browsing anonymously";
  headerAvatar.classList.add("hidden");
  // Signed in: account controls live in the settings menu, away from the
  // refresh button (an adjacent sign-out icon was an accidental-click trap).
  // Signed out: a prominent Sign in button is the primary action instead.
  settingsWrap.classList.toggle("hidden", !session);
  signInButton.classList.toggle("hidden", !!session);
  if (session) {
    settingsAccount.textContent = "Signed in as @" + session.handle;
    loadOwnProfile();
  }
  viewStack = [];
  navigate({ type: "timeline" });
  if (refreshTimer) clearInterval(refreshTimer);
  refreshTimer = setInterval(() => {
    const top = viewStack[viewStack.length - 1];
    if (top && top.type === "timeline" && session) loadView(top, false);
  }, REFRESH_INTERVAL_MS);
}

async function loadOwnProfile() {
  try {
    const profile = await xrpc("app.bsky.actor.getProfile", { actor: session.did }, true);
    if (profile && profile.avatar) {
      headerAvatar.src = profile.avatar;
      headerAvatar.classList.remove("hidden");
    }
    if (profile && profile.displayName) {
      accountLabel.textContent = profile.displayName + "  @" + session.handle;
    }
  } catch (_) { /* cosmetic only */ }
}

function navigate(view) {
  viewStack.push(view);
  backButton.classList.toggle("hidden", viewStack.length <= 1);
  loadView(view, true);
}

backButton.addEventListener("click", () => {
  if (viewStack.length > 1) {
    viewStack.pop();
    const view = viewStack[viewStack.length - 1];
    backButton.classList.toggle("hidden", viewStack.length <= 1);
    loadView(view, true);
  }
});

tabTimeline.addEventListener("click", () => switchTab("timeline"));
tabSearch.addEventListener("click", () => switchTab("search"));

function switchTab(kind) {
  tabTimeline.classList.toggle("active", kind === "timeline");
  tabSearch.classList.toggle("active", kind === "search");
  const base = viewStack[0];
  if (!base || base.type !== kind) {
    viewStack = [{ type: kind }];
    backButton.classList.add("hidden");
    loadView(viewStack[0], true);
  } else {
    viewStack = [base];
    backButton.classList.add("hidden");
    loadView(base, true);
  }
}

refreshButton.addEventListener("click", () => {
  const top = viewStack[viewStack.length - 1];
  if (top) loadView(top, true);
});

async function loadView(view, reset) {
  hideError();
  composeBox.classList.toggle("hidden", !(session && view.type === "timeline"));
  searchBox.classList.toggle("hidden", view.type !== "search");
  tabTimeline.classList.toggle("active", viewStack[0] && viewStack[0].type === "timeline");
  tabSearch.classList.toggle("active", viewStack[0] && viewStack[0].type === "search");
  if (reset) {
    feedEl.innerHTML = '<div class="empty-state">Loading…</div>';
    view.cursor = null;
  }
  try {
    switch (view.type) {
      case "timeline": await loadTimeline(view, reset); break;
      case "search": await loadSearch(view, reset); break;
      case "profile": await loadProfile(view, reset); break;
      case "thread": await loadThread(view, reset); break;
    }
  } catch (err) {
    if (reset) feedEl.innerHTML = "";
    showError(describeError(err));
  }
}

function showError(message) {
  viewError.textContent = message;
  viewError.classList.remove("hidden");
}
function hideError() {
  viewError.classList.add("hidden");
}

// MARK: - Timeline

async function loadTimeline(view, reset) {
  if (!session) {
    feedEl.innerHTML = '<div class="empty-state">Sign in to see your home timeline.<br>' +
      'Search still works without an account.</div>';
    return;
  }
  const params = { limit: String(FEED_PAGE_SIZE) };
  if (!reset && view.cursor) params.cursor = view.cursor;
  const data = await xrpc("app.bsky.feed.getTimeline", params, true);
  const items = (data && data.feed) || [];
  view.cursor = data && data.cursor;
  if (reset) currentPosts = [];
  renderFeedItems(items, reset);
}

// MARK: - Search

searchButton.addEventListener("click", () => {
  const view = { type: "search", query: searchInput.value.trim(), kind: searchType.value, sort: searchSort.value };
  viewStack = [view];
  backButton.classList.add("hidden");
  loadView(view, true);
});

searchInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") searchButton.click();
});

async function loadSearch(view, reset) {
  if (!view.query) {
    feedEl.innerHTML = '<div class="empty-state">Search public posts and people.</div>';
    return;
  }
  if (view.kind === "people") {
    const data = await xrpc("app.bsky.actor.searchActors",
      { q: view.query, limit: String(FEED_PAGE_SIZE) }, !!session);
    currentPosts = [];
    renderPeople((data && data.actors) || [], reset);
    return;
  }
  const params = { q: view.query, limit: String(FEED_PAGE_SIZE), sort: view.sort === "top" ? "top" : "latest" };
  if (!reset && view.cursor) params.cursor = view.cursor;
  const data = await xrpc("app.bsky.feed.searchPosts", params, !!session);
  const posts = (data && data.posts) || [];
  view.cursor = data && data.cursor;
  if (reset) currentPosts = [];
  renderFeedItems(posts.map((post) => ({ post })), reset);
}

function renderPeople(actors, reset) {
  if (reset) feedEl.innerHTML = "";
  if (!actors.length && reset) {
    feedEl.innerHTML = '<div class="empty-state">No people found.</div>';
    return;
  }
  feedEl.insertAdjacentHTML("beforeend", actors.map(renderPersonRow).join(""));
}

function renderPersonRow(actor) {
  return `
    <div class="post">
      <img class="avatar" src="${escapeAttr(actor.avatar || "")}" loading="lazy"
           data-profile="${escapeAttr(actor.did)}">
      <div class="post-body">
        <div class="post-header">
          <span class="display-name" data-profile="${escapeAttr(actor.did)}">${escapeHTML(actor.displayName || actor.handle)}</span>
          <span class="handle">@${escapeHTML(actor.handle)}</span>
        </div>
        <div class="post-text">${escapeHTML(actor.description || "")}</div>
      </div>
    </div>`;
}

// MARK: - Profile

async function loadProfile(view, reset) {
  const actor = view.actor;
  const authed = !!session;
  const profile = await xrpc("app.bsky.actor.getProfile", { actor }, authed);
  const params = { actor, limit: String(FEED_PAGE_SIZE), filter: "posts_no_replies" };
  if (!reset && view.cursor) params.cursor = view.cursor;
  const feed = await xrpc("app.bsky.feed.getAuthorFeed", params, authed);
  const items = (feed && feed.feed) || [];
  view.cursor = feed && feed.cursor;
  if (reset) {
    currentPosts = [];
    feedEl.innerHTML = renderProfileHead(profile);
  }
  renderFeedItems(items, false);
}

function renderProfileHead(profile) {
  return `
    <div class="profile-head">
      <img src="${escapeAttr(profile.avatar || "")}" alt="">
      <div>
        <div class="profile-name">${escapeHTML(profile.displayName || profile.handle)}</div>
        <div class="handle">@${escapeHTML(profile.handle)}</div>
        <div class="profile-bio">${escapeHTML(profile.description || "")}</div>
        <div class="profile-counts">
          <span>${profile.followersCount ?? 0} followers</span>
          <span>${profile.followsCount ?? 0} following</span>
          <span>${profile.postsCount ?? 0} posts</span>
        </div>
      </div>
    </div>`;
}

// MARK: - Thread

async function loadThread(view, reset) {
  const data = await xrpc("app.bsky.feed.getPostThread",
    { uri: view.uri, depth: "6" }, !!session);
  currentPosts = [];
  feedEl.innerHTML = "";
  if (!data || !data.thread || !data.thread.post) {
    feedEl.innerHTML = '<div class="empty-state">Thread not found.</div>';
    return;
  }
  const chain = [];
  let node = data.thread;
  while (node) {
    if (node.post) chain.unshift(node);
    node = node.parent;
  }
  const main = chain.pop();
  for (const ancestor of chain) {
    renderPostInto(ancestor.post, { depth: 0, faded: true });
  }
  renderPostInto(main.post, { depth: 0 });
  const replies = (main.replies || []).filter((r) => r.post);
  for (const reply of replies) renderReplyTree(reply, 1);
}

function renderReplyTree(node, depth) {
  renderPostInto(node.post, { depth: Math.min(depth, 4) });
  const replies = (node.replies || []).filter((r) => r.post);
  for (const reply of replies) renderReplyTree(reply, depth + 1);
}

// MARK: - Feed rendering

function renderFeedItems(items, reset) {
  if (reset) feedEl.innerHTML = "";
  if (!items.length) {
    if (reset) feedEl.innerHTML = '<div class="empty-state">No posts yet.</div>';
    return;
  }
  for (const item of items) {
    const reason = item.reason && item.reason.$type === "app.bsky.feed.defs#reasonRepost"
      ? item.reason.by : null;
    renderPostInto(item.post, { reasonBy: reason });
  }
  const top = viewStack[viewStack.length - 1];
  if (top && top.cursor) {
    feedEl.insertAdjacentHTML("beforeend",
      '<div class="empty-state"><button id="loadMoreButton" class="secondary">Load more</button></div>');
    document.getElementById("loadMoreButton").addEventListener("click", function () {
      this.closest(".empty-state").remove();
      loadView(top, false);
    });
  }
}

function renderPostInto(post, options) {
  const opts = options || {};
  currentPosts.push(post);
  const idx = currentPosts.length - 1;
  const depthPad = opts.depth ? ` style="margin-left:${opts.depth * 18}px"` : "";
  const reasonLine = opts.reasonBy
    ? `<div class="handle" style="padding:6px 14px 0"${depthPad}>⟲ ${escapeHTML(opts.reasonBy.displayName || opts.reasonBy.handle)} reposted</div>`
    : "";
  feedEl.insertAdjacentHTML("beforeend", reasonLine + renderPost(post, idx, opts));
}

function renderPost(post, idx, opts) {
  const author = post.author || {};
  const record = post.record || {};
  const time = formatTime(record.createdAt || post.indexedAt);
  const viewer = post.viewer || {};
  const liked = !!viewer.like;
  const reposted = !!viewer.repost;
  const actions = session
    ? `<span class="action ${liked ? "active" : ""}" data-like="${idx}">♥ ${post.likeCount ?? 0}</span>
       <span class="action ${reposted ? "active" : ""}" data-repost="${idx}">⟲ ${post.repostCount ?? 0}</span>`
    : `<span>♥ ${post.likeCount ?? 0}</span><span>⟲ ${post.repostCount ?? 0}</span>`;
  return `
    <div class="post"${opts.faded ? ' style="opacity:0.65"' : ""}>
      <img class="avatar" src="${escapeAttr(author.avatar || "")}" loading="lazy"
           data-profile="${escapeAttr(author.did || "")}">
      <div class="post-body">
        <div class="post-header">
          <span class="display-name" data-profile="${escapeAttr(author.did || "")}">${escapeHTML(author.displayName || author.handle || "")}</span>
          <span class="handle">@${escapeHTML(author.handle || "")}</span>
          <span class="time">${time}</span>
        </div>
        <div class="post-text">${renderFacetedText(record)}</div>
        ${renderEmbed(post.embed)}
        <div class="post-stats">
          <span class="action" data-thread="${idx}">↩ ${post.replyCount ?? 0}</span>
          ${actions}
          <span>❝ ${post.quoteCount ?? 0}</span>
        </div>
      </div>
    </div>`;
}

// Renders post text with link/mention/tag facets. Facet offsets are UTF-8
// byte offsets, so slice on encoded bytes rather than JS string indices.
function renderFacetedText(record) {
  const text = record.text || "";
  const facets = record.facets || [];
  if (!facets.length) return escapeHTML(text);

  const encoder = new TextEncoder();
  const decoder = new TextDecoder();
  const bytes = encoder.encode(text);

  const spans = [];
  let cursor = 0;
  const sorted = facets
    .filter((f) => f.index && f.index.byteStart >= 0 && f.index.byteEnd <= bytes.length)
    .sort((a, b) => a.index.byteStart - b.index.byteStart);

  for (const facet of sorted) {
    if (facet.index.byteStart < cursor) continue; // skip overlaps
    if (facet.index.byteStart > cursor) {
      spans.push(escapeHTML(decoder.decode(bytes.slice(cursor, facet.index.byteStart))));
    }
    const slice = escapeHTML(decoder.decode(bytes.slice(facet.index.byteStart, facet.index.byteEnd)));
    const feature = (facet.features || [])[0] || {};
    if (feature.$type === "app.bsky.richtext.facet#link" && feature.uri) {
      spans.push(`<span class="link" title="${escapeAttr(feature.uri)}">${slice}</span>`);
    } else if (feature.$type === "app.bsky.richtext.facet#mention") {
      spans.push(`<span class="link">${slice}</span>`);
    } else if (feature.$type === "app.bsky.richtext.facet#tag") {
      spans.push(`<span class="link">${slice}</span>`);
    } else {
      spans.push(slice);
    }
    cursor = facet.index.byteEnd;
  }
  if (cursor < bytes.length) spans.push(escapeHTML(decoder.decode(bytes.slice(cursor))));
  return spans.join("");
}

function renderEmbed(embed) {
  if (!embed || !embed.$type) return "";
  switch (embed.$type) {
    case "app.bsky.embed.images#view":
      return '<div class="post-embed">' + (embed.images || []).map((img) =>
        `<img class="embed-image" src="${escapeAttr(img.thumb || img.fullsize)}" alt="${escapeAttr(img.alt || "")}" loading="lazy">`
      ).join("") + "</div>";
    case "app.bsky.embed.external#view": {
      const ext = embed.external || {};
      return `<div class="embed-card"><span class="card-title">${escapeHTML(ext.title || ext.uri || "")}</span>${escapeHTML(ext.description || "")}</div>`;
    }
    case "app.bsky.embed.record#view": {
      const rec = embed.record || {};
      const author = rec.author || {};
      const value = rec.value || {};
      if (!rec.author) return '<div class="embed-quote">Post unavailable</div>';
      return `<div class="embed-quote"><span class="quote-author">${escapeHTML(author.displayName || author.handle || "")}</span>${escapeHTML(value.text || "")}</div>`;
    }
    case "app.bsky.embed.recordWithMedia#view": {
      let html = "";
      const media = embed.media || {};
      if (media.$type === "app.bsky.embed.images#view") {
        html += renderEmbed(media);
      } else if (media.$type === "app.bsky.embed.external#view") {
        html += renderEmbed(media);
      }
      if (embed.record) html += renderEmbed({ $type: "app.bsky.embed.record#view", record: embed.record });
      return html;
    }
    default:
      return "";
  }
}

// MARK: - Feed interactions (delegated)

feedEl.addEventListener("click", async (e) => {
  const profileTarget = e.target.closest("[data-profile]");
  if (profileTarget && profileTarget.dataset.profile) {
    navigate({ type: "profile", actor: profileTarget.dataset.profile });
    return;
  }
  const threadTarget = e.target.closest("[data-thread]");
  if (threadTarget) {
    const post = currentPosts[Number(threadTarget.dataset.thread)];
    if (post) navigate({ type: "thread", uri: post.uri });
    return;
  }
  const likeTarget = e.target.closest("[data-like]");
  if (likeTarget && session) {
    await toggleRecord(likeTarget, "app.bsky.feed.like", "like");
    return;
  }
  const repostTarget = e.target.closest("[data-repost]");
  if (repostTarget && session) {
    await toggleRecord(repostTarget, "app.bsky.feed.repost", "repost");
  }
});

async function toggleRecord(el, collection, field) {
  const post = currentPosts[Number(el.dataset[field])];
  if (!post) return;
  el.style.opacity = "0.5";
  try {
    post.viewer = post.viewer || {};
    const existing = post.viewer[field];
    if (existing) {
      await xrpcPost("com.atproto.repo.deleteRecord", {
        repo: session.did,
        collection,
        rkey: existing.split("/").pop(),
      }, true);
      post.viewer[field] = null;
      post[field + "Count"] = Math.max((post[field + "Count"] ?? 1) - 1, 0);
    } else {
      const result = await xrpcPost("com.atproto.repo.createRecord", {
        repo: session.did,
        collection,
        record: {
          $type: collection,
          subject: { uri: post.uri, cid: post.cid },
          createdAt: new Date().toISOString(),
        },
      }, true);
      post.viewer[field] = result && result.uri;
      post[field + "Count"] = (post[field + "Count"] ?? 0) + 1;
    }
    const active = !!post.viewer[field];
    el.classList.toggle("active", active);
    el.textContent = (field === "like" ? "♥ " : "⟲ ") + (post[field + "Count"] ?? 0);
  } catch (err) {
    showError(describeError(err));
  } finally {
    el.style.opacity = "";
  }
}

// MARK: - Compose

composeText.addEventListener("input", () => {
  const remaining = 300 - graphemeLength(composeText.value);
  composeCount.textContent = String(remaining);
  composeCount.style.color = remaining < 0 ? "var(--error)" : "";
});

postButton.addEventListener("click", async () => {
  const text = composeText.value.trim();
  if (!text || graphemeLength(text) > 300 || !session) return;
  postButton.disabled = true;
  try {
    const record = {
      $type: "app.bsky.feed.post",
      text,
      createdAt: new Date().toISOString(),
    };
    const facets = detectLinkFacets(text);
    if (facets.length) record.facets = facets;
    await xrpcPost("com.atproto.repo.createRecord", {
      repo: session.did,
      collection: "app.bsky.feed.post",
      record,
    }, true);
    composeText.value = "";
    composeCount.textContent = "300";
    const top = viewStack[viewStack.length - 1];
    if (top && top.type === "timeline") loadView(top, true);
  } catch (err) {
    showError("Post failed: " + describeError(err));
  } finally {
    postButton.disabled = false;
  }
});

// Builds link facets (byte offsets) so URLs in composed posts are clickable.
function detectLinkFacets(text) {
  const encoder = new TextEncoder();
  const facets = [];
  const urlRe = /https?:\/\/[^\s)>\]]+/g;
  let match;
  while ((match = urlRe.exec(text)) !== null) {
    const before = encoder.encode(text.slice(0, match.index));
    const slice = encoder.encode(match[0]);
    facets.push({
      index: { byteStart: before.length, byteEnd: before.length + slice.length },
      features: [{ $type: "app.bsky.richtext.facet#link", uri: match[0] }],
    });
  }
  return facets;
}

function graphemeLength(text) {
  if (typeof Intl !== "undefined" && Intl.Segmenter) {
    return Array.from(new Intl.Segmenter().segment(text)).length;
  }
  return [...text].length;
}

// MARK: - Utilities

function normalizeURL(value) {
  if (!value) return null;
  let url = value;
  if (!/^https?:\/\//i.test(url)) url = "https://" + url;
  return url.replace(/\/+$/, "");
}

function describeError(err) {
  return err && err.message ? err.message : String(err);
}

function formatTime(iso) {
  const date = new Date(iso);
  if (isNaN(date)) return "";
  const diffMs = Date.now() - date.getTime();
  const diffMin = Math.round(diffMs / 60000);
  if (diffMin < 1) return "now";
  if (diffMin < 60) return diffMin + "m";
  const diffHr = Math.round(diffMin / 60);
  if (diffHr < 24) return diffHr + "h";
  const diffDay = Math.round(diffHr / 24);
  if (diffDay < 7) return diffDay + "d";
  return date.toLocaleDateString();
}

function escapeHTML(text) {
  const div = document.createElement("div");
  div.textContent = text ?? "";
  return div.innerHTML;
}

function escapeAttr(text) {
  return (text ?? "").replace(/"/g, "&quot;");
}
