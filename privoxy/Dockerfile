FROM alpine:3.20

RUN apk add --no-cache privoxy

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 8118/8119/8120 tergantung LISTEN_PORT
EXPOSE 8118 8119 8120

ENTRYPOINT ["/entrypoint.sh"]
