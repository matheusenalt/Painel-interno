<?php
declare(strict_types=1);
namespace OCA\TeamManager\Service;
class ControlClient {
    private const SOCKET = '/run/portal-control/team.sock';
    public function request(array $payload): array {
        $errno=0; $errstr='';
        $fp=@stream_socket_client('unix://' . self::SOCKET, $errno, $errstr, 3.0);
        if ($fp === false) throw new \RuntimeException('Serviço Gestão de Equipe indisponível.');
        stream_set_timeout($fp, 15);
        $body=json_encode($payload, JSON_UNESCAPED_SLASHES|JSON_UNESCAPED_UNICODE);
        if ($body===false || fwrite($fp, $body."\n")===false) { fclose($fp); throw new \RuntimeException('Falha ao enviar solicitação.'); }
        $line=fgets($fp, 1048576); fclose($fp);
        if ($line===false) throw new \RuntimeException('Serviço Gestão de Equipe não respondeu.');
        $data=json_decode($line, true);
        if (!is_array($data)) throw new \RuntimeException('Resposta inválida do serviço Gestão de Equipe.');
        if (($data['ok']??false)!==true) throw new \RuntimeException((string)($data['error']??'Operação recusada.'));
        return $data;
    }
}
