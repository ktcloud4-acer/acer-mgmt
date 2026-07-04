#!/usr/bin/env bash
set -euo pipefail

IMAGE="${FILEBEAT_IMAGE:-docker.elastic.co/beats/filebeat:9.4.2}"
CONFIG_SRC="${CONFIG_SRC:-/tmp/filebeat-aio.yml}"
CONFIG_DIR="${CONFIG_DIR:-/etc/filebeat-aio}"
DATA_DIR="${DATA_DIR:-/var/lib/filebeat-aio}"

sudo mkdir -p "${CONFIG_DIR}" "${DATA_DIR}"
sudo install -o root -g root -m 0644 "${CONFIG_SRC}" "${CONFIG_DIR}/filebeat.yml"
sudo docker pull "${IMAGE}"
sudo docker rm -f filebeat-aio >/dev/null 2>&1 || true

sudo docker run -d \
  --name filebeat-aio \
  --restart unless-stopped \
  --network host \
  --user root \
  -v "${CONFIG_DIR}/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro" \
  -v /var/log:/var/log:ro \
  -v /var/lib/docker/volumes/kolla_logs/_data:/var/log/kolla:ro \
  -v "${DATA_DIR}:/usr/share/filebeat/data" \
  "${IMAGE}" \
  filebeat -e --strict.perms=false
