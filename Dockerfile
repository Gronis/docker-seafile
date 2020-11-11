FROM debian:buster-slim
MAINTAINER Robin Grönerg <robingronberg@gmail.com>

RUN DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y \
    procps python3 python3-setuptools python3-pip curl sqlite3 && \
  pip3 install --timeout=3600 \
    Pillow pylibmc captcha jinja2 sqlalchemy python3-ldap \
    django-pylibmc django-simple-captcha && \
  apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ENV DOCKERIZE_VERSION v0.6.1
RUN curl -L https://github.com/jwilder/dockerize/releases/download/$DOCKERIZE_VERSION/dockerize-linux-amd64-$DOCKERIZE_VERSION.tar.gz | tar -xz -C /usr/local/bin

ENV VERSION=7.1.5
RUN useradd -d /seafile -M -s /bin/bash -c "Seafile User" seafile \
  && mkdir -p /opt/haiwen /seafile/ \
  && curl -sL $(curl -sL https://www.seafile.com/en/download/ \
    | grep -oE 'https://.*seafile-server.*x86-64.tar.gz' \
    | sed -e "s/[0-9]\.[0-9]\.[0-9]/$VERSION/g" | sort -r | head -1) \
    | tar -C /opt/haiwen/ -xz \
  && chown -R seafile:seafile /seafile /opt/haiwen

COPY ["seafile-entrypoint.sh", "/usr/local/bin/"]

EXPOSE 8000 8082

ENTRYPOINT ["/usr/local/bin/seafile-entrypoint.sh"]
