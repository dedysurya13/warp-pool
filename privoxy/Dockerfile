FROM alpine:3.20

# privoxy + netcat for the startup reachability check
RUN apk add --no-cache privoxy netcat-openbsd

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8118 8119 8120

ENTRYPOINT ["/entrypoint.sh"]
