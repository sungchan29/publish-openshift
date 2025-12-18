#!/bin/bash

dnf install -y haproxy

if [[ ! -f /etc/haproxy/haproxy.cfg.orig ]]; then
  mv /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.orig
fi

cat <<EOF > /etc/haproxy/haproxy.cfg
global
  log         127.0.0.1 local2
  pidfile     /var/run/haproxy.pid
  maxconn     4000
  daemon

defaults
  mode                    http
  log                     global
  option                  dontlognull
  option http-server-close
  option                  redispatch
  retries                 3
  timeout http-request    10s
  timeout queue           1m
  timeout connect         10s
  timeout client          1m
  timeout server          1m
  timeout http-keep-alive 10s
  timeout check           10s
  maxconn                 3000

frontend stats
  bind *:1936
  mode            http
  log             global
  maxconn 10
  stats enable
  stats hide-version
  stats refresh 30s
  stats show-node
  stats show-desc Stats for ocp4 cluster
  stats auth admin:ocp4
  stats uri /stats

listen api-server-6443
  bind *:6443
  mode tcp
  server sno     172.16.120.100:6443 check inter 1s
  server master1 172.16.120.111:6443 check inter 1s
  server master2 172.16.120.112:6443 check inter 1s
  server master3 172.16.120.113:6443 check inter 1s

listen machine-config-server-22623
  bind *:22623
  mode tcp
  server sno     172.16.120.100:22623 check inter 1s
  server master1 172.16.120.111:22623 check inter 1s
  server master2 172.16.120.112:22623 check inter 1s
  server master3 172.16.120.113:22623 check inter 1s

listen ingress-router-80
  bind *:80
  mode tcp
  balance source
  server sno     172.16.120.100:80 check inter 1s
  server infra01 172.16.120.121:80 check inter 1s
  server infra02 172.16.120.122:80 check inter 1s
  server infra03 172.16.120.123:80 check inter 1s

listen ingress-router-443
  bind *:443
  mode tcp
  balance source
  server sno     172.16.120.100:443 check inter 1s
  server infra01 172.16.120.121:443 check inter 1s
  server infra02 172.16.120.122:443 check inter 1s
  server infra03 172.16.120.123:443 check inter 1s
EOF


chcon --reference=/etc/haproxy/haproxy.cfg.orig /etc/haproxy/haproxy.cfg

semanage port -a -t http_port_t -p tcp 1936
semanage port -a -t http_port_t -p tcp 6443
semanage port -a -t http_port_t -p tcp 22623

firewall-cmd --permanent --add-port=80/tcp --add-port=443/tcp --add-port=1936/tcp --add-port=6443/tcp --add-port=22623/tcp --zone=public
firewall-cmd --reload

systemctl start haproxy.service


netstat -anp |grep LISTEN |grep -v unix |grep tcp |grep -v tcp6