FROM semaphoreui/semaphore:v2.18.25

ARG K6_VERSION=v0.59.0

USER root

RUN apk add --no-cache curl tar \
    && curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-amd64.tar.gz" -o /tmp/k6.tar.gz \
    && tar -xzf /tmp/k6.tar.gz -C /tmp \
    && install -m 0755 "/tmp/k6-${K6_VERSION}-linux-amd64/k6" /usr/local/bin/k6 \
    && k6 version \
    && rm -rf /tmp/k6.tar.gz "/tmp/k6-${K6_VERSION}-linux-amd64"

USER 1001
