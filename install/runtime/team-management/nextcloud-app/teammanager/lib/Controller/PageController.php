<?php
declare(strict_types=1);
namespace OCA\TeamManager\Controller;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\Attribute\NoCSRFRequired;
use OCP\AppFramework\Http\TemplateResponse;
use OCP\IGroupManager;
use OCP\IRequest;
use OCP\IUserSession;
use OCP\Util;
class PageController extends Controller {
    public function __construct(string $appName, IRequest $request, private IUserSession $session, private IGroupManager $groups) { parent::__construct($appName,$request); }
    private function allowed(): bool {
        $u=$this->session->getUser(); if ($u===null) return false; $id=$u->getUID();
        return $this->groups->isAdmin($id) || $this->groups->isInGroup($id,'gestao');
    }
    #[NoAdminRequired]
    #[NoCSRFRequired]
    public function index(): TemplateResponse {
        if (!$this->allowed()) { $r=new TemplateResponse($this->appName,'forbidden'); $r->setStatus(403); return $r; }
        Util::addStyle($this->appName,'app'); Util::addScript($this->appName,'app');
        return new TemplateResponse($this->appName,'main');
    }
}
