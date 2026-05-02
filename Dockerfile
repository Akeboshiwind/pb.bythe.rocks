FROM alpine:3.19 AS builder

ARG PB_VERSION=0.22.21
ARG LITESTREAM_VERSION=0.3.13
ARG TARGETARCH=amd64

RUN apk add --no-cache curl unzip ca-certificates

WORKDIR /tmp

RUN curl -fsSL "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_${TARGETARCH}.zip" -o pb.zip \
    && unzip pb.zip pocketbase \
    && chmod +x pocketbase

RUN curl -fsSL "https://github.com/benbjohnson/litestream/releases/download/v${LITESTREAM_VERSION}/litestream-v${LITESTREAM_VERSION}-linux-${TARGETARCH}.tar.gz" -o ls.tar.gz \
    && tar -xzf ls.tar.gz \
    && chmod +x litestream

FROM alpine:3.19

RUN apk add --no-cache ca-certificates bash tzdata

COPY --from=builder /tmp/pocketbase /usr/local/bin/pocketbase
COPY --from=builder /tmp/litestream /usr/local/bin/litestream

COPY litestream.yml /etc/litestream.yml
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
