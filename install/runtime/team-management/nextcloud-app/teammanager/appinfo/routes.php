<?php
declare(strict_types=1);
return ['routes' => [
    ['name' => 'page#index', 'url' => '/', 'verb' => 'GET'],
    ['name' => 'api#status', 'url' => '/api/status', 'verb' => 'GET'],
    ['name' => 'api#createEmployee', 'url' => '/api/employee', 'verb' => 'POST'],
    ['name' => 'api#saveEmail', 'url' => '/api/email', 'verb' => 'POST'],
    ['name' => 'api#changeSector', 'url' => '/api/sector', 'verb' => 'POST'],
    ['name' => 'api#offboardEmployee', 'url' => '/api/offboard', 'verb' => 'POST'],
]];
