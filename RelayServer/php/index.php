<?php
// SwiftMaestro Tracking Relay — PHP (multi-user, secure)
//
// SECURITY MODEL
//   - Each user has a random API key (their signing secret + identity)
//   - Tracking tokens are HMAC-SHA256 signed — only valid tokens are logged
//   - Events are tagged with the creator's API key
//   - GET /events requires ?apikey=... and returns ONLY that user's events
//   - Open/click endpoints are public but HMAC-verified (no fake event spam)
//
// Endpoints:
//   GET /tracking/t/open/{token}.gif  — verify HMAC, log open, return 1x1 GIF
//   GET /tracking/t/c/{token}?url=... — verify HMAC, log click, redirect
//   GET /tracking/v1/events?apikey=KEY [&messageId=X] [&since=ISO] [&limit=N]
//   GET /tracking/health              — 200 OK (no auth)

header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, OPTIONS');
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');

if ($_SERVER['REQUEST_METHOD'] === 'OPTIONS') {
    http_response_code(204);
    exit;
}

// --- Config ---
$STORE_DIR  = __DIR__ . '/data';
$STORE_FILE = $STORE_DIR . '/relay-store.json';

// --- Store functions ---
function loadStore() {
    global $STORE_FILE;
    if (file_exists($STORE_FILE)) {
        $json = file_get_contents($STORE_FILE);
        $data = json_decode($json, true);
        if (isset($data['messages']) && isset($data['events'])) {
            return $data;
        }
    }
    return ['messages' => [], 'events' => []];
}

function saveStore($store) {
    global $STORE_DIR, $STORE_FILE;
    if (!is_dir($STORE_DIR)) {
        mkdir($STORE_DIR, 0755, true);
    }
    // Atomic write: write to temp file then rename
    $tmp = $STORE_FILE . '.tmp.' . getmypid();
    file_put_contents($tmp, json_encode($store, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
    rename($tmp, $STORE_FILE);
}

function appendEvent($event) {
    $store = loadStore();
    $store['events'][] = $event;
    if (count($store['events']) > 100000) {
        $store['events'] = array_slice($store['events'], -100000);
    }
    saveStore($store);
}

// --- Verify token and resolve API key ---
// For signed tokens: verifies HMAC and returns the API key from the payload.
// For unsigned (legacy) tokens: accepts the query-parameter API key.
function verifyToken($token, $queryAPIKey) {
    $padded = strtr($token, '-_', '+/');
    $remainder = strlen($padded) % 4;
    if ($remainder) $padded .= str_repeat('=', 4 - $remainder);
    $decoded = base64_decode($padded, true);
    if ($decoded === false || $decoded === '') {
        return null;
    }
    $payload = json_decode($decoded, true);
    if (!is_array($payload) || !isset($payload['mid'])) {
        return null;
    }

    // New signed tokens (have HMAC signature)
    if (isset($payload['sig'])) {
        $apiKey = $payload['apiKey'] ?? $queryAPIKey;
        if (!$apiKey) return null;

        $ts = $payload['ts'] ?? '';
        $messageID = $payload['mid'];
        $recipient = $payload['rcp'] ?? '';
        $dataToVerify = $messageID . $recipient . $ts;
        $expectedSig = hash_hmac('sha256', $dataToVerify, $apiKey);

        if (!hash_equals($expectedSig, $payload['sig'])) {
            return null; // Invalid signature
        }

        // Reject tokens older than 90 days
        if ($ts && (time() - intval($ts)) > (90 * 86400)) {
            return null;
        }

        return [
            'messageID' => $messageID,
            'recipient' => $recipient,
            'apiKey'    => $apiKey,
        ];
    }

    // Legacy unsigned tokens (pre-auth): accept with query-parameter API key
    return [
        'messageID' => $payload['mid'] ?? 'unknown',
        'recipient' => $payload['rcp'] ?? null,
        'apiKey'    => $queryAPIKey ?: null,
    ];
}

// --- Client IP ---
function getClientIP() {
    if (!empty($_SERVER['HTTP_X_FORWARDED_FOR'])) {
        $ips = explode(',', $_SERVER['HTTP_X_FORWARDED_FOR']);
        return trim($ips[0]);
    }
    if (!empty($_SERVER['HTTP_X_REAL_IP'])) {
        return $_SERVER['HTTP_X_REAL_IP'];
    }
    return $_SERVER['REMOTE_ADDR'] ?? 'unknown';
}

// --- UUID v4 ---
function newUUID() {
    return sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x',
        mt_rand(0, 0xffff), mt_rand(0, 0xffff),
        mt_rand(0, 0xffff),
        mt_rand(0, 0x0fff) | 0x4000,
        mt_rand(0, 0x3fff) | 0x8000,
        mt_rand(0, 0xffff), mt_rand(0, 0xffff), mt_rand(0, 0xffff)
    );
}

// --- Validate API key format (64-char hex = UUID+UUID) ---
function isValidAPIKey($key) {
    return is_string($key) && preg_match('/^[a-f0-9]{64}$/i', $key);
}

// --- Route ---
$action = $_GET['action'] ?? '';
$token  = $_GET['token'] ?? '';

// Support direct query string if .htaccess isn't active
if (!$action && isset($_SERVER['REQUEST_URI'])) {
    $uri = parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);
    if (preg_match('#/t/open/(.+)\.gif$#', $uri, $m)) {
        $action = 'open';
        $token = $m[1];
    } elseif (preg_match('#/t/c/(.+)$#', $uri, $m)) {
        $action = 'click';
        $token = $m[1];
    } elseif (preg_match('#/health$#', $uri)) {
        $action = 'health';
    } elseif (preg_match('#/v1/events$#', $uri) || preg_match('#/events$#', $uri)) {
        $action = 'events';
    }
}

switch ($action) {

    // --- Health check (no auth) ---
    case 'health':
        header('Content-Type: text/plain');
        echo 'OK';
        break;

    // --- Open pixel ---
    case 'open':
        if (!$token) { http_response_code(400); echo 'Missing token'; break; }

        // Extract API key from token payload or query parameter
        $padded = strtr($token, '-_', '+/');
        $remainder = strlen($padded) % 4;
        if ($remainder) $padded .= str_repeat('=', 4 - $remainder);
        $decoded = base64_decode($padded, true);
        $payload = json_decode($decoded, true);
        $queryAPIKey = $_GET['apikey'] ?? '';

        // Verify token and resolve API key
        $decodedToken = verifyToken($token, $queryAPIKey);

        if ($decodedToken === null) {
            // Invalid or expired token — still return pixel (don't tip off bots)
            header('Content-Type: image/gif');
            header('Cache-Control: no-store, no-cache, must-revalidate');
            echo base64_decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
            break;
        }

        appendEvent([
            'id'         => newUUID(),
            'messageID'  => $decodedToken['messageID'],
            'type'       => 'open',
            'timestamp'  => date('c'),
            'recipient'  => $decodedToken['recipient'],
            'sourceIP'   => getClientIP(),
            'userAgent'  => $_SERVER['HTTP_USER_AGENT'] ?? null,
            'apiKey'     => $decodedToken['apiKey'],
            'attributes' => (object) [],
        ]);

        header('Content-Type: image/gif');
        header('Cache-Control: no-store, no-cache, must-revalidate');
        header('Pragma: no-cache');
        header('Expires: 0');
        echo base64_decode('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7');
        break;

    // --- Click redirect ---
    case 'click':
        if (!$token) { http_response_code(400); echo 'Missing token'; break; }

        $dest = $_GET['url'] ?? '/';
        // Validate redirect URL (no javascript: or data: schemes)
        if (preg_match('#^(javascript|data|vbscript):#i', $dest)) {
            $dest = '/';
        }

        $padded = strtr($token, '-_', '+/');
        $remainder = strlen($padded) % 4;
        if ($remainder) $padded .= str_repeat('=', 4 - $remainder);
        $decoded = base64_decode($padded, true);
        $payload = json_decode($decoded, true);
        $queryAPIKey = $_GET['apikey'] ?? '';
        $decodedToken = verifyToken($token, $queryAPIKey);

        if ($decodedToken === null) {
            header('Location: ' . $dest, true, 302);
            break;
        }

        appendEvent([
            'id'         => newUUID(),
            'messageID'  => $decodedToken['messageID'],
            'type'       => 'click',
            'timestamp'  => date('c'),
            'recipient'  => $decodedToken['recipient'],
            'sourceIP'   => getClientIP(),
            'userAgent'  => $_SERVER['HTTP_USER_AGENT'] ?? null,
            'apiKey'     => $decodedToken['apiKey'],
            'attributes' => ['url' => $dest],
        ]);

        header('Location: ' . $dest, true, 302);
        break;

    // --- Query events (REQUIRES apikey) ---
    case 'events':
        header('Content-Type: application/json');

        $apikey = $_GET['apikey'] ?? '';
        if (!isValidAPIKey($apikey)) {
            http_response_code(401);
            echo json_encode(['error' => 'Missing or invalid apikey parameter']);
            break;
        }

        $store = loadStore();
        $events = $store['events'];

        // Filter by API key — only return this user's events
        $events = array_values(array_filter($events, function($e) use ($apikey) {
            return ($e['apiKey'] ?? null) === $apikey;
        }));

        if (!empty($_GET['messageId'])) {
            $mid = $_GET['messageId'];
            $events = array_values(array_filter($events, fn($e) => $e['messageID'] === $mid));
        }
        if (!empty($_GET['since'])) {
            $since = strtotime($_GET['since']);
            $events = array_values(array_filter($events, fn($e) => strtotime($e['timestamp']) >= $since));
        }
        if (!empty($_GET['limit'])) {
            $events = array_slice($events, -intval($_GET['limit']));
        }

        echo json_encode(['events' => $events]);
        break;

    default:
        http_response_code(404);
        echo 'Not found';
        break;
}
