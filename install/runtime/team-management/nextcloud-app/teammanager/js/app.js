(() => {
  const base=OC.generateUrl('/apps/teammanager');
  const $=id=>document.getElementById(id);
  let sectors=[];
  const esc=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const notify=(msg,error=false)=>{const b=$('teammanager-flash'); b.textContent=msg; b.className=`teammanager-flash ${error?'error':'success'}`; b.hidden=false;};
  const request=async(path,options={})=>{const h=new Headers(options.headers||{});h.set('requesttoken',OC.requestToken);const r=await fetch(base+path,{...options,headers:h,credentials:'same-origin'});let d;try{d=await r.json();}catch(_){throw new Error(`Resposta HTTP inválida (${r.status})`)}if(!r.ok||d.ok===false)throw new Error(d.error||`HTTP ${r.status}`);return d;};
  const sectorOptions=(selected='')=>sectors.map(s=>`<option value="${esc(s.id)}" ${s.id===selected?'selected':''}>${esc(s.name)}</option>`).join('');
  const showFoxCredentials=(name,email,password)=>{
    $('teammanager-credentials-text').textContent=`Funcionário: ${name}\nFoxDesk\n  Login: ${email}\n  Senha temporária: ${password}`;
    $('teammanager-credentials').hidden=false;
  };
  const foxStatus=u=>{
    if(!u.email)return '<span class="teammanager-pending">⚠ Pendente — sem e-mail</span>';
    if(u.foxdesk)return `<span class="teammanager-ok">✓ ${u.foxdesk_active?'Ativo':'Inativo'} (${esc(u.foxdesk_role||'conta')})</span>`;
    return '<span class="teammanager-pending">⚠ Sem conta</span>';
  };
  const render=async()=>{
    const d=await request('/api/status'); sectors=d.sectors||[];
    $('teammanager-sector').innerHTML=sectorOptions(d.default_sector||'');
    const body=$('teammanager-users'); body.innerHTML='';
    (d.employees||[]).forEach(u=>{
      const tr=document.createElement('tr');
      tr.innerHTML=`<td>${esc(u.name)}</td><td><code>${esc(u.uid)}</code></td><td><div class="teammanager-email-edit"><input type="email" data-email="${esc(u.uid)}" value="${esc(u.email||'')}" placeholder="Adicionar e-mail"><button data-save-email="${esc(u.uid)}" data-name="${esc(u.name)}">Salvar e-mail</button></div></td><td>${foxStatus(u)}</td><td><select data-sector="${esc(u.uid)}">${sectorOptions(u.sector)}</select></td><td class="teammanager-actions"><button data-save-sector="${esc(u.uid)}">Salvar setor</button><button class="teammanager-danger" data-offboard="${esc(u.uid)}" data-name="${esc(u.name)}">Desligar</button></td>`;
      body.appendChild(tr);
    });
    if(!(d.employees||[]).length) body.innerHTML='<tr><td colspan="6">Nenhum funcionário encontrado nos setores permitidos.</td></tr>';

    body.querySelectorAll('[data-save-email]').forEach(btn=>btn.addEventListener('click',async()=>{
      const uid=btn.dataset.saveEmail, name=btn.dataset.name||uid;
      const input=body.querySelector(`input[data-email="${CSS.escape(uid)}"]`);
      const email=input.value.trim();
      if(!email){notify('Informe um e-mail antes de salvar.',true);return;}
      if(!confirm(`Salvar o e-mail ${email} para ${name}?\n\nSe ainda não houver conta FoxDesk, ela será criada automaticamente como agente.`))return;
      try{
        btn.disabled=true;
        const form=new URLSearchParams({uid,email});
        const r=await request('/api/email',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'},body:form});
        if(r.credentials&&r.credentials.foxdesk_password)showFoxCredentials(name,email,r.credentials.foxdesk_password);
        notify(r.message||`E-mail de ${uid} salvo.`);
        await render();
      }catch(e){notify(e.message,true);}finally{btn.disabled=false;}
    }));

    body.querySelectorAll('[data-save-sector]').forEach(btn=>btn.addEventListener('click',async()=>{
      const uid=btn.dataset.saveSector;const sel=body.querySelector(`select[data-sector="${CSS.escape(uid)}"]`);
      try{btn.disabled=true;const form=new URLSearchParams({uid,sector:sel.value});await request('/api/sector',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'},body:form});notify(`Setor de ${uid} atualizado.`);await render();}catch(e){notify(e.message,true);}finally{btn.disabled=false;}
    }));

    body.querySelectorAll('[data-offboard]').forEach(btn=>btn.addEventListener('click',async()=>{
      const uid=btn.dataset.offboard, name=btn.dataset.name||uid;
      const expected=`EXCLUIR ${uid}`;
      const typed=prompt(`Desligar ${name}?\n\nIsso EXCLUI a conta e a área pessoal do Nextcloud.\nA conta FoxDesk será desativada para preservar o histórico de chamados.\nTeam Folders não serão apagadas.\n\nDigite exatamente:\n${expected}`,'');
      if(typed===null)return;
      if(typed!==expected){notify(`Confirmação incorreta. Digite exatamente: ${expected}`,true);return;}
      if(!confirm(`ÚLTIMA CONFIRMAÇÃO\n\nExcluir a conta Nextcloud de ${name} (${uid}) agora?\n\nEsta operação não pode ser desfeita pelo painel.`))return;
      try{btn.disabled=true;const form=new URLSearchParams({uid,confirm:typed});const r=await request('/api/offboard',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'},body:form});notify(r.message||`${name} desligado com sucesso.`);await render();}catch(e){notify(e.message,true);}finally{btn.disabled=false;}
    }));

    const hist=(d.history||[]).map(x=>`${x.time||''} | ${x.actor||'?'} | ${x.action||''} | ${x.target||''}${x.details?` | ${JSON.stringify(x.details)}`:''}`).join('\n');
    $('teammanager-history').textContent=hist||'Nenhuma operação registrada.';
  };

  document.addEventListener('DOMContentLoaded',async()=>{
    try{await render();}catch(e){notify(e.message,true);}
    $('teammanager-refresh').addEventListener('click',()=>render().catch(e=>notify(e.message,true)));
    $('teammanager-create').addEventListener('click',async()=>{
      const uid=$('teammanager-uid').value.trim().toLowerCase(), name=$('teammanager-name').value.trim(), email=$('teammanager-email').value.trim(), sector=$('teammanager-sector').value;
      if(!uid||!name||!sector){notify('Preencha nome, login e setor. O e-mail é opcional.',true);return;}
      const msg=email?`Cadastrar ${name} no setor ${sector}?\n\nSerão criadas contas no Nextcloud e FoxDesk.`:`Cadastrar ${name} no setor ${sector}?\n\nSerá criada somente a conta Nextcloud. O FoxDesk ficará pendente até um e-mail ser adicionado.`;
      if(!confirm(msg))return;
      const btn=$('teammanager-create');
      try{
        btn.disabled=true;
        const form=new URLSearchParams({uid,name,email,sector});
        const d=await request('/api/employee',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'},body:form});
        let text=`Funcionário: ${name}\nNextcloud\n  Login: ${uid}\n  Senha temporária: ${d.credentials.nextcloud_password}`;
        if(d.credentials.foxdesk_password){text+=`\n\nFoxDesk\n  Login: ${email}\n  Senha temporária: ${d.credentials.foxdesk_password}`;}else{text+='\n\nFoxDesk\n  Pendente até cadastrar um e-mail.';}
        $('teammanager-credentials-text').textContent=text;
        $('teammanager-credentials').hidden=false;
        notify(email?'Funcionário cadastrado nos dois sistemas.':'Funcionário cadastrado no Nextcloud. FoxDesk pendente de e-mail.');
        $('teammanager-name').value='';$('teammanager-uid').value='';$('teammanager-email').value='';
        await render();
      }catch(e){notify(e.message,true);}finally{btn.disabled=false;}
    });
  });
})();
