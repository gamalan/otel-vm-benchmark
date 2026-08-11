# otel-vm-benchmark

Periodic **VM benchmark + degradation telemetry** that pushes OpenTelemetry metrics over
OTLP/HTTP to [OpenObserve](https://openobserve.com) — directly, or through your existing
OpenTelemetry Collector.

Built for the classic mystery: *"the provider upgraded our VM and now it's slower."* Each run
sends benchmark scores **and** the hardware/steal/throttle signals that explain a regression,
tagged with the CPU model, topology, kernel and a `run.id` so before/after comparisons survive
silent hardware swaps.

## Data flow

Two supported modes — pick one per VM.

```text
Mode A — direct to OpenObserve

  VM ──benchmark.sh── OTLP/HTTP ──▶ OpenObserve
       (POST JSON to :5081/api/default/otlp/v1/metrics)

Mode B — via OTel Collector (recommended, keeps everything in one pipeline)

  VM ──benchmark.sh── OTLP/HTTP ──▶ OTel Collector (:4318) ──▶ OpenObserve
       (your existing collector,     hostmetrics receiver,      one stream for
        default endpoint)            resource/batch processors   host + bench data
```

Mode B is the "in sync" setup: the script's metrics flow through the same collector and
pipeline as your base host-metrics script, so OpenObserve gets one merged stream per metric
and you can correlate `bench.*` against the always-on `host.*` (CPU, memory, disk, network).

## What it collects

| Metric | Source | Unit | Tells you |
| --- | --- | --- | --- |
| `bench.cpu.events_per_second` | sysbench cpu, 30s, threads=nproc | events/s | raw CPU compute score |
| `bench.memory.mib_per_second` | sysbench memory, 30s, 1K blocks | MiB/s | memory bandwidth |
| `bench.disk.read_iops` / `write_iops` | fio 4k rand, iodepth=32, 30s | iops | disk throughput |
| `bench.disk.read_bw_bytes` / `write_bw_bytes` | fio | B/s | disk throughput |
| `bench.disk.read_lat_p50_ms` / `lat_p99_ms` (× read/write) | fio latency percentiles | ms | **latency regression — the usual culprit** |
| `bench.net.sent_bits_per_second` / `received_bits_per_second` | iperf3 `-P 4 -t 20` (only if `IPERF3_HOST` set) | bit/s | network throughput |
| `host.cpu.steal_pct` | /proc/stat delta across the run | % | **noisy neighbor / oversubscription** |
| `host.cpu.idle_pct` / `iowait_pct` | /proc/stat delta | % | contention during the run |
| `host.cpu.scaling_freq_avg_khz` / `max_khz` | cpufreq sysfs after the run | kHz | **throttling — freq stuck well below max** |
| `host.load.1m` / `5m` / `15m` | /proc/loadavg | load | baseline system load |

**Resource attributes on every metric** (grouping keys in OpenObserve):

`host.name`, `vm.provider`, `vm.size`, `run.id`, `host.cpu.count`, `cpu.model`,
`cpu.sockets`, `cpu.cores_per_socket`, `cpu.threads_per_core`, `cpu.max_mhz`,
`cpu.arch`, `kernel.version`

## Requirements

```bash
# Debian/Ubuntu
apt install sysbench fio iperf3   # iperf3 only needed for the network benchmark
```

No collector-side changes are required for the script itself — it only speaks OTLP/HTTP.

## Quick start

### Mode A — direct to OpenObserve

```bash
# 1. copy to the VM
scp otel-vm-benchmark.sh root@vm:/opt/otel-vm-benchmark/
chmod +x /opt/otel-vm-benchmark/otel-vm-benchmark.sh

# 2. set env for the run (put these in /etc/environment or the cron line)
export OTLP_ENDPOINT="http://<openobserve-host>:5081/api/default/otlp/v1/metrics"
export OTLP_HEADERS="Authorization: Basic $(printf 'user:pass' | base64)"
export VM_PROVIDER="hetzner" VM_SIZE="cpx31"

# 3. run once
/opt/otel-vm-benchmark/otel-vm-benchmark.sh
```

### Mode B — via your existing OTel Collector

Point the script at the collector's OTLP/HTTP receiver (the default endpoint already matches):

```bash
export OTLP_ENDPOINT="http://127.0.0.1:4318/v1/metrics"
```

Merge this into your collector config (add `receiver/prometheus`-style extras only if you
want node_exporter data too — see below):

```yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318   # script pushes here

processors:
  resource:                      # optional: stamp every metric, incl. the base script's
    attributes:
      - key: deployment.environment
        value: production
        action: upsert
  batch:
    timeout: 5s

exporters:
  otlphttp/openobserve:
    endpoint: http://openobserve:5081/api/default/otlp   # exporter appends /v1/metrics
    headers:
      Authorization: "Basic <base64(user:pass)>"
  debug:
    verbosity: basic

service:
  pipelines:
    metrics:
      receivers: [otlp]                  # add hostmetrics here too if not already present:
      processors: [resource, batch]      #   receivers: [otlp, hostmetrics]
      exporters: [otlphttp/openobserve, debug]
```

If your base script already runs the collector's `hostmetrics` receiver, just add it to the
same `metrics` pipeline — `bench.*` and `host.*` then land in OpenObserve together, one
stream per metric, and both carry the same resource attributes.

### Optional: node_exporter for deep host telemetry

For PSI pressure, hwmon temperature, netstat/TCP retransmits and scheduler stats (all useful
for post-upgrade forensics), run node_exporter on the VM and scrape it with the collector:

```yaml
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: node
          scrape_interval: 30s
          static_configs:
            - targets: ['127.0.0.1:9100']
# add prometheus to the same metrics pipeline receivers
```

## Scheduling

### Cron

```bash
0 * * * * OTLP_ENDPOINT="..." OTLP_HEADERS="..." VM_PROVIDER="hetzner" VM_SIZE="cpx31" \
  /opt/otel-vm-benchmark/otel-vm-benchmark.sh >> /var/log/vm-benchmark.log 2>&1
```

### systemd timer (preferred — logs, restart, and no cron env surprises)

`/etc/systemd/system/vm-benchmark.service`:

```ini
[Unit]
Description=VM benchmark -> OTel metrics
[Service]
Type=oneshot
Environment=OTLP_ENDPOINT=http://127.0.0.1:4318/v1/metrics
Environment=VM_PROVIDER=hetzner
Environment=VM_SIZE=cpx31
ExecStart=/opt/otel-vm-benchmark/otel-vm-benchmark.sh
```

`/etc/systemd/system/vm-benchmark.timer`:

```ini
[Unit]
Description=Run VM benchmark hourly
[Timer]
OnCalendar=hourly
Persistent=true
[Install]
WantedBy=timers.target
```

```bash
systemctl daemon-reload && systemctl enable --now vm-benchmark.timer
```

## Environment reference

| Var | Default | Purpose |
| --- | --- | --- |
| `OTLP_ENDPOINT` | `http://localhost:4318/v1/metrics` | OTLP/HTTP metrics endpoint |
| `OTLP_HEADERS` | — | extra headers, **pipe-separated**: `Authorization: Basic xyz` |
| `VM_PROVIDER` | `unknown` | attribute, e.g. `hetzner` / `vultr` / `digitalocean` |
| `VM_SIZE` | `unknown` | attribute, e.g. `cpx31` / `s-4vcpu-8gb` |
| `IPERF3_HOST` | — | iperf3 server address; unset = skip network bench |
| `SKIP_CPU` / `SKIP_MEM` / `SKIP_DISK` / `SKIP_NET` | `0` | set to `1` to skip a benchmark |
| `RUN_ID` | timestamp | set internally; override for custom run labels |

## OpenObserve

OTLP metric names become streams. Gauge values land in the `_value` field; resource
attributes become labels (tags).

```sql
-- CPU score by hardware generation (per run)
SELECT run_id, cpu_model, max(_value) AS score
FROM "bench.cpu.events_per_second"
GROUP BY run_id, cpu_model
ORDER BY run_id DESC
LIMIT 30;
```

```sql
-- steal % per host over time (noisy neighbor check)
SELECT _timestamp, host_name, _value
FROM "host.cpu.steal_pct"
ORDER BY _timestamp DESC
LIMIT 100;
```

Suggested alerts (metric `_value` thresholds):

- `host.cpu.steal_pct` > 5 for 3+ consecutive runs → provider oversubscription
- `host.cpu.scaling_freq_avg_khz` < 0.8 × `cpu.max_mhz` → throttling
- `bench.disk.read_lat_p99_ms` > 2× the VM's baseline → storage degradation
- `bench.cpu.events_per_second` < 0.9× previous run's value (compare same `cpu.model`) → compute regression

## Troubleshooting

```bash
# 1. run once and watch the log
/opt/otel-vm-benchmark/otel-vm-benchmark.sh

# 2. check the endpoint accepts OTLP JSON (direct mode)
curl -i -X POST "$OTLP_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "$(printf '%s' "$OTLP_HEADERS" | tr '|' '\n' | head -1)" \
  -d '{"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"test.push","gauge":{"dataPoints":[{"asDouble":1}]}}]}]}]}'
```

| Symptom | Fix |
| --- | --- |
| `push failed: HTTP Error 415` | endpoint speaks protobuf only — use the collector (Mode B) which accepts both |
| `push failed: HTTP Error 401/403` | wrong `OTLP_HEADERS` — OpenObserve needs `Authorization: Basic base64(user:pass)` |
| `sysbench not found — skipping...` | `apt install sysbench fio` |
| no `cpu.*` attrs in OpenObserve | attributes are per-metric labels — filter by them, they are not separate streams |
| metrics missing from dashboard | OpenObserve only shows streams once first data arrives; wait for the first hourly run |
