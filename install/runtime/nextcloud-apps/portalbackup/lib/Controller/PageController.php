<?php
declare(strict_types=1);

namespace OCA\PortalBackup\Controller;

use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\Attribute\NoCSRFRequired;
use OCP\AppFramework\Http\TemplateResponse;
use OCP\IRequest;
use OCP\Util;

class PageController extends Controller {
    public function __construct(string $appName, IRequest $request) {
        parent::__construct($appName, $request);
    }

    #[NoCSRFRequired]
    public function index(): TemplateResponse {
        Util::addStyle($this->appName, 'admin');
        Util::addScript($this->appName, 'admin');
        return new TemplateResponse($this->appName, 'main');
    }
}
