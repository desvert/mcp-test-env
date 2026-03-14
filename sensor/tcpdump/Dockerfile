FROM alpine:3.19

RUN apk add --no-cache tcpdump

COPY start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]
