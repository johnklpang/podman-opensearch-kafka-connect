# Streaming Stack on RHEL 8.10 — Podman + podman-compose

Production-oriented deployment of **ZooKeeper**, **Apache Kafka**, **Kafka Connect** (with **OpenSearch Sink** plugin), **OpenSearch**, **Kafka UI**, and **OpenSearch Dashboards** on **RHEL 8.10** using **rootless-friendly Podman** and **podman-compose**.

## Custom host ports (no defaults)

| Service | Host port | Container port | Purpose |
|---------|-----------|----------------|---------|
| ZooKeeper | **12181** | 2181 | Coordination |
| Kafka | **19092** | 9092 | External bootstrap |
| Kafka (internal) | — | 29092 | In-network clients |
| Kafka Connect | **18083** | 8083 | REST API |
| OpenSearch HTTP | **19200** | 9200 | Search API |
| OpenSearch transport | **19600** | 9600 | Node transport |
| Kafka UI | **18081** | 8080 | Kafka management UI |
| OpenSearch Dashboards | **15601** | 5601 | Visualization UI |

All services share the user-defined bridge network `streamstack-net`.

---

## Architecture

```
                    ┌─────────────────┐
   Host :18081 ────►│    Kafka UI     │
                    └────────┬────────┘
                             │
Host :19092 ──► Kafka :9092/29092 ◄──► ZooKeeper :2181 (host :12181)
                             │
                    ┌────────┴────────┐
   Host :18083 ────►│ Kafka Connect   │── sink ──► OpenSearch :9200 (host :19200)
                    │ + OS Sink plugin│                 │
                    └─────────────────┘                 ▼
                                          OpenSearch Dashboards (host :15601)
```

---

## 1. Prerequisites and package installation (RHEL 8.10)

Run as root once:

```bash
sudo ./scripts/01-prereqs-rhel810.sh
```

What it does:

- Installs **Podman**, CNI/netavark stack, `python3`, `jq`, `curl`, **firewalld**, SELinux tools
- Installs **podman-compose** (dnf if available, otherwise `pip`)
- Sets `vm.max_map_count=262144` (required by OpenSearch)
- Enables linger / subuid-subgid for the invoking sudo user (rootless)

### Manual equivalent (if you prefer not to use the script)

```bash
sudo dnf -y install epel-release
sudo dnf -y install podman podman-plugins containernetworking-plugins \
  slirp4netns fuse-overlayfs aardvark-dns netavark python3 python3-pip \
  curl jq firewalld policycoreutils-python-utils container-selinux

# podman-compose
sudo dnf -y install podman-compose || sudo python3 -m pip install 'podman-compose>=1.0.6'

# OpenSearch mmap
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-streamstack-opensearch.conf
sudo sysctl --system

# Rootless helpers
sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
sudo loginctl enable-linger "$USER"
```

Verify:

```bash
podman --version
podman-compose --version
sysctl vm.max_map_count   # expect 262144
```

### SELinux notes

- Compose volumes use the `:Z` label so Podman relabels content for private container use.
- `container-selinux` policies cover typical named volumes under the user container storage path.
- The firewall script optionally sets `container_connect_any` for broader container egress if your policy is strict.
- Prefer **Enforcing**; do not disable SELinux for this stack.

### firewalld

```bash
sudo ./scripts/04-firewall-selinux.sh
```

Opens only the custom ports listed above (permanent + reload).

---

## 2. Pull base container images

As the runtime user (rootless recommended):

```bash
./scripts/02-pull-images.sh
```

Images pulled:

| Component | Image |
|-----------|--------|
| ZooKeeper | `docker.io/confluentinc/cp-zookeeper:7.6.1` |
| Kafka | `docker.io/confluentinc/cp-kafka:7.6.1` |
| Kafka Connect (base) | `docker.io/confluentinc/cp-kafka-connect:7.6.1` |
| OpenSearch | `docker.io/opensearchproject/opensearch:2.14.0` |
| Dashboards | `docker.io/opensearchproject/opensearch-dashboards:2.14.0` |
| Kafka UI | `docker.io/provectuslabs/kafka-ui:v0.7.2` |

---

## 3. Kafka Connect + OpenSearch Sink plugin

**Required:** bake the Aiven OpenSearch Sink into a local image (bind mounts are unreliable under SELinux/rootful Podman).

```bash
./scripts/03-build-connect.sh
```

- Image: `localhost/kafka-connect-opensearch:7.6.1` (set as `CONNECT_IMAGE` in `.env`)
- Plugin class: `io.aiven.kafka.connect.opensearch.OpenSearchSinkConnector`
- Containerfile: [`kafka-connect/Containerfile`](kafka-connect/Containerfile) (`COPY` of prefetched jars)

Confirm at runtime:

```bash
curl -s http://127.0.0.1:18083/connector-plugins | jq 'map(.class) | map(select(test("(?i)opensearch")))'
podman exec streamstack-kafka-connect ls /usr/share/confluent-hub-components/aiven-opensearch-connector | head
```

---

## 4. Complete `podman-compose.yml`

File: [`podman-compose.yml`](podman-compose.yml) — driven by [`.env`](.env).

Highlights:

- Shared bridge network `streamstack-net`
- Named volumes with SELinux `:Z` labels
- Healthchecks and `depends_on` ordering
- Kafka dual listeners:
  - **Internal:** `PLAINTEXT://kafka:29092` (Connect, UI, other containers)
  - **External:** `PLAINTEXT_HOST://localhost:19092` (host clients; set `KAFKA_ADVERTISED_HOST` for remote producers)
- OpenSearch single-node with security plugin disabled for lab/bootstrap (`DISABLE_SECURITY_PLUGIN=true`)
- Kafka UI wired to Kafka + Connect
- Dashboards pointed at `http://opensearch:9200`

Deploy:

```bash
sudo ./scripts/04-firewall-selinux.sh   # once, as root
./scripts/05-deploy.sh
```

Useful commands:

```bash
podman-compose --env-file .env -f podman-compose.yml ps
podman logs -f streamstack-kafka-connect
podman network inspect streamstack-net
```

Optional boot persistence (rootless user unit): see [`systemd/streamstack.service`](systemd/streamstack.service).

---

## 5. Configure & deploy the OpenSearch Sink connector

Connector definition: [`configs/connectors/opensearch-sink.json`](configs/connectors/opensearch-sink.json)

| Setting | Value |
|---------|--------|
| Name | `opensearch-sink-app-events` |
| Class | `io.aiven.kafka.connect.opensearch.OpensearchSinkConnector` |
| Topic | `app-events` |
| OpenSearch URL | `http://opensearch:9200` (in-network) |
| Index | derived from topic name → `app-events` |
| Value converter | JSON, schemas disabled |

### Automated registration

```bash
./scripts/06-register-connector.sh
```

This will:

1. Wait until the OpenSearch plugin is listed by Connect
2. Create topic `app-events` (3 partitions, RF=1)
3. `POST` the connector (or `PUT` config if it already exists)
4. Print connector status

### Manual REST API

```bash
# Create
curl -s -X POST http://127.0.0.1:18083/connectors \
  -H 'Content-Type: application/json' \
  -d @configs/connectors/opensearch-sink.json | jq .

# Status
curl -s http://127.0.0.1:18083/connectors/opensearch-sink-app-events/status | jq .

# Update config
jq '.config' configs/connectors/opensearch-sink.json | \
  curl -s -X PUT http://127.0.0.1:18083/connectors/opensearch-sink-app-events/config \
    -H 'Content-Type: application/json' -d @- | jq .

# Delete
curl -s -X DELETE http://127.0.0.1:18083/connectors/opensearch-sink-app-events
```

### Produce sample data

```bash
./scripts/produce-sample-data.sh 20
```

Each message is JSON, for example:

```json
{"id":"evt-1","event_type":"user.signup","user_id":"user-1","amount":1.25,"ts":"2026-08-10T01:00:00Z"}
```

---

## 6. Verification — data flow and UIs

```bash
./scripts/07-verify.sh
```

Checks:

- Custom host ports listening
- Connect / OpenSearch / Kafka UI / Dashboards HTTP health
- Connector state `RUNNING`
- Document count in OpenSearch index `app-events`

### Manual checks

```bash
# Kafka topic
podman exec streamstack-kafka kafka-console-consumer \
  --bootstrap-server kafka:29092 \
  --topic app-events --from-beginning --max-messages 5

# OpenSearch docs
curl -s 'http://127.0.0.1:19200/app-events/_search?pretty&size=3'

# Cluster health
curl -s 'http://127.0.0.1:19200/_cluster/health?pretty'
```

### Web UIs

| UI | URL |
|----|-----|
| Kafka UI | http://\<host\>:18081 |
| OpenSearch Dashboards | http://\<host\>:15601 |
| OpenSearch API | http://\<host\>:19200 |
| Kafka Connect REST | http://\<host\>:18083 |

In Dashboards: create an index pattern for `app-events*` (Stack Management → Index patterns), then explore under Discover.

---

## Quick start (all steps)

```bash
# As root (once)
sudo ./scripts/01-prereqs-rhel810.sh
sudo ./scripts/04-firewall-selinux.sh

# As runtime user
./scripts/02-pull-images.sh
./scripts/03-build-connect.sh             # bake OpenSearch Sink into local Connect image
./scripts/05-deploy.sh
./scripts/06-register-connector.sh
./scripts/produce-sample-data.sh 20
./scripts/07-verify.sh
```

### Connect crash-loop: `find: command not found`

If logs show:

```text
[streamstack-connect-init] staging=/plugin-staging ...
/entrypoint/docker-entrypoint.sh: line N: find: command not found
```

your host is still using the **old custom entrypoint**. Stop it and use the baked image:

```bash
podman rm -f streamstack-kafka-connect
git pull
./scripts/emergency-fix-connect.sh
```

That builds `localhost/kafka-connect-opensearch:7.6.1` (plugin baked in) and starts Connect with the stock Confluent entrypoint.

### `/connector-plugins` returns `[]` for OpenSearch

Connect is running **without** the Sink plugin (stock image or empty bake).

```bash
# Shows which image is running + jar count, then bakes via podman cp+commit and recreates
./scripts/install-opensearch-plugin-now.sh
```

Quick checks:

```bash
podman inspect streamstack-kafka-connect --format '{{.Config.Image}}'
podman exec streamstack-kafka-connect ls /usr/share/confluent-hub-components/aiven-opensearch-connector | wc -l
curl -s http://127.0.0.1:18083/connector-plugins | jq 'map(.class)|map(select(test("(?i)opensearch")))'
```

Expected image: `localhost/kafka-connect-opensearch:7.6.1` with ~60 jars and class `OpenSearchSinkConnector`.

This will:
1. Download Aiven connector jars
2. `podman build` `localhost/kafka-connect-opensearch:7.6.1` with jars `COPY`’d in
3. Recreate the Connect container from that image
4. Register the sink connector

Manual equivalent:

```bash
./scripts/03-build-connect.sh
# ensure .env has:
# CONNECT_IMAGE=localhost/kafka-connect-opensearch:7.6.1
podman rm -f streamstack-kafka-connect
podman-compose --env-file .env -f podman-compose.yml up -d kafka-connect
curl -s http://127.0.0.1:18083/connector-plugins | jq 'map(.class)|map(select(test("(?i)opensearch")))'
./scripts/06-register-connector.sh
```

Teardown:

```bash
./scripts/teardown.sh            # stop containers
./scripts/teardown.sh --volumes  # also wipe named volumes
```

---

## Production hardening checklist

This compose file is a solid single-node baseline. Before production:

1. **Security:** Re-enable OpenSearch security (`DISABLE_SECURITY_PLUGIN=false`), TLS everywhere, rotate `OPENSEARCH_INITIAL_ADMIN_PASSWORD`, put Kafka behind SASL/SSL, protect Connect REST (reverse proxy + auth).
2. **Kafka HA:** 3+ brokers, RF≥3, external ZooKeeper ensemble or migrate to KRaft.
3. **Resources:** Raise `OPENSEARCH_JAVA_OPTS` / Kafka heap; pin CPU/memory with Podman `--cpus` / `--memory` or compose deploy limits.
4. **Networking:** Set `KAFKA_ADVERTISED_HOST` to a real hostname/IP; restrict firewalld to management subnets; consider a reverse proxy for UIs.
5. **Persistence:** Back up named volumes; place container storage on dedicated disks; monitor disk for Kafka logs and OpenSearch data.
6. **Observability:** Ship container logs to your SIEM; alert on connector `FAILED` state and OpenSearch red health.
7. **Upgrades:** Pin image digests; rebuild the Connect image when bumping the connector version.

---

## Repository layout

```
.
├── .env                              # Ports, images, cluster settings
├── podman-compose.yml                # Full multi-service stack
├── kafka-connect/Containerfile       # Connect + OpenSearch Sink plugin
├── configs/connectors/
│   └── opensearch-sink.json          # Sink connector definition
├── scripts/
│   ├── 01-prereqs-rhel810.sh
│   ├── 02-pull-images.sh
│   ├── 03-build-connect.sh
│   ├── 04-firewall-selinux.sh
│   ├── 05-deploy.sh
│   ├── 06-register-connector.sh
│   ├── 07-verify.sh
│   ├── produce-sample-data.sh
│   └── teardown.sh
└── systemd/streamstack.service       # Optional user unit
```

---

## Troubleshooting

| Symptom | Action |
|---------|--------|
| OpenSearch exits / `max virtual memory areas` | Confirm `sysctl vm.max_map_count` is `262144` |
| Permission denied on volumes (SELinux) | Ensure `:Z` on mounts; `podman unshare restorecon -R …` if using bind mounts |
| Connect cannot reach Kafka | Use internal listener `kafka:29092`, not host port |
| Connector plugin missing | Rebuild Connect image; check `/connector-plugins` |
| External producers fail | Set `KAFKA_ADVERTISED_HOST` to reachable host IP and recreate Kafka |
| Port already allocated | Change values in `.env` (keep them non-default) |
| Rootless port bind issues | All published ports are >1024 by design |

```bash
podman ps -a --filter name=streamstack
podman logs streamstack-opensearch
podman logs streamstack-kafka-connect
curl -s http://127.0.0.1:18083/connectors/opensearch-sink-app-events/status | jq .
```
