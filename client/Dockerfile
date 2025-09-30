FROM alpine:3.22

RUN apk upgrade --no-cache \
    && apk add --no-cache wireguard-tools socat \
    && wget -O /usr/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 \
    && chmod +x /usr/bin/yq

COPY init.sh /usr/sbin/init.sh

CMD ["/usr/sbin/init.sh"]
