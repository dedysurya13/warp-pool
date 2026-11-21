FROM alpine:3.20

# privoxy + netcat + curl for the startup reachability check
RUN apk add --no-cache privoxy netcat-openbsd curl

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8118

ENTRYPOINT ["/entrypoint.sh"]
