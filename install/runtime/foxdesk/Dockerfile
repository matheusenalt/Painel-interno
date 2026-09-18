FROM php:8.3-apache

ARG FOXDESK_VERSION
# Opcional: SHA-256 esperado do tarball do release. Se vazio, o build segue
# com um aviso; se preenchido, o build falha caso o hash não bata.
ARG FOXDESK_SHA256=""

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl libonig-dev libzip-dev unzip \
    && docker-php-ext-install -j"$(nproc)" pdo_mysql mbstring zip \
    && a2enmod rewrite headers expires \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /var/www/html

ARG FOXDESK_SHA256=""
RUN set -eux; \
    curl -fL --retry 4 --retry-delay 3 \
      "https://github.com/lukashanes/foxdesk/archive/refs/tags/v${FOXDESK_VERSION}.tar.gz" \
      -o /tmp/foxdesk.tar.gz; \
    if [ -n "$FOXDESK_SHA256" ]; then \
      echo "${FOXDESK_SHA256}  /tmp/foxdesk.tar.gz" | sha256sum -c - ; \
    else \
      echo "AVISO: FOXDESK_SHA256 não informado no build — pulando verificação de integridade do tarball." >&2; \
    fi; \
    tar -xzf /tmp/foxdesk.tar.gz --strip-components=1 -C /var/www/html; \
    rm -f /tmp/foxdesk.tar.gz; \
    mkdir -p /var/www/html/uploads /var/www/html/storage

# Patch público: mantém os idiomas originais do FoxDesk e adiciona a camada pt-BR
# usada pelos e-mails operacionais do ambiente. O mesmo patch fica disponível
# em /usr/local/bin para reaplicação idempotente sobre volumes restaurados.
COPY apply-portal-ptbr.php /usr/local/bin/apply-portal-ptbr.php
RUN php /usr/local/bin/apply-portal-ptbr.php /var/www/html \
    && chown -R www-data:www-data /var/www/html

COPY apache.conf /etc/apache2/conf-available/portal-foxdesk.conf
COPY php.ini /usr/local/etc/php/conf.d/portal-foxdesk.ini
RUN a2enconf portal-foxdesk
