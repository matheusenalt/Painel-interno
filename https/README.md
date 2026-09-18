# HTTPS / Caddy

Execute somente depois que os domínios reais já apontarem para a nova VPS:

```bash
sudo /opt/portal-interno/scripts/configurar-https.sh
```

O script instala/configura Caddy, abre 80/443 quando UFW está presente, reforça o domínio/protocolo do Nextcloud e, em migração, atualiza `APP_URL` do FoxDesk restaurado para o novo domínio.
