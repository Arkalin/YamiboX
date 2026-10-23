<?php
// Deploy beside Discuz class_core only in the disposable local runtime.
if (PHP_SAPI !== 'cli' || getenv('YAMIBO_LOCAL_RUNTIME') !== '1') { exit("LOCAL_CLI_ONLY\n"); }
$run = isset($argv[2]) ? $argv[2] : '';
$fixtureAction = isset($argv[1]) ? $argv[1] : '';
$variant = isset($argv[3]) ? $argv[3] : '';
if (!preg_match('/\A[a-zA-Z0-9_-]{1,64}\z/', $run)) { exit("INVALID_RUN\n"); }
if ($variant !== '' && !preg_match('/\A[a-zA-Z0-9_-]{1,32}\z/', $variant)) { exit("INVALID_VARIANT\n"); }
define('WAF_FIXTURE_ACTION', $fixtureAction);
define('WAF_FIXTURE_RUN', $run);
define('WAF_FIXTURE_VARIANT', $variant);
define('CURSCRIPT', 'forum');
define('APPTYPEID', 2);
define('HOOKTYPE', 'hookscript');
define('CACHE_FORBIDDEN', true);
$_SERVER = array_merge($_SERVER, array('REMOTE_ADDR' => '127.0.0.1', 'REMOTE_PORT' => '0',
    'SERVER_ADDR' => '127.0.0.1', 'SERVER_NAME' => '127.0.0.1', 'SERVER_PORT' => '8088',
    'HTTP_HOST' => '127.0.0.1:8088', 'REQUEST_METHOD' => 'GET', 'REQUEST_URI' => '/',
    'SCRIPT_NAME' => '/waf-recovery-content.php'));
require __DIR__ . '/source/class/class_core.php';
C::app()->cachelist = array('plugin', 'setting', 'usergroups', 'forums', 'posttable_info');
C::app()->init();
require_once libfile('function/forum');
$run = WAF_FIXTURE_RUN;
$fixtureAction = WAF_FIXTURE_ACTION;
$variant = WAF_FIXTURE_VARIANT;
$subject = '[WAF local] ' . $run . ($variant === '' ? '' : ' [' . $variant . ']');
$existing = DB::fetch_first('SELECT tid FROM ' . DB::table('forum_thread') . ' WHERE subject=%s', array($subject));
if ($fixtureAction === 'delete') {
    require_once libfile('function/delete');
    if ($existing) {
        $tid = intval($existing['tid']);
        deletethread(array($tid));
        C::t('forum_threaddisablepos')->delete($tid);
    }
    if ($variant === 'attachments') {
        $mapping = sys_get_temp_dir() . '/yamibox-waf-attachments-' . $run . '.json';
        if (is_file($mapping)) { unlink($mapping); }
        $directory = __DIR__ . '/data/attachment/forum/waf-fixture-' . $run;
        if (is_dir($directory) && count(scandir($directory)) === 2) { rmdir($directory); }
    }
    exit("DELETED\n");
}
if ($fixtureAction !== 'create') { exit("INVALID_ACTION\n"); }
if ($existing) { exit('TID=' . $existing['tid'] . "\n"); }
if ($variant === 'attachments') {
    $attachmentRoot = __DIR__ . '/data/attachment/forum';
    if (!is_writable($attachmentRoot)) { exit("ATTACHMENT_DIRECTORY_NOT_WRITABLE\n"); }
    foreach (array('normal', 'large', 'slow') as $kind) {
        if (file_exists($attachmentRoot . '/waf-fixture-' . $run . '/' . $kind . '.txt')) {
            exit("ATTACHMENT_EXISTS\n");
        }
    }
}
$message = 'Disposable local WAF image verification.';
for ($n = 1; $n <= 6; $n++) {
    $port = strncmp($variant, 'cross', 5) === 0 ? '8087' : '8088';
    $message .= "\n[img]http://127.0.0.1:" . $port . '/waf-recovery.php?mode=image&run=' . $run . '&n=' . $n
        . ($variant === '' ? '' : '&variant=' . $variant) . '[/img]';
}
if ($variant === 'attachments') {
    $message = 'Disposable native attachment queue verification.';
}
$tid = C::t('forum_thread')->insert(array('fid' => 2, 'posttableid' => 0, 'author' => 'admin',
    'authorid' => 1, 'subject' => $subject, 'dateline' => TIMESTAMP, 'lastpost' => TIMESTAMP,
    'lastposter' => 'admin', 'displayorder' => 0, 'special' => 0, 'maxposition' => 1), true);
$pid = insertpost(array('fid' => 2, 'tid' => $tid, 'first' => 1, 'author' => 'admin', 'authorid' => 1,
    'subject' => $subject, 'dateline' => TIMESTAMP, 'message' => $message, 'useip' => '127.0.0.1',
    'position' => 1, 'invisible' => 0));
if ($variant === 'attachments') {
    $directory = 'waf-fixture-' . $run;
    $absoluteDirectory = __DIR__ . '/data/attachment/forum/' . $directory;
    if (!is_dir($absoluteDirectory)) { mkdir($absoluteDirectory); }
    $attachments = array();
    foreach (array('normal', 'large', 'slow') as $kind) {
        $attachment = $directory . '/' . $kind . '.txt';
        $file = fopen(__DIR__ . '/data/attachment/forum/' . $attachment, 'x');
        if (!$file) { exit("ATTACHMENT_EXISTS\n"); }
        fwrite($file, str_repeat('Local fixture. ', 64)); fclose($file);
        $aid = C::t('forum_attachment')->insert(array('tid' => $tid, 'pid' => $pid, 'uid' => 1,
            'tableid' => getattachtableid($tid)), true);
        C::t('forum_attachment_n')->insert_attachment(getattachtableid($tid), array('aid' => $aid,
            'tid' => $tid, 'pid' => $pid, 'uid' => 1, 'dateline' => TIMESTAMP,
            'filename' => 'local-waf-' . $kind . '.txt', 'filesize' => 960, 'attachment' => $attachment,
            'isimage' => 0, 'remote' => 0, 'thumb' => 0));
        $attachments[$aid] = $kind;
        $message .= "\n[attach]" . $aid . '[/attach]';
    }
    C::t('forum_thread')->update($tid, array('attachment' => 2));
    C::t('forum_post')->update(0, $pid, array('attachment' => 2, 'message' => $message));
    file_put_contents(sys_get_temp_dir() . '/yamibox-waf-attachments-' . $run . '.json', json_encode($attachments));
    echo 'ATTACHMENTS=' . json_encode($attachments) . "\n";
}
C::t('forum_threaddisablepos')->insert(array('tid' => $tid), false, true);
echo 'TID=' . $tid . "\n";
