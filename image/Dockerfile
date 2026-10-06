# swa-lab-workload (Dockerfile): simulates one machine running the SWA Agent (root) + workload user swa-demo-sa
FROM docker.io/library/alpine:3.20
ARG SA_USER=swa-demo-sa
ARG SA_UID=1001
RUN apk add --no-cache ca-certificates tini bash curl jq coreutils \
 && addgroup -g ${SA_UID} ${SA_USER} && adduser -D -H -u ${SA_UID} -G ${SA_USER} -s /sbin/nologin ${SA_USER} \
 && mkdir -p /etc/swa /run/swa-agent
COPY swa-agent  /opt/swa/bin/swa-agent
COPY swa-go-test /usr/local/bin/swa-go-test
COPY entrypoint.sh /entrypoint.sh
COPY swa-test.sh /usr/local/bin/swa-test.sh
RUN chmod 0755 /opt/swa/bin/swa-agent /usr/local/bin/swa-go-test /usr/local/bin/swa-test.sh /entrypoint.sh
ENTRYPOINT ["/sbin/tini","--","/entrypoint.sh"]
