FROM thecatlady/webhook:2.8.2
WORKDIR     /etc/webhook
COPY assets /etc/webhook/assets
ENV SHARED_DIR_PATH=/etc/webhook/shared
RUN apk update && apk add --no-cache docker-cli bash dos2unix
RUN find /etc/webhook/assets/scripts -type f -name '*.sh' -exec dos2unix {} \;
RUN echo https://ftp.halifax.rwth-aachen.de/alpine/v3.17/main >> /etc/apk/repositories
RUN echo https://ftp.halifax.rwth-aachen.de/alpine/v3.17/community >> /etc/apk/repositories

ENV BUILD_DEPS="gettext"  \
    RUNTIME_DEPS="libintl"

RUN set -x && \
    apk add --update $RUNTIME_DEPS && \
    apk add --virtual build_deps $BUILD_DEPS &&  \
    cp /usr/bin/envsubst /usr/local/bin/envsubst && \
    apk del build_deps

RUN apk update --allow-untrusted && apk add --allow-untrusted --no-cache docker-cli-compose

ENTRYPOINT ["/etc/webhook/assets/scripts/entrypoint.sh"]