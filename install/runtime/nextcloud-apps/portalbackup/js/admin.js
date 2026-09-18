(() => {
    const base = OC.generateUrl('/apps/portalbackup');
    const $ = (id) => document.getElementById(id);
    const fmtBytes = (n) => {
        if (!Number.isFinite(Number(n))) return '-';
        const units = ['B', 'KB', 'MB', 'GB', 'TB'];
        let v = Number(n), i = 0;
        while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
        return `${v.toFixed(i > 1 ? 1 : 0)} ${units[i]}`;
    };
    let lastFinishedKey = null;
    const notify = (msg, error = false, info = false) => {
        const box = $('portalbackup-flash');
        if (!box) return;
        box.textContent = msg;
        box.className = `portalbackup-flash ${error ? 'error' : (info ? 'info' : 'success')}`;
        box.hidden = false;
    };
    const request = async (path, options = {}) => {
        const headers = new Headers(options.headers || {});
        headers.set('requesttoken', OC.requestToken);
        const r = await fetch(base + path, {...options, headers, credentials: 'same-origin'});
        let data;
        try { data = await r.json(); } catch (_) { throw new Error(`Resposta HTTP inválida (${r.status})`); }
        if (!r.ok || data.ok === false) throw new Error(data.error || `HTTP ${r.status}`);
        return data;
    };
    const setBusy = (busy) => {
        ['portalbackup-start','portalbackup-restore-local','portalbackup-restore-upload'].forEach(id => { const e=$(id); if(e) e.disabled=busy; });
    };
    const refreshBackups = async () => {
        const data = await request('/api/backups');
        const select = $('portalbackup-local-select');
        select.innerHTML = '';
        const list = data.backups || [];
        if (!list.length) {
            const o = document.createElement('option'); o.textContent='Nenhum backup local disponível'; o.value=''; select.appendChild(o);
            $('portalbackup-last-backup').textContent = 'Nenhum snapshot local encontrado.';
            return;
        }
        list.forEach(b => {
            const o = document.createElement('option');
            o.value = `${b.kind}|${b.name}`;
            const d = new Date(Number(b.mtime) * 1000);
            o.textContent = `${b.kind === 'weekly' ? 'Semanal' : 'Diário'} — ${d.toLocaleString()} — ${fmtBytes(b.size)}${b.has_checksum ? ' — SHA256' : ''}`;
            select.appendChild(o);
        });
        const b = list[0];
        $('portalbackup-last-backup').textContent = `Último snapshot local: ${new Date(Number(b.mtime)*1000).toLocaleString()} (${fmtBytes(b.size)})`;
    };
    const refreshStatus = async () => {
        try {
            const data = await request('/api/status');
            const job = data.job;
            if (!job) { $('portalbackup-job').textContent='Nenhuma operação registrada.'; setBusy(false); return; }
            $('portalbackup-job').textContent = [
                `Tipo: ${job.action}`,
                `Status: ${job.status}`,
                `Início: ${job.started_at || '-'}`,
                `Fim: ${job.finished_at || '-'}`,
                job.message ? `Mensagem: ${job.message}` : '',
                job.log_tail ? `\n${job.log_tail}` : ''
            ].filter(Boolean).join('\n');
            const busy = ['queued','running'].includes(job.status);
            setBusy(busy);
            if (busy) {
                notify(job.action === 'restore' ? 'Restauração em andamento. O painel pode ficar temporariamente indisponível.' : 'Backup em andamento. Aguarde a conclusão.', false, true);
            } else {
                const key = `${job.action}|${job.started_at || ''}|${job.finished_at || ''}|${job.status}`;
                if (key !== lastFinishedKey) {
                    lastFinishedKey = key;
                    if (job.status === 'success' || job.status === 'ok') {
                        notify(job.action === 'restore' ? 'Restauração concluída. Se sua sessão expirou, atualize a página e faça login novamente.' : 'Backup concluído com sucesso.');
                    } else if (job.status === 'failed') {
                        notify('A operação terminou com falha. Revise o log abaixo antes de continuar.', true);
                    }
                }
                await refreshBackups();
            }
        } catch (e) {
            $('portalbackup-job').textContent = `Controle indisponível: ${e.message}`;
        }
    };
    const confirmRestore = (label) => window.confirm(`Restaurar ${label}?\n\nO portal ficará temporariamente indisponível. Antes do rollback será criado um backup automático do estado atual. Quando o portal voltar, atualize a página e faça login novamente se necessário.`);

    document.addEventListener('DOMContentLoaded', async () => {
        try { await refreshBackups(); } catch (e) { notify(e.message, true); }
        await refreshStatus();

        $('portalbackup-start').addEventListener('click', async () => {
            try { setBusy(true); await request('/api/backup', {method:'POST'}); notify('Backup iniciado.'); await refreshStatus(); }
            catch(e){ setBusy(false); notify(e.message, true); }
        });

        $('portalbackup-restore-local').addEventListener('click', async () => {
            const v = $('portalbackup-local-select').value; if (!v) return;
            const [kind,name] = v.split('|');
            if (!confirmRestore(name)) return;
            try {
                setBusy(true);
                const body = new URLSearchParams({kind,name});
                await request('/api/restore/local', {method:'POST', headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'}, body});
                notify('Restauração iniciada. A página pode ficar temporariamente indisponível.');
                await refreshStatus();
            } catch(e){ setBusy(false); notify(e.message, true); }
        });

        $('portalbackup-restore-upload').addEventListener('click', async () => {
            const file = $('portalbackup-upload').files[0];
            if (!file) { notify('Selecione o arquivo .tar.gz.', true); return; }
            if (!confirmRestore(file.name)) return;
            const form = new FormData(); form.append('backup', file);
            const sum = $('portalbackup-checksum').files[0]; if (sum) form.append('checksum', sum);
            try {
                setBusy(true);
                const data = await request('/api/restore/upload', {method:'POST', body:form});
                notify(data.checksum_provided ? 'Upload recebido. O SHA-256 será validado pelo host antes do rollback.' : 'Upload recebido; a estrutura será validada pelo host antes do rollback.');
                await refreshStatus();
            } catch(e){ setBusy(false); notify(e.message, true); }
        });

        setInterval(refreshStatus, 5000);
    });
})();
