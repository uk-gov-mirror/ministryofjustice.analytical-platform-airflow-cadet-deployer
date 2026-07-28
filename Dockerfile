#checkov:skip=CKV_DOCKER_2: HEALTHCHECK not required - This is a utility container
#checkov:skip=CKV_DOCKER_3: USER is set in the base image (https://github.com/ministryofjustice/analytical-platform-airflow-python-base/blob/main/Dockerfile#L135)

FROM ghcr.io/ministryofjustice/analytical-platform-airflow-python-base:1.38.0@sha256:6d5673d45c3c05b04a3f8c1ae3b24c5472ae753b9d1e5e822507995643b34abe

ARG MOJAP_IMAGE_VERSION="default"
ENV MOJAP_IMAGE_VERSION=${MOJAP_IMAGE_VERSION} \
    MICROSOFT_SQL_ODBC_VERSION="18.6.1.1-1" \
    MICROSOFT_SQL_TOOLS_VERSION="18.6.1.1-1"

USER root

WORKDIR ${ANALYTICAL_PLATFORM_DIRECTORY}

COPY --chown=${CONTAINER_UID}:${CONTAINER_GID} pyproject.toml uv.lock ./

# Microsoft SQL ODBC and Tools
RUN <<EOF
curl --location --fail-with-body \
  "https://packages.microsoft.com/keys/microsoft.asc" \
  --output microsoft.asc

gpg --dearmor --output microsoft-prod.gpg microsoft.asc

install -D --owner root --group root --mode 644 microsoft-prod.gpg /usr/share/keyrings/microsoft-prod.gpg

echo "deb [arch=amd64,arm64,armhf signed-by=/usr/share/keyrings/microsoft-prod.gpg] https://packages.microsoft.com/ubuntu/24.04/prod noble main" > /etc/apt/sources.list.d/mssql-release.list

apt-get update --yes

ACCEPT_EULA=Y apt-get install --yes --no-install-recommends \
  "msodbcsql18=${MICROSOFT_SQL_ODBC_VERSION}" \
  "mssql-tools18=${MICROSOFT_SQL_TOOLS_VERSION}"

apt-get clean --yes

rm --force --recursive /var/lib/apt/lists/* microsoft.asc microsoft-prod.gpg
EOF

USER ${CONTAINER_UID}

RUN uv sync --frozen --no-dev

COPY --chown=${CONTAINER_UID}:${CONTAINER_GID} --chmod=0755 src/ ${ANALYTICAL_PLATFORM_DIRECTORY}

ENTRYPOINT ["./entrypoint.sh"]
