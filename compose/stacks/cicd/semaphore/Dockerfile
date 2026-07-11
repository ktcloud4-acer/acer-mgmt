FROM semaphoreui/semaphore:v2.18.25

ARG K6_VERSION=v1.0.0-rc2
ARG KUBECTL_VERSION=v1.35.6

USER root

RUN apk add --no-cache curl tar \
    && curl -fsSL "https://github.com/grafana/k6/releases/download/${K6_VERSION}/k6-${K6_VERSION}-linux-amd64.tar.gz" -o /tmp/k6.tar.gz \
    && tar -xzf /tmp/k6.tar.gz -C /tmp \
    && install -m 0755 "/tmp/k6-${K6_VERSION}-linux-amd64/k6" /usr/local/bin/k6 \
    && curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" -o /tmp/kubectl \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && k6 version \
    && kubectl version --client=true \
    && rm -rf /tmp/k6.tar.gz "/tmp/k6-${K6_VERSION}-linux-amd64" /tmp/kubectl

USER 1001
