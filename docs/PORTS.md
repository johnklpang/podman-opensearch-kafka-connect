# Host port map (custom — no defaults)

| Service | Variable | Host | Container |
|---------|----------|------|-----------|
| ZooKeeper | `ZOOKEEPER_HOST_PORT` | 12181 | 2181 |
| Kafka (external) | `KAFKA_HOST_PORT` | 19092 | 9092 |
| Kafka (internal) | `KAFKA_INTERNAL_PORT` | — | 29092 |
| Kafka Connect | `CONNECT_HOST_PORT` | 18083 | 8083 |
| OpenSearch HTTP | `OPENSEARCH_HOST_PORT` | 19200 | 9200 |
| OpenSearch transport | `OPENSEARCH_TRANSPORT_HOST_PORT` | 19600 | 9600 |
| Kafka UI | `KAFKA_UI_HOST_PORT` | 18081 | 8080 |
| OpenSearch Dashboards | `DASHBOARDS_HOST_PORT` | 15601 | 5601 |

Change values in `.env` and re-run `scripts/04-firewall-selinux.sh` + recreate the stack.
