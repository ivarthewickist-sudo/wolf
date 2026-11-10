<?php
declare(strict_types=1);
// One-time setup, run by curl: install.php?token=<install_token>[&promote=email][&invite=CODE&uses=100]
// Applies schema.sql, seeds the first invite and an example party, then deletes itself and schema.sql unless ?keep=1.
header('Content-Type: text/plain; charset=utf-8');
$cfg = require __DIR__ . '/config.php';
if (!hash_equals($cfg['install_token'], (string)($_GET['token'] ?? ''))) { http_response_code(403); exit("forbidden\n"); }

$db = new PDO("mysql:host={$cfg['host']};dbname={$cfg['name']};charset=utf8mb4", $cfg['user'], $cfg['pass'], [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$schema = __DIR__ . '/schema.sql';
if (is_file($schema)) {
    foreach (array_filter(array_map('trim', explode(';', preg_replace('/^--.*$/m', '', file_get_contents($schema))))) as $sql) $db->exec($sql);
    echo "schema applied\n";
}
if (!empty($_GET['invite'])) {
    $db->prepare('INSERT INTO invites (code, note, max_uses) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE uses = 0, max_uses = VALUES(max_uses), expires_at = NULL')
       ->execute([$_GET['invite'], 'created by install.php', max(1, (int)($_GET['uses'] ?? 1))]);
    echo "invite ready: {$_GET['invite']}\n";
}
if (!empty($_GET['status'])) { // counts only, no personal data
    echo 'users: ' . $db->query('SELECT COUNT(*) FROM users')->fetchColumn() . ', admins: ' . $db->query('SELECT COUNT(*) FROM users WHERE is_admin = 1')->fetchColumn()
       . ', invite uses: ' . $db->query('SELECT GROUP_CONCAT(CONCAT(code, "=", uses, "/", max_uses)) FROM invites')->fetchColumn() . "\n";
}
if (!empty($_GET['wipe'])) { // clears test accounts and sessions' data before launch; invites are kept, their use counters reset
    foreach (['resets', 'rate_limits', 'users'] as $t) $db->exec("DELETE FROM $t");
    $db->exec("DELETE FROM party WHERE title = 'STAGING NIGHT'");
    $db->exec('UPDATE invites SET uses = 0');
    echo "test data wiped: " . $db->query('SELECT COUNT(*) FROM users')->fetchColumn() . " users left\n";
}
if (!$db->query('SELECT COUNT(*) FROM party')->fetchColumn()) {
    $db->exec("INSERT INTO party (title, starts_at, ends_at, venue, address, city, entry, capacity, dress_code, dress_notes, rules, theme)
      VALUES ('FULL MOON · NIGHT 07', '2026-11-28 22:00:00', '2026-11-29 05:00:00', 'THE DEN (EXAMPLE)', 'EXACT ADDRESS SENT 24H BEFORE DOORS', 'REYKJAVÍK',
      'SHOW CLEARANCE 07 AT THE DOOR', 120, 'ALL BLACK. NO LOGOS.',
      '[\"BLACK FROM COLLAR TO BOOTS\",\"ONE RED DETAIL ALLOWED\",\"MASKS WELCOME, NOT REQUIRED\",\"SHOES YOU CAN DANCE IN TILL SIX\"]',
      '[\"NO PHOTOS OR VIDEO ON THE FLOOR\",\"PHONES STAY IN POCKETS\",\"ASK FIRST. NO MEANS NO\",\"NO PLUS-ONES WITHOUT CLEARANCE\",\"WHAT HAPPENS IN THE DEN STAYS THERE\",\"LOOK AFTER THE PACK\"]',
      NULL)");
    echo "example party added\n";
}
if (!empty($_GET['promote'])) {
    $s = $db->prepare('UPDATE users SET is_admin = 1 WHERE email = ?');
    $s->execute([strtolower((string)$_GET['promote'])]);
    echo $s->rowCount() ? "admin: {$_GET['promote']}\n" : "no such user: {$_GET['promote']}\n";
}
if (empty($_GET['keep'])) { @unlink($schema); @unlink(__FILE__); echo "install files removed\n"; }
