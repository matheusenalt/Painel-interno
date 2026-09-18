# Publicação segura no GitHub

Esta árvore já foi preparada como uma **edição pública sanitizada**.

## Regra mais importante

**Não transforme o repositório privado original em público e não use `git clone --mirror` para criar esta versão.**

Mesmo que o estado atual esteja limpo, o histórico Git do projeto privado pode conter arquivos, nomes, domínios ou outras informações removidas posteriormente.

A edição pública deve começar com **um histórico Git novo**, usando somente os arquivos desta pasta sanitizada.

## Antes do primeiro push

### 1. Configure a privacidade do e-mail dos commits

No GitHub, ative **Keep my email addresses private** e use o endereço `noreply` fornecido pela própria conta. Antes do primeiro commit deste repositório novo:

```bash
git config user.email "SEU_NOREPLY_DO_GITHUB"
git config user.name "SEU_NOME_OU_USUARIO"
```

Depois de criar commits, confira o que ficará público:

```bash
git log --format='%an <%ae>' | sort -u
```

Se aparecer um e-mail que não deveria ser público, corrija **antes** de publicar. Como esta edição deve começar com histórico novo, é mais seguro recriar o histórico do que importar commits do repositório privado.

### 2. Rode uma denylist particular, fora do repositório

Crie no seu computador um arquivo que **não será commitado**, contendo termos que jamais podem aparecer na edição pública: nome da empresa, domínios, cidades, nomes internos, provedores, identificadores e outros termos específicos. Exemplo:

```bash
./scripts-repo/check-denylist.sh ~/denylist.txt
```

Ou rode tudo de uma vez informando a denylist ao check principal:

```bash
PUBLIC_DENYLIST_FILE=~/denylist.txt ./scripts-repo/pre-push-check.sh
```

A verificação deve retornar sem achados. Não coloque essa denylist dentro do repositório público.

### 3. Rode os checks automatizados

```bash
./scripts-repo/pre-push-check.sh
```

O comando valida segredos, possíveis e-mails/IPs públicos literais, presença de branding interno, sintaxe Bash/PHP/Python e arquivos de configuração que não deveriam ser versionados.

## Criar o repositório público

Crie no GitHub um repositório **novo e vazio**, por exemplo:

```text
portal-interno-selfhosted
```

Não importe o repositório privado e não inicialize o novo repositório pelo GitHub com arquivos extras se você já possui esta árvore local.

Dentro desta pasta:

```bash
git init
git branch -M main
./scripts-repo/pre-push-check.sh
git add .
git status
git commit -m "Publica baseline sanitizado do portal self-hosted"
PUBLIC_DENYLIST_FILE=~/denylist.txt ./scripts-repo/pre-push-check.sh
git remote add origin https://github.com/SEU_USUARIO/portal-interno-selfhosted.git
git push -u origin main
```

Revise o `git status` antes do commit.

## Depois do push

Confira no GitHub:

- se não existe pasta de documentação interna;
- se não existem logos reais;
- se `portal.json`, `team.json` e `.env` não foram enviados;
- se o README mostra apenas placeholders;
- se a aba de linguagens está coerente;
- se nenhuma informação removida aparece na busca do repositório.

## LinkedIn

Compartilhe apenas o link desta edição pública. Não publique links para instâncias reais, repositórios privados, painéis administrativos ou backups.

Antes de publicar texto, imagens ou vídeos, revise também:

- barra de endereço do navegador e URLs;
- nomes de abas e favoritos;
- favicons/logos que identifiquem a empresa;
- nomes de pessoas, chamados, clientes e arquivos;
- notificações e mensagens visíveis ao fundo;
- metadados/EXIF das imagens, quando aplicável;
- qualquer QR Code, token, chave ou identificador de acesso.

