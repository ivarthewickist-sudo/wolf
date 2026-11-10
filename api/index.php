<?php
declare(strict_types=1);

// Single JSON endpoint for the Wolf site: POST {"a": "<action>", ...} to api/index.php.
// Sessions are PHP cookies. Every query is a prepared statement; access rules live here (the old Supabase RLS).

ini_set('display_errors', '0');
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');

function out(array $d, int $http = 200): never { http_response_code($http); echo json_encode($d, JSON_UNESCAPED_UNICODE); exit; }
function fail(string $code, int $http = 400): never { out(['error' => ['code' => $code]], $http); }
set_exception_handler(function (Throwable $e) { error_log('wolf api: ' . $e->getMessage()); fail('server_error', 500); });

// CSRF: only a same-origin script can send POST + JSON + a custom header (anything cross-site needs a CORS preflight we never grant).
if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST' || ($_SERVER['HTTP_X_WOLF'] ?? '') !== '1'
    || stripos($_SERVER['CONTENT_TYPE'] ?? '', 'application/json') !== 0
    || (int)($_SERVER['CONTENT_LENGTH'] ?? 0) > 65536) fail('bad_request');
$origin = $_SERVER['HTTP_ORIGIN'] ?? '';
if ($origin !== '' && parse_url($origin, PHP_URL_HOST) !== explode(':', $_SERVER['HTTP_HOST'] ?? '')[0]) fail('bad_request', 403);
$in = json_decode((string)file_get_contents('php://input'), true);
if (!is_array($in) || !is_string($in['a'] ?? null)) fail('bad_request');

$cfg = require __DIR__ . '/config.php';
$db = new PDO("mysql:host={$cfg['host']};dbname={$cfg['name']};charset=utf8mb4", $cfg['user'], $cfg['pass'], [
    PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC, PDO::ATTR_EMULATE_PREPARES => false,
]);
$db->exec("SET time_zone = '+00:00'");

$https = (!empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off') || ($_SERVER['HTTP_X_FORWARDED_PROTO'] ?? '') === 'https';
ini_set('session.use_strict_mode', '1');
ini_set('session.gc_maxlifetime', (string)(86400 * 30));
session_name('wolf');
session_set_cookie_params(['lifetime' => 86400 * 30, 'path' => '/', 'secure' => $https, 'httponly' => true, 'samesite' => 'Lax']);
session_start();

const ALGO_FALLBACK = PASSWORD_DEFAULT;
function hash_pw(string $pw): string { return password_hash($pw, defined('PASSWORD_ARGON2ID') ? PASSWORD_ARGON2ID : ALGO_FALLBACK); }

function me(): ?array {
    global $db;
    if (empty($_SESSION['uid'])) return null;
    $s = $db->prepare('SELECT id, email, first_name, last_name, phone, is_admin FROM users WHERE id = ?');
    $s->execute([$_SESSION['uid']]);
    $u = $s->fetch();
    if (!$u) { unset($_SESSION['uid']); return null; }
    $u['id'] = (int)$u['id']; $u['is_admin'] = (bool)$u['is_admin'];
    return $u;
}
function need_user(): array { return me() ?? fail('not_signed_in', 401); }
function need_admin(): array { $u = need_user(); if (!$u['is_admin']) fail('forbidden', 403); return $u; }

function limit(string $key, int $max, int $secs): void {
    global $db;
    $db->prepare('DELETE FROM rate_limits WHERE t < ?')->execute([time() - 86400]);
    $s = $db->prepare('SELECT COUNT(*) FROM rate_limits WHERE k = ? AND t > ?');
    $s->execute([$key, time() - $secs]);
    if ((int)$s->fetchColumn() >= $max) fail('over_request_rate_limit', 429);
    $db->prepare('INSERT INTO rate_limits (k, t) VALUES (?, ?)')->execute([$key, time()]);
}
$ip = sha1($_SERVER['REMOTE_ADDR'] ?? '');

function str(mixed $v, int $max): ?string {
    if (!is_string($v)) return null;
    $v = trim($v);
    return $v === '' ? null : mb_substr($v, 0, $max);
}
function lines(mixed $v): array {
    if (!is_array($v)) return [];
    $v = array_map(fn($x) => is_string($x) ? mb_substr(trim($x), 0, 120) : '', $v);
    return array_slice(array_values(array_filter($v, fn($x) => $x !== '')), 0, 30);
}
function iso(?string $dt): ?string { return $dt ? str_replace(' ', 'T', $dt) . 'Z' : null; }
function to_db(mixed $iso): ?string {
    if (!is_string($iso) || $iso === '') return null;
    try { return (new DateTimeImmutable($iso))->setTimezone(new DateTimeZone('UTC'))->format('Y-m-d H:i:s'); }
    catch (Throwable) { fail('bad_request'); }
}
function party_out(array $p): array {
    foreach (['id', 'capacity'] as $k) if ($p[$k] !== null) $p[$k] = (int)$p[$k];
    foreach (['lat', 'lon'] as $k) if ($p[$k] !== null) $p[$k] = (float)$p[$k];
    $p['published'] = (bool)$p['published'];
    $p['starts_at'] = iso($p['starts_at']); $p['ends_at'] = iso($p['ends_at']);
    $p['dress_notes'] = json_decode($p['dress_notes'] ?: '[]', true) ?: [];
    $p['rules'] = json_decode($p['rules'] ?: '[]', true) ?: [];
    unset($p['created_at']);
    return $p;
}
function start_session_for(int $id): void { session_regenerate_id(true); $_SESSION['uid'] = $id; }

switch ($in['a']) {
    case 'me':
        out(['user' => me()]);

    case 'invite_ok':
        limit("inv|$ip", 60, 900);
        $code = str($in['c'] ?? null, 40);
        $s = $db->prepare('SELECT 1 FROM invites WHERE code = ? AND uses < max_uses AND (expires_at IS NULL OR expires_at > UTC_TIMESTAMP())');
        $s->execute([$code ?? '']);
        out(['ok' => (bool)$s->fetchColumn()]);

    case 'signup':
        limit("signup|$ip", 8, 900);
        $email = strtolower(trim((string)($in['email'] ?? '')));
        $pw = (string)($in['password'] ?? '');
        $first = str($in['first_name'] ?? null, 60); $last = str($in['last_name'] ?? null, 60);
        $phone = str($in['phone'] ?? null, 24); $code = str($in['invite'] ?? null, 40);
        if (!filter_var($email, FILTER_VALIDATE_EMAIL) || strlen($email) > 190) fail('email_address_invalid');
        if (strlen($pw) < 8 || strlen($pw) > 200) fail('weak_password');
        if (!$first || !$last || !$phone || !preg_match('/^\+?[\d\s().-]{7,24}$/', $phone) || !preg_match('/^\d{7,15}$/', preg_replace('/\D/', '', $phone))) fail('bad_request');
        if (!$code) fail('invite_invalid');
        $db->beginTransaction();
        try {
            // spending the invite and creating the user are one transaction, so a refused sign-up never burns a code
            $u = $db->prepare('UPDATE invites SET uses = uses + 1 WHERE code = ? AND uses < max_uses AND (expires_at IS NULL OR expires_at > UTC_TIMESTAMP())');
            $u->execute([$code]);
            if ($u->rowCount() !== 1) { $db->rollBack(); fail('invite_invalid'); }
            $db->prepare('INSERT INTO users (email, pass_hash, first_name, last_name, phone, invite) VALUES (?, ?, ?, ?, ?, ?)')
               ->execute([$email, hash_pw($pw), $first, $last, $phone, $code]);
            $id = (int)$db->lastInsertId();
            $db->commit();
        } catch (PDOException $e) {
            if ($db->inTransaction()) $db->rollBack();
            if (($e->errorInfo[1] ?? 0) === 1062) fail('user_already_exists', 409);
            throw $e;
        }
        start_session_for($id);
        out(['user' => me()]);

    case 'login':
        $email = strtolower(trim((string)($in['email'] ?? '')));
        limit("login|$ip", 30, 900);
        limit('loginm|' . sha1($email), 8, 900);
        $s = $db->prepare('SELECT id, pass_hash FROM users WHERE email = ?');
        $s->execute([$email]);
        $r = $s->fetch();
        // verify against a throwaway hash when the email is unknown, so timing doesn't reveal which emails exist
        $ok = password_verify((string)($in['password'] ?? ''), $r['pass_hash'] ?? hash_pw('x'));
        if (!$r || !$ok) fail('invalid_credentials', 401);
        start_session_for((int)$r['id']);
        out(['user' => me()]);

    case 'logout':
        $_SESSION = [];
        session_destroy();
        out(['ok' => true]);

    case 'reset_password':
        limit("reset|$ip", 10, 900);
        $pw = (string)($in['password'] ?? '');
        if (strlen($pw) < 8 || strlen($pw) > 200) fail('weak_password');
        $s = $db->prepare('SELECT user_id FROM resets WHERE token_hash = ? AND expires_at > UTC_TIMESTAMP()');
        $s->execute([hash('sha256', (string)($in['token'] ?? ''))]);
        $uid = $s->fetchColumn();
        if (!$uid) fail('reset_invalid', 400);
        $db->prepare('UPDATE users SET pass_hash = ? WHERE id = ?')->execute([hash_pw($pw), $uid]);
        $db->prepare('DELETE FROM resets WHERE user_id = ?')->execute([$uid]);
        start_session_for((int)$uid);
        out(['user' => me()]);

    case 'party_latest':
        $u = need_user();
        $s = $db->prepare('SELECT * FROM party WHERE published = 1 OR ? = 1 ORDER BY starts_at DESC LIMIT 1');
        $s->execute([$u['is_admin'] ? 1 : 0]);
        $p = $s->fetch();
        out(['party' => $p ? party_out($p) : null]);

    // ---- admin only from here ----
    case 'party_list':
        need_admin();
        $rows = $db->query('SELECT p.*, n.notes FROM party p LEFT JOIN party_notes n ON n.party_id = p.id ORDER BY p.starts_at DESC')->fetchAll();
        out(['parties' => array_map(fn($p) => party_out($p) + ['notes' => $p['notes'] ?? ''], $rows)]);

    case 'party_save':
        need_admin();
        $r = $in['row'] ?? null;
        if (!is_array($r)) fail('bad_request');
        $title = str($r['title'] ?? null, 190);
        $start = to_db($r['starts_at'] ?? null);
        if (!$title || !$start) fail('bad_request');
        $cap = $r['capacity'] ?? null;
        if ($cap !== null && !(is_int($cap) && $cap >= 0)) fail('bad_request');
        $status = in_array($r['status'] ?? null, ['sold_out', 'cancelled'], true) ? $r['status'] : null;
        $v = [
            'title' => $title, 'theme' => str($r['theme'] ?? null, 190), 'venue' => str($r['venue'] ?? null, 190),
            'city' => str($r['city'] ?? null, 120), 'address' => str($r['address'] ?? null, 255), 'directions' => str($r['directions'] ?? null, 2000),
            'entry' => str($r['entry'] ?? null, 255), 'dress_code' => str($r['dress_code'] ?? null, 255), 'capacity' => $cap,
            'status' => $status, 'published' => empty($r['published']) ? 0 : 1,
            'dress_notes' => json_encode(lines($r['dress_notes'] ?? []), JSON_UNESCAPED_UNICODE), 'rules' => json_encode(lines($r['rules'] ?? []), JSON_UNESCAPED_UNICODE),
            'starts_at' => $start, 'ends_at' => to_db($r['ends_at'] ?? null),
        ];
        $id = isset($in['id']) ? (int)$in['id'] : 0;
        if ($id) {
            $set = implode(', ', array_map(fn($k) => "$k = :$k", array_keys($v)));
            $v['id'] = $id;
            $db->prepare("UPDATE party SET $set WHERE id = :id")->execute($v);
        } else {
            $db->prepare('INSERT INTO party (' . implode(', ', array_keys($v)) . ') VALUES (:' . implode(', :', array_keys($v)) . ')')->execute($v);
            $id = (int)$db->lastInsertId();
        }
        $notes = str($in['notes'] ?? null, 5000);
        if ($notes) $db->prepare('REPLACE INTO party_notes (party_id, notes) VALUES (?, ?)')->execute([$id, $notes]);
        else $db->prepare('DELETE FROM party_notes WHERE party_id = ?')->execute([$id]);
        out(['id' => $id]);

    case 'party_delete':
        need_admin();
        $db->prepare('DELETE FROM party WHERE id = ?')->execute([(int)($in['id'] ?? 0)]);
        out(['ok' => true]);

    case 'members_list':
        need_admin();
        $rows = $db->query('SELECT id, email, first_name, last_name, phone, invite, created_at FROM users ORDER BY created_at DESC')->fetchAll();
        foreach ($rows as &$m) { $m['id'] = (int)$m['id']; $m['created_at'] = iso($m['created_at']); }
        out(['members' => $rows]);

    case 'admin_reset_link':
        need_admin();
        $uid = (int)($in['user_id'] ?? 0);
        $s = $db->prepare('SELECT 1 FROM users WHERE id = ?');
        $s->execute([$uid]);
        if (!$s->fetchColumn()) fail('bad_request');
        $token = bin2hex(random_bytes(32));
        $db->prepare('DELETE FROM resets WHERE user_id = ?')->execute([$uid]);
        $db->prepare('INSERT INTO resets (token_hash, user_id, expires_at) VALUES (?, ?, UTC_TIMESTAMP() + INTERVAL 1 HOUR)')->execute([hash('sha256', $token), $uid]);
        out(['token' => $token]);

    default:
        fail('bad_request');
}
