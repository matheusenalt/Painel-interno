<div id="portalbackup-app" class="portalbackup-wrap">
    <div class="portalbackup-header">
        <h2>Backup e Restauração</h2>
        <p class="portalbackup-muted">Operação administrativa do Portal Interno. Em desastre de infraestrutura, use a restauração pelo terminal ou o instalador de recuperação.</p>
    </div>

    <div id="portalbackup-flash" class="portalbackup-flash" hidden></div>

    <section class="portalbackup-card portalbackup-status-card">
        <h3>Status da operação</h3>
        <p class="portalbackup-muted">Acompanhe aqui o backup ou a restauração em andamento.</p>
        <pre id="portalbackup-job">Nenhuma operação em andamento.</pre>
        <div class="portalbackup-restore-notice">
            <strong>Durante uma restauração:</strong> o Nextcloud ficará temporariamente indisponível enquanto os dados, bancos e serviços são restaurados. Quando o portal voltar, atualize a página e faça login novamente caso seja solicitado.
        </div>
    </section>

    <section class="portalbackup-card">
        <h3>Backup</h3>
        <div id="portalbackup-last-backup" class="portalbackup-status">Carregando…</div>
        <button id="portalbackup-start" class="primary">Fazer backup agora</button>
    </section>

    <section class="portalbackup-card">
        <h3>Restaurar backup local</h3>
        <p>Use um snapshot que ainda está na VPS. Antes da restauração, o sistema cria automaticamente um backup do estado atual.</p>
        <div class="portalbackup-warning">O painel pode sair do ar por alguns instantes. Depois que voltar, atualize a página e faça login novamente se necessário.</div>
        <select id="portalbackup-local-select"></select>
        <button id="portalbackup-restore-local" class="danger">Restaurar selecionado</button>
    </section>

    <section class="portalbackup-card">
        <h3>Restaurar backup externo</h3>
        <p>Selecione o <code>.tar.gz</code> salvo externamente. O arquivo <code>.sha256</code> é opcional, mas recomendado.</p>
        <div class="portalbackup-warning">O arquivo será validado antes do rollback e um snapshot de segurança do estado atual será criado automaticamente.</div>
        <label>Backup (.tar.gz)</label>
        <input id="portalbackup-upload" type="file" accept=".gz,application/gzip">
        <label>Checksum (.sha256, opcional)</label>
        <input id="portalbackup-checksum" type="file" accept=".sha256,text/plain">
        <button id="portalbackup-restore-upload" class="danger">Enviar, validar e restaurar</button>
    </section>
</div>
