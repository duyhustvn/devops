FROM alpine:3.19

RUN apk add --no-cache keepalived curl bash iproute2

ENTRYPOINT ["keepalived", "-n", "-l", "-f", "/etc/keepalived/keepalived.conf"]
