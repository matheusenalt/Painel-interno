<?php
declare(strict_types=1);

namespace OCA\PortalBackup\Controller;

use OCA\PortalBackup\Service\ControlClient;
use OCP\AppFramework\Controller;
use OCP\AppFramework\Http\DataResponse;
use OCP\IRequest;

class ApiController extends Controller {
    private const INBOX = '/portal-restore-inbox';

    public function __construct(
        string $appName,
        IRequest $request,
        private ControlClient $client,
    ) {
        parent::__construct($appName, $request);
    }

    public function status(): DataResponse {
        return $this->call(['action' => 'status']);
    }

    public function backups(): DataResponse {
        return $this->call(['action' => 'list_backups']);
    }

    public function startBackup(): DataResponse {
        return $this->call(['action' => 'start_backup']);
    }

    public function restoreLocal(string $kind, string $name): DataResponse {
        if (!in_array($kind, ['daily', 'weekly'], true)) {
            return new DataResponse(['ok' => false, 'error' => 'Origem de backup inválida.'], 400);
        }
        if (!preg_match('/^portal(?:-weekly)?-[0-9]{8}-[0-9]{6}\.tar\.gz$/', $name)) {
            return new DataResponse(['ok' => false, 'error' => 'Nome de backup inválido.'], 400);
        }
        return $this->call(['action' => 'start_restore', 'source' => 'local', 'kind' => $kind, 'name' => $name]);
    }

    public function restoreUpload(): DataResponse {
        $archive = $this->request->getUploadedFile('backup');
        if (empty($archive) || (int)($archive['error'] ?? UPLOAD_ERR_NO_FILE) !== UPLOAD_ERR_OK) {
            return new DataResponse(['ok' => false, 'error' => 'Arquivo de backup não recebido ou excede o limite configurado.'], 400);
        }
        $original = (string)($archive['name'] ?? 'backup.tar.gz');
        if (!str_ends_with(strtolower($original), '.tar.gz')) {
            return new DataResponse(['ok' => false, 'error' => 'Envie um arquivo .tar.gz gerado pelo Portal Interno.'], 400);
        }
        $tmp = (string)($archive['tmp_name'] ?? '');
        if ($tmp === '' || !is_uploaded_file($tmp)) {
            return new DataResponse(['ok' => false, 'error' => 'Upload temporário inválido.'], 400);
        }

        $token = bin2hex(random_bytes(12));
        $basename = 'restore-' . $token . '.tar.gz';
        $dest = self::INBOX . '/' . $basename;
        if (!is_dir(self::INBOX) || !is_writable(self::INBOX)) {
            return new DataResponse(['ok' => false, 'error' => 'Área de staging da restauração não está gravável.'], 500);
        }
        if (!move_uploaded_file($tmp, $dest)) {
            return new DataResponse(['ok' => false, 'error' => 'Falha ao mover o backup para a área segura de staging.'], 500);
        }
        @chmod($dest, 0660);

        $checksumVerified = false;
        $checksum = $this->request->getUploadedFile('checksum');
        if (!empty($checksum) && (int)($checksum['error'] ?? UPLOAD_ERR_NO_FILE) === UPLOAD_ERR_OK) {
            $sumTmp = (string)($checksum['tmp_name'] ?? '');
            $raw = $sumTmp !== '' ? @file_get_contents($sumTmp) : false;
            if ($raw === false || !preg_match('/\b([a-fA-F0-9]{64})\b/', $raw, $m)) {
                @unlink($dest);
                return new DataResponse(['ok' => false, 'error' => 'Arquivo .sha256 inválido.'], 400);
            }
            $expected = strtolower($m[1]);
            file_put_contents($dest . '.sha256', $expected . '  ' . $basename . "\n", LOCK_EX);
            @chmod($dest . '.sha256', 0660);
            $checksumVerified = true;
        }

        $response = $this->call([
            'action' => 'start_restore',
            'source' => 'upload',
            'name' => $basename,
            'original_name' => $original,
        ]);
        $data = $response->getData();
        if (is_array($data)) {
            $data['checksum_provided'] = $checksumVerified;
            $response->setData($data);
        }
        return $response;
    }

    private function call(array $payload): DataResponse {
        try {
            return new DataResponse($this->client->request($payload));
        } catch (\Throwable $e) {
            return new DataResponse(['ok' => false, 'error' => $e->getMessage()], 503);
        }
    }
}
