FROM m3adow/ubuntu_dumb-init_gosu:latest
MAINTAINER Robin Grönerg <robingronberg@gmail.com>

RUN DEBIAN_FRONTEND=noninteractive apt-get update \
  && apt-get install -y python2.7 libpython2.7 python-mysqldb \
      python-setuptools python-imaging python-ldap sqlite3 \
      python-memcache curl \
  && apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*


RUN useradd -d /seafile -M -s /bin/bash -c "Seafile User" seafile \
  && mkdir -p /opt/haiwen /seafile/ \
  && curl -sL $(curl -sL https://www.seafile.com/en/download/ \
    | grep -oE 'https://.*seafile-server.*x86-64.tar.gz' | sort -r | head -1) \
    | tar -C /opt/haiwen/ -xz \
  && chown -R seafile:seafile /seafile /opt/haiwen

COPY ["seafile-entrypoint.sh", "/usr/local/bin/"]

EXPOSE 8000 8082

ENTRYPOINT ["/usr/bin/dumb-init", "/usr/local/bin/seafile-entrypoint.sh"]
