<?php
// Local-only fixture. Install temporarily; never deploy with a forum release.
if (getenv('YAMIBO_LOCAL_RUNTIME') !== '1' ||
    !in_array(isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : '', array('127.0.0.1:8088', '127.0.0.1:8087'), true)) {
    http_response_code(404);
    exit;
}
header('Cache-Control: no-store');
$mode = isset($_GET['mode']) ? $_GET['mode'] : 'body';
$run = isset($_GET['run']) ? $_GET['run'] : 'default';
if (!preg_match('/\A[a-zA-Z0-9_-]{1,64}\z/', $run)) {
    http_response_code(400);
    exit;
}
if ($mode === 'seed') {
    setcookie('nox_fixture', $run, time() + 3600, '/');
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><title>Local WAF fixture</title><p><a href="/forum.php">Enter local forum</a></p>'
        . '<p><a href="/member.php?mod=logging&amp;action=login">Open local login in this browser</a></p>';
    exit;
}
if ($mode === 'origin-probe') {
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><title>Local origin probe</title><p>Same-host alternate-port image request</p>'
        . '<img alt="Local receiver" src="http://127.0.0.1:8087/waf-recovery.php?mode=receiver&amp;run=' . rawurlencode($run) . '">';
    exit;
}
$isImage = $mode === 'image';
$variant = isset($_GET['variant']) ? $_GET['variant'] : '';
if ($variant !== '' && !preg_match('/\A[a-zA-Z0-9_-]{1,32}\z/', $variant)) { http_response_code(400); exit; }
$configPath = sys_get_temp_dir() . '/yamibox-waf-active-' . $run . '.json';
$config = is_file($configPath) ? json_decode(file_get_contents($configPath), true) : array();
$version = isset($config['version']) ? preg_replace('/[^a-zA-Z0-9_-]/', '', substr($config['version'], 0, 32)) : '';
$clearance = 'fixture-' . $run . ($version === '' ? '' : '-' . $version);
if ($isImage) {
    $mode = isset($config['images']) ? $config['images'] : 'off';
    if (isset($config['images_by_variant'][$variant])) { $mode = $config['images_by_variant'][$variant]; }
}
$path = sys_get_temp_dir() . '/yamibox-waf-' . $run . '.json';
$file = fopen($path, 'c+');
flock($file, LOCK_EX);
$state = json_decode(stream_get_contents($file), true);
if (!is_array($state)) { $state = array(); }
if ($mode !== 'counts') {
    $key = (isset($_SERVER['REQUEST_METHOD']) ? $_SERVER['REQUEST_METHOD'] : 'GET') . ':'
        . ($isImage ? 'image-' . max(1, min(9, (int)(isset($_GET['n']) ? $_GET['n'] : 1))) . ':' : '') . $mode;
    if ($variant !== '') { $key .= ':' . $variant; }
    $state[$key] = isset($state[$key]) ? $state[$key] + 1 : 1;
    // Record presence only, never the credential or request body.
    $state['received_forum_auth'] = preg_match('/(?:^|;\s*)[^=;]*_2132_auth=/', isset($_SERVER['HTTP_COOKIE']) ? $_SERVER['HTTP_COOKIE'] : '') === 1;
    $state['auth_seen_by_mode'][$key] = !empty($state['auth_seen_by_mode'][$key]) || $state['received_forum_auth'];
    rewind($file);
    ftruncate($file, 0);
    fwrite($file, json_encode($state));
    fflush($file);
}
flock($file, LOCK_UN);
fclose($file);
if ($mode === 'counts' || $mode === 'receiver') {
    header('Content-Type: application/json');
    echo json_encode($state);
    exit;
}
if ($mode === 'file') {
    $kind = isset($_GET['fixture_file']) ? $_GET['fixture_file'] : 'normal';
    $length = $kind === 'large' ? 50 * 1024 * 1024 + 1 : ($kind === 'slow' ? 4 * 1024 * 1024 : 1024);
    header('Content-Type: text/plain');
    header('Content-Disposition: attachment; filename="local-waf-fixture.txt"');
    header('Content-Length: ' . $length);
    $chunk = str_repeat('Local fixture.\n', 4096);
    for ($offset = 0; $offset < $length; $offset += strlen($chunk)) {
        echo substr($chunk, 0, min(strlen($chunk), $length - $offset));
        flush();
        if (connection_aborted()) { break; }
        if ($kind === 'slow') { usleep(200000); }
    }
    exit;
}
if ($mode === 'plain403' || $mode === 'plain405') {
    http_response_code($mode === 'plain403' ? 403 : 405);
    echo 'ordinary error';
    exit;
}
if ($mode === 'single' && !isset($_GET['fixture_single'])) {
    header('Location: ' . $_SERVER['REQUEST_URI'] . (strpos($_SERVER['REQUEST_URI'], '?') === false ? '?' : '&') . 'fixture_single=1', true, 302);
    exit;
}
if ($mode === 'cross-origin') {
    header('Location: http://127.0.0.1:8087/waf-recovery.php?mode=receiver&run=' . rawurlencode($run), true, 302);
    exit;
}
$cleared = isset($_COOKIE['nox_jst_v1']) && $_COOKIE['nox_jst_v1'] === $clearance;
if ($mode === 'off' || $mode === 'single' || ($cleared && $mode !== 'permanent')) {
    if ($isImage) {
        $n = max(1, min(9, (int)(isset($_GET['n']) ? $_GET['n'] : 1)));
        header('Content-Type: image/png');
        $image = imagecreatetruecolor(800, 1000);
        imagefill($image, 0, 0, imagecolorallocate($image, 40 + $n * 15, 80 + $n * 10, 130));
        imagestring($image, 5, 80, 450, 'LOCAL WAF FIXTURE ' . $n, imagecolorallocate($image, 255, 255, 255));
        $slow = isset($config['image_slow_ms']) ? max(0, min(2000, (int)$config['image_slow_ms'])) : 0;
        if ($slow > 0) {
            // Uncompressed PNG is still a real image, large enough to observe
            // incremental progress and cancel without inventing invalid bytes.
            ob_start(); imagepng($image, null, 0); $png = ob_get_clean();
            header('Content-Length: ' . strlen($png));
            for ($offset = 0; $offset < strlen($png); $offset += 65536) {
                echo substr($png, $offset, 65536);
                flush();
                if (connection_aborted()) { break; }
                usleep($slow * 1000);
            }
        } else { imagepng($image); }
        imagedestroy($image);
        exit;
    }
    header('Content-Type: text/html; charset=utf-8');
    echo '<!doctype html><title>Local fixture success</title><p>Success</p>';
    exit;
}
if ($mode === 'self') {
    header('Location: ' . $_SERVER['REQUEST_URI'], true, 302);
    exit;
}
// Hold only a blocked response so another real request can commit clearance
// first. The replay returns through the success branch above without a delay.
$responseDelay = isset($_GET['fixture_response_delay_ms']) ? max(0, min(8000, (int)$_GET['fixture_response_delay_ms'])) : 0;
if ($responseDelay > 0) { usleep($responseDelay * 1000); }
http_response_code(405);
header('Content-Type: text/html; charset=utf-8');
if ($mode === 'headers') { header('bdwaf-request-id: local-fixture'); }
echo '<!doctype html><title>Local challenge fixture</title><!-- window.__noxexpire nox_jst_v1 -->';
if ($mode === 'interaction') {
    echo '<input name="captcha" placeholder="captcha"><button>Verify</button>';
} elseif ($mode !== 'no-cookie' && $mode !== 'permanent') {
    $delay = $mode === 'delay' ? 1500 : 50;
    $cookie = json_encode('nox_jst_v1=' . $clearance . '; Path=/; Max-Age=180; SameSite=Lax');
    echo '<script>setTimeout(function(){document.cookie=' . $cookie . ';},' . $delay . ');</script>';
}
