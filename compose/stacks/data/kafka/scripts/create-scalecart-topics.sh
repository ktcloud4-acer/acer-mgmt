#!/usr/bin/env bash
set -euo pipefail

BOOTSTRAP_SERVER="${BOOTSTRAP_SERVER:-localhost:19092}"
PARTITIONS="${PARTITIONS:-6}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-1}"
TEAMS=(nmg ggg khb ljw oje)
SUFFIXES=(orders orders.retry orders.dlq)

for team in "${TEAMS[@]}"; do
  for suffix in "${SUFFIXES[@]}"; do
    topic="scalecart.${team}.${suffix}"
    docker exec kafka /opt/kafka/bin/kafka-topics.sh \
      --bootstrap-server "${BOOTSTRAP_SERVER}" \
      --create \
      --if-not-exists \
      --topic "${topic}" \
      --partitions "${PARTITIONS}" \
      --replication-factor "${REPLICATION_FACTOR}"
  done
done

docker exec kafka /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server "${BOOTSTRAP_SERVER}" \
  --list \
  | grep -E '^scalecart\.(nmg|ggg|khb|ljw|oje)\.orders(\.retry|\.dlq)?$'
