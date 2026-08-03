<?php
// SwiftMaestro Tracking Relay — PHP version
//
// Deploy: upload the php/ directory to your web hosting as /tracking/
//
// Endpoints (via .htaccess rewrites):
//   GET /tracking/open/{token}.gif    — log open, return 1x1 GIF
//   GET /tracking/c/{token}?url=...   — log click, redirect
//   GET /tracking/health              — 200 OK
//   GET /tracking/events?messageID=x  — query events (JSON)
//
// Direct access (if .htaccess doesn't work):
//   GET /tracking/index.php?action=open&token=...
//   GET /tracking/index.php?action=click&token=...
//   GET /tracking/index.php?action=health
//   GET /tracking/index.php?action=events&messageID=...

header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET, OPTIONS');

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
    file_put_contents($STORE_FILE, json_encode($store, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
}

function appendEvent($event) {
    $store = loadStore();
    $store['events'][] = $event;
    // Keep last 50,000 events to prevent unbounded growth
    if (count($store['events']) > 50000) {
        $store['events'] = array_slice($store['events'], -50000);
    }
    saveStore($store);
}

// --- Token decoding ---
function decodeToken($token) {
    $padded = strtr($token, '-_', '+/');
    $remainder = strlen($padded) % 4;
    if ($remainder) $padded .= str_repeat('=', 4 - $remainder);
    $decoded = base64_decode($padded, true);
    if ($decoded === false || $decoded === '') {
        return ['messageID' => $token, 'recipient' => null];
    }
    $payload = json_decode($decoded, true);
    if (!is_array($payload)) {
        return ['messageID' => $token, 'recipient' => null];
    }
    return [
        'messageID' => $payload['mid'] ?? 'unknown',
        'recipient' => $payload['rcp'] ?? null,
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

// --- New event ID (UUID v4) ---
function newUUID() {
    return sprintf('%04x%04x-%04x-%04x-%04x-%04x%04x%04x',
        mt_rand(0, 0xffff), mt_rand(0, 0xffff),
        mt_rand(0, 0xffff),
        mt_rand(0, 0x0fff) | 0x4000,
        mt_rand(0, 0x3fff) | 0x8000,
        mt_rand(0, 0xffff), mt_rand(0, 0xffff), mt_rand(0, 0xffff)
    );
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
    } elseif (preg_match('#/events$#', $uri)) {
        $action = 'events';
    }
}

switch ($action) {

    // --- Health check ---
    case 'health':
        header('Content-Type: text/plain');
        echo 'OK';
        break;

    // --- Open pixel ---
    case 'open':
        if (!$token) { http_response_code(400); echo 'Missing token'; break; }

        $decoded = decodeToken($token);
        appendEvent([
            'id'         => newUUID(),
            'messageID'  => $decoded['messageID'],
            'type'       => 'open',
            'timestamp'  => date('c'),
            'recipient'  => $decoded['recipient'],
            'sourceIP'   => getClientIP(),
            'userAgent'  => $_SERVER['HTTP_USER_AGENT'] ?? null,
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
        $decoded = decodeToken($token);
        appendEvent([
            'id'         => newUUID(),
            'messageID'  => $decoded['messageID'],
            'type'       => 'click',
            'timestamp'  => date('c'),
            'recipient'  => $decoded['recipient'],
            'sourceIP'   => getClientIP(),
            'userAgent'  => $_SERVER['HTTP_USER_AGENT'] ?? null,
            'attributes' => ['url' => $dest],
        ]);

        header('Location: ' . $dest, true, 302);
        break;

    // --- Query events ---
    case 'events':
        header('Content-Type: application/json');
        $store = loadStore();
        $events = $store['events'];

        if (!empty($_GET['messageID'])) {
            $mid = $_GET['messageID'];
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
