# PHP Tracking Relay

Drop-in email tracking relay for shared hosting. No Node.js required.

## Deploy

1. Upload the `php/` directory to your web hosting as `/tracking/`
2. Make sure the `data/` directory is writable by the web server:
   ```
   chmod 755 data/
   ```
3. In SwiftMaestro → Settings → Mail, set Base URL to:
   ```
   https://swiftmaestro.com/tracking
   ```

## Endpoints

| URL | Description |
|-----|-------------|
| `GET /tracking/t/open/{token}.gif` | Log open event, return 1x1 GIF |
| `GET /tracking/t/c/{token}?url={url}` | Log click event, redirect to URL |
| `GET /tracking/health` | Health check (returns "OK") |
| `GET /tracking/events?messageID=xxx` | Query events for a message |

## Files

- `index.php` — main entry point (handles all routes)
- `.htaccess` — Apache URL rewriting (skip if using nginx)
- `data/relay-store.json` — event store (auto-created, same format as Node.js version)

## Without .htaccess

If URL rewriting doesn't work, use direct query strings:

```
/tracking/index.php?action=open&token=...
/tracking/index.php?action=click&token=...&url=...
/tracking/index.php?action=health
/tracking/index.php?action=events&messageID=...
```

## Notes

- Events are stored in `data/relay-store.json` (same JSON format as the embedded relay)
- Last 50,000 events are kept to prevent unbounded disk growth
- CORS is open so the SwiftMaestro app can query events directly
