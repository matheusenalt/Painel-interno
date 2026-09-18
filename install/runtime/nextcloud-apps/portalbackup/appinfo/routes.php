<?php
declare(strict_types=1);

return [
    'routes' => [
        ['name' => 'page#index', 'url' => '/', 'verb' => 'GET'],
        ['name' => 'api#status', 'url' => '/api/status', 'verb' => 'GET'],
        ['name' => 'api#backups', 'url' => '/api/backups', 'verb' => 'GET'],
        ['name' => 'api#startBackup', 'url' => '/api/backup', 'verb' => 'POST'],
        ['name' => 'api#restoreLocal', 'url' => '/api/restore/local', 'verb' => 'POST'],
        ['name' => 'api#restoreUpload', 'url' => '/api/restore/upload', 'verb' => 'POST'],
    ],
];
