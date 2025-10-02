FROM alpine:3.22

RUN apk upgrade --no-cache \
    && apk add --no-cache wireguard-tools iptables \
    && apk add --no-cache yq --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community

COPY init.sh /usr/sbin/init.sh

CMD ["/usr/sbin/init.sh"]

EXPOSE 51820/udp
