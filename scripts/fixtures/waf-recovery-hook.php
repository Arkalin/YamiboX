<?php
// Temporary, opt-in local hook. Include before Discuz bootstrap, then remove.
// Only a specifically seeded test session is affected, never other local users.
if (getenv('YAMIBO_LOCAL_RUNTIME') !== '1' ||
    (isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : '') !== '127.0.0.1:8088') { return; }
$fixtureRun = isset($_COOKIE['nox_fixture']) ? $_COOKIE['nox_fixture'] : '';
if (!preg_match('/\A[a-zA-Z0-9_-]{1,64}\z/', $fixtureRun)) { return; }
$fixtureConfigPath = sys_get_temp_dir() . '/yamibox-waf-active-' . $fixtureRun . '.json';
$fixtureConfig = is_file($fixtureConfigPath) ? json_decode(file_get_contents($fixtureConfigPath), true) : null;
if (!is_array($fixtureConfig)) { return; }
$fixtureScript = basename($_SERVER['SCRIPT_FILENAME']);
$fixtureSafeEntry = $fixtureScript === 'member.php' && isset($_GET['mod']) && $_GET['mod'] === 'logging'
    && (!isset($_GET['action']) || $_GET['action'] === 'login') && $_SERVER['REQUEST_METHOD'] === 'GET';
$fixtureCheckIn = $fixtureScript === 'plugin.php' && isset($_GET['id']) && $_GET['id'] === 'zqlj_sign'
    && !empty($fixtureConfig['checkin']);
$fixturePromotion = $fixtureScript === 'index.php' && isset($_GET['fromuid']) && !empty($fixtureConfig['observe_promotion']);
$fixtureProfile = $fixtureScript === 'home.php' && isset($_GET['mod'], $_GET['do'])
    && $_GET['mod'] === 'space' && $_GET['do'] === 'profile';
if ($fixtureScript === 'forum.php' && isset($_GET['mod'], $_GET['aid']) && $_GET['mod'] === 'attachment') {
    $fixtureAttachmentMapPath = sys_get_temp_dir() . '/yamibox-waf-attachments-' . $fixtureRun . '.json';
    $fixtureAttachmentMap = is_file($fixtureAttachmentMapPath) ? json_decode(file_get_contents($fixtureAttachmentMapPath), true) : array();
    $fixtureAttachmentID = explode('|', base64_decode($_GET['aid'], true))[0];
    if (isset($fixtureAttachmentMap[$fixtureAttachmentID])) { $_GET['fixture_file'] = $fixtureAttachmentMap[$fixtureAttachmentID]; }
}
$fixtureAttachment = $fixtureScript === 'forum.php' && isset($_GET['mod'], $_GET['fixture_file'])
    && $_GET['mod'] === 'attachment' && in_array($_GET['fixture_file'], array('normal', 'large', 'slow'), true);
$fixtureMode = $fixtureSafeEntry ? $fixtureConfig['verification'] : $fixtureConfig['challenge'];
if ($fixtureProfile && isset($fixtureConfig['profile'])) { $fixtureMode = $fixtureConfig['profile']; }
if ($fixtureCheckIn) { $fixtureMode = isset($_GET['sign']) ? 'permanent' : 'checkin-page'; }
if ($fixturePromotion) { $fixtureMode = 'receiver'; }
if ($fixtureAttachment && $fixtureMode === 'off') { $fixtureMode = 'file'; }
if ($fixtureMode === 'off') { return; }
$fixtureCounter = sys_get_temp_dir() . '/yamibox-waf-hook-' . $fixtureRun . '.json';
$fixtureFile = fopen($fixtureCounter, 'c+');
flock($fixtureFile, LOCK_EX);
$fixtureCounts = json_decode(stream_get_contents($fixtureFile), true);
if (!is_array($fixtureCounts)) { $fixtureCounts = array(); }
$fixtureRole = $fixtureSafeEntry ? 'verify' : ($fixtureCheckIn ? (isset($_GET['sign']) ? 'checkin-action' : 'checkin-page') : 'request');
$fixtureKey = $_SERVER['REQUEST_METHOD'] . ':' . $fixtureScript . ':' . $fixtureRole;
$fixtureCounts[$fixtureKey] = isset($fixtureCounts[$fixtureKey]) ? $fixtureCounts[$fixtureKey] + 1 : 1;
rewind($fixtureFile); ftruncate($fixtureFile, 0); fwrite($fixtureFile, json_encode($fixtureCounts));
fflush($fixtureFile); flock($fixtureFile, LOCK_UN); fclose($fixtureFile);
if ($fixtureMode === 'checkin-page') {
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store');
    echo '<!doctype html><title>Local check-in fixture</title><div class="signbtn">'
        . '<a class="btna" href="plugin.php?id=zqlj_sign&amp;sign=localfixture">点击打卡</a></div>';
    exit;
}
$fixtureVersion = isset($fixtureConfig['version']) ? preg_replace('/[^a-zA-Z0-9_-]/', '', substr($fixtureConfig['version'], 0, 32)) : '';
$fixtureClearance = 'fixture-' . $fixtureRun . ($fixtureVersion === '' ? '' : '-' . $fixtureVersion);
$fixtureCleared = isset($_COOKIE['nox_jst_v1']) && $_COOKIE['nox_jst_v1'] === $fixtureClearance;
if ($fixtureCleared && !in_array($fixtureMode, array('permanent', 'plain403', 'plain405', 'single', 'cross-origin', 'receiver', 'file'), true)) {
    if ($fixtureAttachment) { $fixtureMode = 'file'; } else { return; }
}
$_GET['run'] = $fixtureRun;
$_GET['mode'] = $fixtureMode;
require __DIR__ . '/waf-recovery.php';
exit;
