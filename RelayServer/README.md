# SwiftMaestro Tracking Relay

A self-hostable email open/click tracking server for SwiftMaestro.

When you send tracked emails through SwiftMaestro's Mail panel, the tracking pixel URL points to this server. When recipients open the email, their client hits this server, which logs the open/click event.

## Quick Start

```bash
# No dependencies — runs on Node.js 18+ alone
node server.js

# Or with a custom port:
PORT=8087 node server.js
```

## Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /t/open/{token}.gif` | Logs an open event, returns a 1x1 transparent GIF |
| `GET /t/c/{token}?url={url}` | Logs a click event, redirects to the destination URL |
| `GET /health` | Returns `200 OK` |
| `GET /events?messageID=xxx` | Query events for a specific message |
| `GET /events?since=ISO` | Query all events since a timestamp |

## Configuration

All configuration is via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `3000` | HTTP listen port |
| `STORE_PATH` | `./relay-store.json` | Path to the event store JSON file |
| `SIGNING_SECRET` | *(empty)* | HMAC secret for token verification (must match SwiftMaestro's Keychain secret) |
| `VERIFY_TOKENS` | `0` | Set to `1` to enable HMAC token verification |

## Store Format

Events are persisted to `relay-store.json` in the same format as SwiftMaestro's embedded relay:

```json
{
  "messages": {
    "message-id-123": {
      "messageID": "message-id-123",
      "sender": "you@example.com",
      "recipients": ["them@example.com"],
      "subject": "Hello",
      "mode": "open_and_click",
      "createdAt": "2026-08-03T10:00:00Z",
      "metadata": {}
    }
  },
  "events": [
    {
      "id": "uuid",
      "messageID": "message-id-123",
      "type": "open",
      "timestamp": "2026-08-03T10:05:00Z",
      "recipient": "them@example.com",
      "sourceIP": "1.2.3.4",
      "userAgent": "Mozilla/5.0...",
      "attributes": {}
    }
  ]
}
```

## Deploy with nginx (HTTPS)

For real-world tracking, the relay needs to be reachable over HTTPS. Example nginx config for `track.swiftmaestro.com`:

```nginx
server {
    listen 443 ssl http2;
    server_name track.swiftmaestro.com;

    ssl_certificate     /etc/letsencrypt/live/track.swiftmaestro.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/track.swiftmaestro.com/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Then in SwiftMaestro → Settings → Mail, set the Base URL to:
```
https://track.swiftmaestro.com
```

## Running with pm2

```bash
pm2 start server.js --name tracking-relay
pm2 save
pm2 startup
```

## Security Notes

- **Token verification** is optional. Without it, anyone who knows the URL pattern can fire tracking events. For public-facing relays, enable `VERIFY_TOKENS=1` and set `SIGNING_SECRET` to match SwiftMaestro's Keychain secret.
- **CORS** is open (`Access-Control-Allow-Origin: *`) so the SwiftMaestro app can query events directly from the relay.
- **No authentication** on the events endpoint by default. For production, add a simple API key check.
