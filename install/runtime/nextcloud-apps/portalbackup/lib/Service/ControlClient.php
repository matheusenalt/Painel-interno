<?php
declare(strict_types=1);

namespace OCA\PortalBackup\Service;

class ControlClient {
    private const SOCKET = '/run/portal-control/control.sock';

    public function request(array $payload): array {
        $errno = 0;
        $errstr = '';
        $fp = @stream_socket_client('unix://' . self::SOCKET, $errno, $errstr, 3.0);
        if ($fp === false) {
            throw new \RuntimeException('Serviço de controle indisponível. Verifique portal-control.service.');
        }
        stream_set_timeout($fp, 5);
        $body = json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        if ($body === false || fwrite($fp, $body . "\n") === false) {
            fclose($fp);
            throw new \RuntimeException('Falha ao enviar solicitação ao serviço de controle.');
        }
        $line = fgets($fp, 1048576);
        fclose($fp);
        if ($line === false) {
            throw new \RuntimeException('Serviço de controle não respondeu.');
        }
        $data = json_decode($line, true);
        if (!is_array($data)) {
            throw new \RuntimeException('Resposta inválida do serviço de controle.');
        }
        if (($data['ok'] ?? false) !== true) {
            throw new \RuntimeException((string)($data['error'] ?? 'Operação recusada pelo serviço de controle.'));
        }
        return $data;
    }
}
