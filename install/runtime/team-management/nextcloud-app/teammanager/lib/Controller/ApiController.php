<?php
declare(strict_types=1);
namespace OCA\TeamManager\Controller;
use OCA\TeamManager\Service\ControlClient;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\Attribute\NoAdminRequired;
use OCP\AppFramework\Http\DataResponse;
use OCP\IGroupManager;
use OCP\IRequest;
use OCP\IUserSession;
class ApiController extends Controller {
    public function __construct(string $appName, IRequest $request, private ControlClient $client, private IUserSession $session, private IGroupManager $groups) { parent::__construct($appName,$request); }
    private function actor(): ?string {
        $u=$this->session->getUser(); if ($u===null) return null; $id=$u->getUID();
        return ($this->groups->isAdmin($id)||$this->groups->isInGroup($id,'gestao')) ? $id : null;
    }
    private function call(array $payload): DataResponse {
        $actor=$this->actor(); if ($actor===null) return new DataResponse(['ok'=>false,'error'=>'Acesso restrito à Gestão e Admin.'],403);
        $payload['actor']=$actor;
        try { return new DataResponse($this->client->request($payload)); }
        catch (\Throwable $e) { return new DataResponse(['ok'=>false,'error'=>$e->getMessage()],503); }
    }
    #[NoAdminRequired]
    public function status(): DataResponse { return $this->call(['action'=>'status']); }
    #[NoAdminRequired]
    public function createEmployee(string $uid, string $name, string $email, string $sector): DataResponse {
        return $this->call(['action'=>'create_employee','uid'=>$uid,'name'=>$name,'email'=>$email,'sector'=>$sector]);
    }
    #[NoAdminRequired]
    public function saveEmail(string $uid, string $email): DataResponse {
        return $this->call(['action'=>'save_email','uid'=>$uid,'email'=>$email]);
    }
    #[NoAdminRequired]
    public function changeSector(string $uid, string $sector): DataResponse {
        return $this->call(['action'=>'change_sector','uid'=>$uid,'sector'=>$sector]);
    }
    #[NoAdminRequired]
    public function offboardEmployee(string $uid, string $confirm): DataResponse {
        return $this->call(['action'=>'offboard_employee','uid'=>$uid,'confirm'=>$confirm]);
    }
}
