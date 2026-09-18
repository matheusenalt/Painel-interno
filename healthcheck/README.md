# Validação

Depois de instalação, migração, mudança de proxy ou restore:

```bash
sudo /opt/portal-interno/scripts/healthcheck.sh
sudo /opt/portal-interno/scripts/auditar-seguranca.sh
sudo docker exec -u www-data portal-nextcloud php occ status
```

O healthcheck compara o ambiente atual com `/opt/portal-interno/config/portal.json`. A auditoria complementa com verificações de segurança do host/serviços.
