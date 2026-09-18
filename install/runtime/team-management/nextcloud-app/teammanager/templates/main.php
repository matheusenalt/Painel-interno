<div id="teammanager-app" class="teammanager-wrap">
  <div class="teammanager-head">
    <div><h2>Gestão de Equipe</h2><p>Cadastro, e-mail/FoxDesk, troca de setor e desligamento. O grupo <strong>admin</strong> é protegido e nunca aparece como opção.</p></div>
    <button id="teammanager-refresh">Atualizar</button>
  </div>
  <div id="teammanager-flash" class="teammanager-flash" hidden></div>

  <section class="teammanager-card">
    <h3>Novo funcionário</h3>
    <div class="teammanager-grid">
      <label>Nome completo<input id="teammanager-name" type="text" maxlength="100" autocomplete="off"></label>
      <label>Login Nextcloud<input id="teammanager-uid" type="text" maxlength="32" placeholder="ex.: joaosilva" autocomplete="off"></label>
      <label>E-mail <span class="teammanager-muted">(opcional)</span><input id="teammanager-email" type="email" maxlength="160" placeholder="Pode ser adicionado depois" autocomplete="off"></label>
      <label>Setor<select id="teammanager-sector"></select></label>
    </div>
    <button id="teammanager-create" class="primary">Cadastrar funcionário</button>
    <p class="teammanager-muted">Sem e-mail, cria somente o Nextcloud. Ao cadastrar um e-mail depois, o painel cria automaticamente a conta FoxDesk como agente. Se o e-mail já existir no funcionário, uma alteração atualiza a mesma conta FoxDesk em vez de duplicar.</p>
  </section>

  <section id="teammanager-credentials" class="teammanager-card teammanager-creds" hidden>
    <h3>Credenciais temporárias</h3>
    <pre id="teammanager-credentials-text"></pre>
    <p class="teammanager-muted">Copie e entregue com segurança ao funcionário. Senhas novas também ficam no arquivo root protegido. O painel nunca promove ninguém para administrador.</p>
  </section>

  <section class="teammanager-card">
    <h3>Funcionários</h3>
    <p class="teammanager-muted">O e-mail pode ser adicionado quando o funcionário fornecer. Ao salvar pela primeira vez, a conta FoxDesk é provisionada automaticamente.</p>
    <div class="teammanager-table-wrap">
      <table class="teammanager-table">
        <thead><tr><th>Nome</th><th>Login</th><th>E-mail</th><th>FoxDesk</th><th>Setor</th><th>Ações</th></tr></thead>
        <tbody id="teammanager-users"><tr><td colspan="6">Carregando…</td></tr></tbody>
      </table>
    </div>
  </section>

  <section class="teammanager-card teammanager-danger-info">
    <h3>Desligamento</h3>
    <p class="teammanager-muted">Ao desligar um funcionário, a conta do Nextcloud é excluída e a área pessoal deixa de existir. A conta do FoxDesk é apenas desativada, preservando o histórico de chamados. Team Folders não são apagadas. A ação exige confirmação digitada.</p>
  </section>

  <section class="teammanager-card">
    <h3>Histórico recente</h3>
    <pre id="teammanager-history" class="teammanager-history">Nenhuma operação registrada.</pre>
  </section>
</div>
