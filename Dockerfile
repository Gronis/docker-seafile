FROM debian:bullseye-slim
MAINTAINER Robin Grönerg <robingronberg@gmail.com>

ENV VERSION=9.0.10
ENV DOCKERIZE_VERSION v0.6.1

RUN DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends \
    procps python3 python3-dev python3-setuptools python3-pip \
    python3-wheel curl sqlite3 default-libmysqlclient-dev \
    build-essential autoconf libtool pkg-config \
    libffi-dev libjpeg-dev zlib1g-dev && \
  pip3 install --timeout=3600 \
    Pillow pylibmc captcha jinja2 sqlalchemy python3-ldap \
    django-pylibmc django-simple-captcha mysqlclient lxml \
    future pycryptodome==3.12.0 cffi==1.14.0 && \
  apt-get purge -y \
    python3-dev python3-setuptools python3-pip python3-wheel \
    build-essential autoconf libtool pkg-config && \
  apt-get autoremove -y && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /root/.cache /usr/share/doc/* && \
  find / -type f -name '*.py[co]' -delete -or -type d -name '__pycache__' -delete && \
  curl -L https://github.com/jwilder/dockerize/releases/download/$DOCKERIZE_VERSION/dockerize-linux-amd64-$DOCKERIZE_VERSION.tar.gz | tar -xz -C /usr/local/bin && \
  useradd -d /seafile -M -s /bin/bash -c "Seafile User" seafile \
  && mkdir -p /opt/haiwen /seafile/ \
  && curl -sL $(curl -sL https://www.seafile.com/en/download/ \
    | grep -oE 'https://.*seafile-server.*x86-64.tar.gz' \
    | sed -e "s/[0-9]+\.[0-9]+\.[0-9]+/$VERSION/g" | sort -r | head -1) \
    | tar -C /opt/haiwen/ -xz \
  && chown -R seafile:seafile /seafile /opt/haiwen

COPY ["seafile-entrypoint.sh", "/usr/local/bin/"]

EXPOSE 8000 8082

ENTRYPOINT ["/usr/local/bin/seafile-entrypoint.sh"]
