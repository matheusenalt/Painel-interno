ARG NEXTCLOUD_VERSION
FROM nextcloud:${NEXTCLOUD_VERSION}-apache

ARG PORTAL_CONTROL_GID
USER root
RUN set -eux; \
    test -n "${PORTAL_CONTROL_GID}"; \
    control_group="$(awk -F: -v gid="${PORTAL_CONTROL_GID}" '$3 == gid { print $1; exit }' /etc/group)"; \
    if [ -z "$control_group" ]; then \
        control_group="portalctl"; \
        if getent group "$control_group" >/dev/null 2>&1; then control_group="portalctl-host"; fi; \
        groupadd --gid "${PORTAL_CONTROL_GID}" "$control_group"; \
    fi; \
    usermod -aG "$control_group" www-data; \
    id www-data
