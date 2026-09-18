<?php
/**
 * Portal Interno - padronização dos e-mails do FoxDesk em pt-BR.
 *
 * Este patch é intencionalmente idempotente e foi validado contra FoxDesk 0.3.x.
 * Ele mantém os idiomas originais do projeto e acrescenta a camada visual pt-BR
 * necessária para os e-mails usados pelo portal.
 */

$root = $argv[1] ?? '/var/www/html';
$root = rtrim($root, '/');

function fail_patch(string $message): void
{
    fwrite(STDERR, "ERRO: {$message}\n");
    exit(1);
}

function read_required(string $path): string
{
    if (!is_file($path)) {
        fail_patch("arquivo não encontrado: {$path}");
    }
    $content = file_get_contents($path);
    if ($content === false) {
        fail_patch("não foi possível ler: {$path}");
    }
    return $content;
}

function write_required(string $path, string $content): void
{
    if (file_put_contents($path, $content) === false) {
        fail_patch("não foi possível gravar: {$path}");
    }
}

function insert_before_once(string $content, string $marker, string $insert, string $alreadyMarker, string $label): string
{
    if (strpos($content, $alreadyMarker) !== false) {
        echo "[pt-BR] {$label}: já aplicado.\n";
        return $content;
    }
    $pos = strpos($content, $marker);
    if ($pos === false) {
        fail_patch("ponto de inserção não encontrado para {$label}");
    }
    echo "[pt-BR] {$label}: aplicado.\n";
    return substr($content, 0, $pos) . $insert . "\n" . substr($content, $pos);
}

$mailer = $root . '/includes/mailer.php';
$renderer = $root . '/includes/modules/email/email-renderer.php';
$lang = $root . '/includes/lang/pt-BR.php';

/* -------------------------------------------------------------------------
 * 1) Prazo próximo / vencido: o FoxDesk 0.3.x não traz bloco pt-BR aqui.
 * ---------------------------------------------------------------------- */
$s = read_required($mailer);

$duePtbr = <<<'CODE'
    $copy['pt-BR'] = [
        'subject_overdue' => 'Chamado atrasado: {ticket_code} - {title}',
        'subject_due_soon' => 'Prazo próximo: {ticket_code} - {title}',
        'body_overdue' => 'Este chamado está com o prazo vencido.',
        'body_due_soon' => 'O prazo deste chamado está próximo.',
        'label_ticket' => 'Chamado',
        'label_due_date' => 'Prazo',
        'label_status' => 'Status',
        'label_view_ticket' => 'Ver chamado'
    ];
CODE;

$s = insert_before_once(
    $s,
    "    \$copy['ar'] = [",
    $duePtbr,
    "\$copy['pt-BR'] = [",
    'lembretes de prazo'
);
write_required($mailer, $s);

/* -------------------------------------------------------------------------
 * 2) Renderer HTML: traduz cabeçalho, CTA, motivo, preheader e rodapé
 *    conforme o idioma efetivo do destinatário.
 * ---------------------------------------------------------------------- */
$s = read_required($renderer);

// Migra o nome usado no patch manual validado em produção, caso este arquivo
// venha de um snapshot anterior à consolidação do repositório.
if (strpos($s, 'function foxdesk_localize_email_payload') !== false
    && strpos($s, 'function foxdesk_gl_localize_email_payload') === false) {
    $s = str_replace('foxdesk_localize_email_payload', 'foxdesk_gl_localize_email_payload', $s);
    echo "[pt-BR] patch manual anterior detectado e normalizado.\n";
}

$helper = <<<'CODE'
function foxdesk_gl_localize_email_payload(array $payload, string $language): array
{
    if ($language !== 'pt-BR') {
        return $payload;
    }

    $translations = [
        'Ticket update' => 'Atualização do chamado',
        'Password reset' => 'Redefinição de senha',
        'Status changed' => 'Status alterado',
        'Status updated' => 'Status atualizado',
        'New comment' => 'Novo comentário',
        'New ticket' => 'Novo chamado',
        'Ticket received' => 'Chamado recebido',
        'Assigned to you' => 'Chamado atribuído a você',
        'Recurring task assigned' => 'Tarefa recorrente atribuída',
        'Overdue ticket' => 'Chamado atrasado',
        'Due soon' => 'Prazo próximo',
        'Timer reminder' => 'Lembrete de cronômetro',
        'Open ticket' => 'Abrir chamado',
        'View ticket' => 'Ver chamado',
        'View comment' => 'Ver comentário',
        'Reset password' => 'Redefinir senha',
        'You are receiving this because you are connected to this ticket.'
            => 'Você recebeu este e-mail porque está relacionado a este chamado.',
        'You are receiving this because a password reset was requested.'
            => 'Você recebeu este e-mail porque foi solicitada uma redefinição de senha.',
        'This email is sent only for customer-facing status changes or updates with a comment/time entry.'
            => 'Este e-mail foi enviado devido a uma alteração ou atualização deste chamado.',
        'You are receiving this because you created, are assigned to, commented on, or were copied on this ticket.'
            => 'Você recebeu este e-mail porque está relacionado a este chamado.',
        'You are receiving this because you are a staff member for this FoxDesk.'
            => 'Você recebeu este e-mail porque faz parte da equipe responsável pelos chamados.',
        'You are receiving this because this ticket was submitted for you.'
            => 'Você recebeu este e-mail porque este chamado foi aberto para você.',
        'You are receiving this because this ticket was assigned to you.'
            => 'Você recebeu este e-mail porque este chamado foi atribuído a você.',
        'You are receiving this because you are assigned to this ticket.'
            => 'Você recebeu este e-mail porque este chamado está atribuído a você.',
        'You are receiving this because your timer has been running for a long time.'
            => 'Você recebeu este e-mail porque seu cronômetro está ativo há muito tempo.',
        'You are receiving this confirmation because your email created a new ticket.'
            => 'Você recebeu esta confirmação porque seu e-mail criou um novo chamado.',
        'Open FoxDesk to review this ticket update.'
            => 'Abra o FoxDesk para consultar esta atualização.',
        'Open FoxDesk to review the update.'
            => 'Abra o FoxDesk para consultar esta atualização.'
    ];

    foreach (['eyebrow', 'cta_label', 'reason', 'preheader'] as $key) {
        if (isset($payload[$key], $translations[$payload[$key]])) {
            $payload[$key] = $translations[$payload[$key]];
        }
    }

    return $payload;
}
CODE;

$s = insert_before_once(
    $s,
    'function foxdesk_render_ticket_email_html(array $payload): string',
    $helper,
    'function foxdesk_gl_localize_email_payload',
    'localizador do renderer HTML'
);

$alignNeedle = "    \$align = \$direction === 'rtl' ? 'right' : 'left';";
if (strpos($s, $alignNeedle) === false) {
    fail_patch('linha de alinhamento do renderer não encontrada');
}

if (strpos($s, '$payload = foxdesk_gl_localize_email_payload($payload, $language);') === false) {
    $s = str_replace(
        $alignNeedle,
        $alignNeedle . "\n    \$payload = foxdesk_gl_localize_email_payload(\$payload, \$language);",
        $s
    );
    echo "[pt-BR] localização do payload HTML: aplicada.\n";
} else {
    echo "[pt-BR] localização do payload HTML: já aplicada.\n";
}

if (strpos($s, '$footer_text = $language ===') === false) {
    $call = '    $payload = foxdesk_gl_localize_email_payload($payload, $language);';
    $footerDefinition = <<<'CODE'
    $footer_text = $language === 'pt-BR'
        ? 'Os e-mails do FoxDesk são resumidos. Consulte o chamado no sistema para visualizar o histórico completo.'
        : 'FoxDesk keeps ticket emails short. Reply in the app when you need the full history.';
CODE;
    if (strpos($s, $call) === false) {
        fail_patch('chamada do localizador não encontrada para inserir o rodapé');
    }
    $s = str_replace($call, $call . "\n" . $footerDefinition, $s);
    echo "[pt-BR] seleção de rodapé por idioma: aplicada.\n";
} else {
    echo "[pt-BR] seleção de rodapé por idioma: já aplicada.\n";
}

$footerStyle = 'margin:16px 0 0;color:#94a3b8;font-size:12px;line-height:18px';
$footerOriginal = ". '</div><p style=\"{$footerStyle}\">FoxDesk keeps ticket emails short. Reply in the app when you need the full history.</p></div></body></html>';";
$footerManualPtbr = ". '</div><p style=\"{$footerStyle}\">Os e-mails do FoxDesk são resumidos. Consulte o chamado no sistema para visualizar o histórico completo.</p></div></body></html>';";
$footerDynamic = ". '</div><p style=\"{$footerStyle}\">' . foxdesk_email_escape(\$footer_text) . '</p></div></body></html>';";

if (strpos($s, $footerOriginal) !== false) {
    $s = str_replace($footerOriginal, $footerDynamic, $s);
    echo "[pt-BR] rodapé HTML original convertido para modo multilíngue.\n";
} elseif (strpos($s, $footerManualPtbr) !== false) {
    $s = str_replace($footerManualPtbr, $footerDynamic, $s);
    echo "[pt-BR] rodapé do patch manual convertido para modo multilíngue.\n";
} elseif (strpos($s, 'foxdesk_email_escape($footer_text)') !== false) {
    echo "[pt-BR] rodapé HTML: já aplicado.\n";
} else {
    fail_patch('rodapé esperado do renderer não foi encontrado');
}

write_required($renderer, $s);

/* -------------------------------------------------------------------------
 * 3) Normalização de nomenclatura no pt-BR quando a tradução upstream usa
 *    termos diferentes do padrão pt-BR adotado. Só altera se a chave existir.
 * ---------------------------------------------------------------------- */
$s = read_required($lang);
$replacements = [
    "'New ticket' => 'Novo ingresso'" => "'New ticket' => 'Novo chamado'",
    "'View ticket' => 'Ver tíquete'" => "'View ticket' => 'Ver chamado'",
    "'Open tickets' => 'Ingressos abertos'" => "'Open tickets' => 'Chamados abertos'",
    "'New tickets' => 'Novos ingressos'" => "'New tickets' => 'Novos chamados'",
];
$count = 0;
foreach ($replacements as $old => $new) {
    if (strpos($s, $old) !== false) {
        $s = str_replace($old, $new, $s);
        $count++;
    }
}
write_required($lang, $s);
echo "[pt-BR] nomenclatura do idioma: {$count} ajuste(s) aplicado(s) nesta versão.\n";

echo "[pt-BR] Patch público de e-mails concluído.\n";
