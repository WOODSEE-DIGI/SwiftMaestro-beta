# SwiftBrowser Plugins Guide

SwiftBrowser plugins are small, self-contained web apps that add custom behavior to SwiftMaestro's built-in browser. They include sidebar panels, toolbar-button extensions, and content scripts. They live outside the app bundle, so they survive SwiftMaestro updates and can be created by asking Maestro or by hand.

---

## Where plugins live

Each plugin is a folder under:

```
~/Library/Application Support/SwiftMaestro/BrowserExtensions/<id>/
```

Inside the folder:

```
<id>/
  manifest.json   <- required
  index.html      <- entry point (or popup page)
  content.js      <- optional content script
  styles.css      <- optional styles
  _storage/       <- created automatically for the storage capability
```

Because this directory is in Application Support, plugins are not deleted when you update or reinstall SwiftMaestro.

---

## How to install a plugin

### Option 1: Ask Maestro (recommended)

In chat, describe what you want:

> "Add a toolbar button that downloads YouTube videos"

Maestro will call `install_browser_extension` with a manifest and asset files. The plugin appears immediately in SwiftBrowser.

### Option 2: Install by hand

1. Create a folder under `~/Library/Application Support/SwiftMaestro/BrowserExtensions/`
2. Add a `manifest.json` file (see format below)
3. Add the HTML/JS/CSS files referenced by the manifest
4. Click **Rescan** in Settings → Plugins, or restart SwiftMaestro

---

## Manifest format (`manifest.json`)

```json
{
  "id": "com.example.youtube-downloader",
  "name": "YouTube Downloader",
  "version": "1.0.0",
  "icon": "arrow.down.circle",
  "entry": "popup.html",
  "type": "browser-action",
  "capabilities": ["tabs", "activeTab", "downloads"],
  "host": {
    "toolbar": {
      "icon": "arrow.down.circle",
      "label": "Download",
      "tooltip": "Download the current YouTube video"
    }
  },
  "content_scripts": [
    {
      "matches": ["*://*.youtube.com/*"],
      "js": ["content.js"],
      "css": ["styles.css"],
      "run_at": "document_idle"
    }
  ]
}
```

### Field reference

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Reverse-domain identifier, e.g. `com.example.name`. Used as the folder name. |
| `name` | yes | Human-readable name shown in Settings. |
| `version` | yes | Version string, e.g. `1.0.0`. |
| `icon` | yes | SF Symbol name used in the sidebar or toolbar. |
| `entry` | yes | Main HTML file. For `browser-action` this is the popup; for `panel` this is the sidebar page. |
| `type` | yes | `panel`, `browser-action`, or `content-script`. |
| `capabilities` | yes | Array of capabilities the extension is allowed to use. See below. |
| `host.toolbar` | no | Adds a toolbar button in SwiftBrowser. Only for `browser-action`. |
| `content_scripts` | no | Scripts/styles injected into matching web pages. |

### Extension types

- **`panel`** — Opens as a workspace panel (sidebar icon), like the built-in plugins.
- **`browser-action`** — Adds a button to the SwiftBrowser toolbar. Clicking it opens `entry` as a popover.
- **`content-script`** — Injected into web pages whose URLs match `content_scripts[].matches`. Has no visible UI unless you also declare a toolbar.

### Content script `matches` patterns

Patterns are glob-style:

| Pattern | Matches |
|---------|---------|
| `*://*.youtube.com/*` | Any YouTube page on any scheme. |
| `https://example.com/watch*` | `https://example.com/watch` plus any path/query suffix. |
| `*://example.com/*` | Any page on `example.com`. |

---

## Capabilities

Capabilities are opt-in permissions. An extension can only call bridge APIs that match its declared capabilities.

| Capability | Unlocks |
|------------|---------|
| `storage` | `swiftMaestro.storage.local.get/set/remove/clear` — per-extension key/value storage. |
| `tabs` | `swiftMaestro.tabs.query/create/update/remove/executeScript` — read and manipulate browser tabs. |
| `activeTab` | Grants temporary access to the currently active tab when the user clicks your toolbar button. |
| `downloads` | `swiftMaestro.downloads.download` — save files to disk. |
| `browserAction` | `swiftMaestro.browserAction.setBadgeText` — update the toolbar button badge. |
| `network` | `fetch()` from extension pages (already available; include for clarity). |
| `tools` | Allows the extension to request tool execution from Maestro. |

---

## JavaScript bridge API

Extensions run inside a WKWebView and talk to SwiftMaestro through `swiftMaestro.*` APIs. All calls are asynchronous and use a callback-style signature: `swiftMaestro.apiName.methodName(args, (result) => { ... })`.

### Storage (`storage` capability)

```js
swiftMaestro.storage.local.get("key", (value) => {
  console.log(value);
});

swiftMaestro.storage.local.set({ key: "value" }, () => {
  console.log("saved");
});

swiftMaestro.storage.local.remove("key", () => {});
swiftMaestro.storage.local.clear(() => {});
```

Values are persisted to:

```
~/Library/Application Support/SwiftMaestro/BrowserExtensions/<id>/_storage/local.json
```

### Tabs (`tabs` capability)

```js
// List all tabs
swiftMaestro.tabs.query({}, (tabs) => {
  console.log(tabs);
});

// Create a new tab
swiftMaestro.tabs.create({ url: "https://example.com" }, (tab) => {});

// Get the active tab
swiftMaestro.tabs.query({ active: true, currentWindow: true }, (tabs) => {
  const url = tabs[0]?.url;
});

// Inject a script into a tab
swiftMaestro.tabs.executeScript(tabId, { code: "document.title" }, (results) => {});
```

### Downloads (`downloads` capability)

```js
swiftMaestro.downloads.download({
  url: "https://example.com/video.mp4",
  filename: "video.mp4"
}, (downloadId) => {
  console.log("started", downloadId);
});
```

### Browser action badge (`browserAction` capability)

```js
swiftMaestro.browserAction.setBadgeText({ text: "3" }, () => {});
swiftMaestro.browserAction.setBadgeText({ text: "" }, () => {}); // clear
```

### Runtime messaging

Content scripts and popover pages can message each other through the extension's background context:

```js
// In content script
swiftMaestro.runtime.sendMessage({ action: "get_video_url" }, (response) => {});

// In popup
swiftMaestro.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === "get_video_url") {
    sendResponse({ url: window.location.href });
  }
});
```

---

## Complete examples

### Example 1: Toolbar button with a popup

`manifest.json`:

```json
{
  "id": "com.example.hello-world",
  "name": "Hello World",
  "version": "1.0.0",
  "icon": "hand.wave",
  "entry": "popup.html",
  "type": "browser-action",
  "capabilities": ["tabs", "activeTab"],
  "host": {
    "toolbar": {
      "icon": "hand.wave",
      "label": "Hello",
      "tooltip": "Say hello"
    }
  }
}
```

`popup.html`:

```html
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: system-ui; padding: 16px; width: 200px; }
    button { width: 100%; padding: 8px; }
  </style>
</head>
<body>
  <button id="btn">Get page URL</button>
  <p id="out"></p>
  <script src="popup.js"></script>
</body>
</html>
```

`popup.js`:

```js
document.getElementById("btn").onclick = () => {
  swiftMaestro.tabs.query({ active: true, currentWindow: true }, (tabs) => {
    document.getElementById("out").textContent = tabs[0]?.url || "no tab";
  });
};
```

### Example 2: Content script that runs on YouTube

`manifest.json`:

```json
{
  "id": "com.example.youtube-helper",
  "name": "YouTube Helper",
  "version": "1.0.0",
  "icon": "play.rectangle",
  "entry": "popup.html",
  "type": "content-script",
  "capabilities": ["storage", "tabs"],
  "content_scripts": [
    {
      "matches": ["*://*.youtube.com/*"],
      "js": ["content.js"],
      "run_at": "document_idle"
    }
  ]
}
```

`content.js`:

```js
console.log("YouTube Helper loaded on", window.location.href);

// Highlight the video title
const title = document.querySelector("h1.title, yt-formatted-string.style-scope.ytd-watch-metadata");
if (title) {
  title.style.backgroundColor = "yellow";
}
```

### Example 3: Sidebar panel extension

`manifest.json`:

```json
{
  "id": "com.example.notes-panel",
  "name": "Quick Notes",
  "version": "1.0.0",
  "icon": "note.text",
  "entry": "panel.html",
  "type": "panel",
  "capabilities": ["storage"]
}
```

`panel.html`:

```html
<!DOCTYPE html>
<html>
<body>
  <textarea id="notes" style="width:100%;height:200px;"></textarea>
  <button id="save">Save</button>
  <script src="panel.js"></script>
</body>
</html>
```

`panel.js`:

```js
swiftMaestro.storage.local.get("notes", (value) => {
  document.getElementById("notes").value = value || "";
});

document.getElementById("save").onclick = () => {
  const text = document.getElementById("notes").value;
  swiftMaestro.storage.local.set({ notes: text }, () => {});
};
```

---

## Troubleshooting

| Problem | Cause / Fix |
|---------|-------------|
| Plugin does not appear | Click **Rescan** in Settings → Plugins. Check that `manifest.json` is valid JSON. |
| Toolbar button missing | Make sure `type` is `browser-action` and `host.toolbar` is present. |
| Content script not injecting | Check that `content_scripts[].matches` matches the URL. Remember `*://*.youtube.com/*`, not just `youtube.com`. |
| Bridge API returns error | Verify the capability is listed in `capabilities`. Undeclared calls are rejected. |
| Icon is blank | Use a valid SF Symbol name for `icon` and `host.toolbar.icon`. |
| Install via Maestro fails | Ask Maestro to "copy the example exactly" and ensure `manifest` and `files` are valid JSON objects. |

---

## Tips for agents

When a user asks for a browser plugin, use the `install_browser_extension` tool. Do not edit SwiftMaestro source files and do not create Xcode projects.

Required parameters:
- `id` — reverse-domain identifier
- `name` — human-readable name
- `manifest` — JSON object matching the manifest format above
- `files` — JSON object mapping file paths to file contents

Always include `entry` HTML and any JS/CSS files referenced by the manifest. Use SF Symbol names for icons. Prefer `browser-action` for toolbar buttons and `content-script` for page modifications.
