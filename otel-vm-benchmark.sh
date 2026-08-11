#!/usr/bin/env bash
#
# otel-vm-benchmark.sh — periodic VM benchmark + degradation telemetry
# pushed to OpenObserve (or any OTLP/HTTP endpoint) as OpenTelemetry metrics.
#
# What it collects (each run):
#   bench.cpu.events_per_second        sysbench cpu (threads = nproc, 30s)
#   bench.memory.mib_per_second        sysbench memory (30s)
#   bench.disk.read/write iops/bw/lat  fio randread + randwrite (4k, iodepth=32)
#   bench.net.sent/received_bits_per_second   iperf3 (only if IPERF3_HOST set)
#   host.cpu.steal_pct                 /proc/stat delta across the run (noisy neighbor!)
#   host.cpu.idle_pct / iowait_pct     same delta
#   host.cpu.scaling_freq_khz          cpufreq after run (throttling detection)
#   host.load.1m/5m/15m                /proc/loadavg
#   host.cpu.count                     nproc
# Resource attributes on every metric: host.name, vm.provider, vm.size,
# cpu.model, cpu.sockets, cpu.cores_per_socket, cpu.threads_per_core,
# cpu.max_mhz, kernel.version, run.id — so OpenObserve can group
# "before upgrade" vs "after upgrade" even if the provider swapped hardware.
#
# Env:
#   OTLP_ENDPOINT  OTLP/HTTP metrics endpoint
#                  OpenObserve: http://<host>:5081/api/default/otlp/v1/metrics
#                  default: http://localhost:4318/v1/metrics
#   OTLP_HEADERS   extra headers, pipe-separated: "Authorization: Basic xyz"
#                  OpenObserve: Authorization: Basic $(printf 'user:pass'|base64)
#   VM_PROVIDER    e.g. hetzner / digitalocean / vultr  (attribute)
#   VM_SIZE        e.g. cpx31 / s-4vcpu-8gb            (attribute)
#   IPERF3_HOST    iperf3 server to run network benchmark (optional)
#   SKIP_CPU/SKIP_MEM/SKIP_DISK/SKIP_NET  set to 1 to skip a benchmark
#
# Requirements: bash, python3, sysbench, fio (iperf3 only for network).
#   apt install sysbench fio iperf3
#
# Periodic run (cron):
#   0 * * * * /opt/otel-vm-benchmark/otel-vm-benchmark.sh >> /var/log/vm-benchmark.log 2>&1
#
set -euo pipefail

OTLP_ENDPOINT="${OTLP_ENDPOINT:-http://localhost:4318/v1/metrics}"
VM_PROVIDER="${VM_PROVIDER:-unknown}"
VM_SIZE="${VM_SIZE:-unknown}"
IPERF3_HOST="${IPERF3_HOST:-}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

log() { echo "[$(date -u +%FT%TZ)] $*"; }

# ---------- identity ----------
lscpu -J >"$TMP/lscpu.json" 2>/dev/null || true
uname -r >"$TMP/kernel" 2>/dev/null || true
hostname >"$TMP/hostname" 2>/dev/null || true
nproc >"$TMP/nproc" 2>/dev/null || true

# ---------- baseline cpu counters (before) ----------
grep '^cpu ' /proc/stat >"$TMP/procstat.before" 2>/dev/null || true

# ---------- benchmarks ----------
if command -v sysbench >/dev/null 2>&1; then
	if [ "${SKIP_CPU:-0}" != 1 ]; then
		timeout 300 sysbench cpu --threads="$(nproc)" --time=30 run >"$TMP/sysbench-cpu.txt" 2>/dev/null &&
			log "sysbench cpu done" || log "sysbench cpu failed"
	fi
	if [ "${SKIP_MEM:-0}" != 1 ]; then
		timeout 300 sysbench memory --threads="$(nproc)" --time=30 --memory-block-size=1K run >"$TMP/sysbench-mem.txt" 2>/dev/null &&
			log "sysbench memory done" || log "sysbench memory failed"
	fi
else
	log "sysbench not found — skipping cpu/memory"
fi

if command -v fio >/dev/null 2>&1 && [ "${SKIP_DISK:-0}" != 1 ]; then
	timeout 300 fio --name=randread --ioengine=libaio --direct=1 --bs=4k --size=512M \
		--iodepth=32 --runtime=30 --time_based --rw=randread --output-format=json \
		>"$TMP/fio.json" 2>/dev/null &&
		log "fio randread done" || log "fio randread failed"
	timeout 300 fio --name=randwrite --ioengine=libaio --direct=1 --bs=4k --size=512M \
		--iodepth=32 --runtime=30 --time_based --rw=randwrite --output-format=json \
		>"$TMP/fio-write.json" 2>/dev/null &&
		log "fio randwrite done" || log "fio randwrite failed"
elif [ "${SKIP_DISK:-0}" != 1 ]; then
	log "fio not found — skipping disk"
fi

if [ -n "$IPERF3_HOST" ] && command -v iperf3 >/dev/null 2>&1 && [ "${SKIP_NET:-0}" != 1 ]; then
	timeout 120 iperf3 -c "$IPERF3_HOST" -t 20 -P 4 -J >"$TMP/iperf.json" 2>/dev/null &&
		log "iperf3 done" || log "iperf3 failed/skipped"
fi

# ---------- cpu counters after + freq snapshot ----------
grep '^cpu ' /proc/stat >"$TMP/procstat.after" 2>/dev/null || true
FREQ_AVG=0
FREQ_N=0
FREQ_MAX=0
for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq; do
	[ -r "$f" ] || continue
	v="$(cat "$f" 2>/dev/null || echo 0)"
	[ "$v" -gt 0 ] 2>/dev/null || continue
	FREQ_AVG=$((FREQ_AVG + v))
	FREQ_N=$((FREQ_N + 1))
	[ "$v" -gt "$FREQ_MAX" ] && FREQ_MAX=$v
done
[ "$FREQ_N" -gt 0 ] && FREQ_AVG=$((FREQ_AVG / FREQ_N)) || FREQ_AVG=0
echo "$FREQ_AVG" >"$TMP/freq_avg_khz"
echo "$FREQ_MAX" >"$TMP/freq_max_khz"
awk '{print $1,$2,$3}' /proc/loadavg >"$TMP/loadavg" 2>/dev/null || true

# ---------- build payload + push (python3) ----------
export BENCH_TMP="$TMP" OTLP_ENDPOINT OTLP_HEADERS VM_PROVIDER VM_SIZE RUN_ID
python3 - <<'PY'
import json, os, re, time, urllib.request

TMP   = os.environ["BENCH_TMP"]
ENDP  = os.environ["OTLP_ENDPOINT"]
HEADERS = os.environ.get("OTLP_HEADERS", "")

def rd(name):
    p = os.path.join(TMP, name)
    return open(p).read().strip() if os.path.exists(p) else ""

# ---- resource attributes (grouping key for before/after) ----
res = []
def attr(k, v):
    v = (v or "").strip()
    if v:
        res.append({"key": k, "value": {"stringValue": str(v)}})

attr("host.name", rd("hostname"))
attr("vm.provider", os.environ.get("VM_PROVIDER", ""))
attr("vm.size", os.environ.get("VM_SIZE", ""))
attr("kernel.version", rd("kernel"))
attr("run.id", os.environ.get("RUN_ID", ""))
attr("host.cpu.count", rd("nproc"))

try:
    lscpu = {e["field"].rstrip(":"): e["data"] for e in json.loads(rd("lscpu.json"))["lscpu"]}
    attr("cpu.model", lscpu.get("Model name"))
    attr("cpu.sockets", lscpu.get("Socket(s)"))
    attr("cpu.cores_per_socket", lscpu.get("Core(s) per socket"))
    attr("cpu.threads_per_core", lscpu.get("Thread(s) per core"))
    attr("cpu.max_mhz", lscpu.get("CPU max MHz"))
    attr("cpu.arch", lscpu.get("Architecture"))
except Exception:
    pass

# ---- metric builder ----
now = str(time.time_ns())
metrics = []
def add(name, value, unit="1", extra=None):
    if value is None:
        return
    dp = {"timeUnixNano": now, "asDouble": float(value)}
    if extra:
        dp["attributes"] = [{"key": k, "value": {"stringValue": str(v)}} for k, v in extra.items()]
    metrics.append({"name": name, "unit": unit, "gauge": {"dataPoints": [dp]}})

# ---- sysbench ----
m = re.search(r"events per second:\s*([\d.]+)", rd("sysbench-cpu.txt"))
add("bench.cpu.events_per_second", m.group(1) if m else None, "events/s")

m = re.search(r"([\d.]+)\s+(MiB|GiB)/sec", rd("sysbench-mem.txt"))
if m:
    v = float(m.group(1)) * (1024.0 if m.group(2) == "GiB" else 1.0)
    add("bench.memory.mib_per_second", v, "MiB/s")

# ---- fio ----
for fname, op in (("fio.json", "read"), ("fio-write.json", "write")):
    try:
        d = json.loads(rd(fname))
        j = d["jobs"][0][op]
    except Exception:
        continue
    pct = j.get("lat_us", {}).get("percentile") or j.get("lat_ns", {}).get("percentile") or {}
    scale = 1.0 if j.get("lat_us") else 0.001  # us, or ns -> ms
    add(f"bench.disk.{op}_iops", j.get("iops"), "iops", {"op": op})
    add(f"bench.disk.{op}_bw_bytes", j.get("bw_bytes"), "B/s", {"op": op})
    add(f"bench.disk.{op}_lat_p50_ms", (pct.get("50.000000") or 0) * scale, "ms", {"op": op})
    add(f"bench.disk.{op}_lat_p99_ms", (pct.get("99.000000") or 0) * scale, "ms", {"op": op})

# ---- iperf3 ----
try:
    d = json.loads(rd("iperf.json"))
    end = d.get("end", {})
    add("bench.net.received_bits_per_second", end.get("sum_received", {}).get("bits_per_second"), "bit/s")
    add("bench.net.sent_bits_per_second", end.get("sum_sent", {}).get("bits_per_second"), "bit/s")
except Exception:
    pass

# ---- /proc/stat delta: steal / idle / iowait across the run ----
def cpu_counts(path):
    fields = open(path).read().split()
    nums = list(map(int, fields[1:]))
    return nums  # user nice system idle iowait irq softirq steal guest guest_nice

try:
    b, a = cpu_counts(os.path.join(TMP, "procstat.before")), cpu_counts(os.path.join(TMP, "procstat.after"))
    dt = [a[i] - b[i] for i in range(min(len(b), len(a)))]
    total = max(sum(dt), 1)
    add("host.cpu.steal_pct", 100.0 * (dt[6] if len(dt) > 6 else 0) / total, "%")
    add("host.cpu.idle_pct", 100.0 * (dt[3] if len(dt) > 3 else 0) / total, "%")
    add("host.cpu.iowait_pct", 100.0 * (dt[4] if len(dt) > 4 else 0) / total, "%")
except Exception:
    pass

# ---- cpufreq snapshot + load ----
add("host.cpu.scaling_freq_avg_khz", rd("freq_avg_khz") or None, "kHz")
add("host.cpu.scaling_freq_max_khz", rd("freq_max_khz") or None, "kHz")
la = rd("loadavg").split()
if len(la) >= 3:
    add("host.load.1m", la[0]); add("host.load.5m", la[1]); add("host.load.15m", la[2])

if not metrics:
    print("no metrics collected; nothing pushed")
    raise SystemExit(0)

payload = {"resourceMetrics": [{"resource": {"attributes": res},
            "scopeMetrics": [{"scope": {"name": "otel-vm-benchmark"},
            "metrics": metrics}]}]}

req = urllib.request.Request(ENDP, data=json.dumps(payload).encode(), method="POST")
req.add_header("Content-Type", "application/json")
for h in filter(None, HEADERS.split("|")):
    if ":" in h:
        k, v = h.split(":", 1)
        req.add_header(k.strip(), v.strip())
try:
    with urllib.request.urlopen(req, timeout=30) as r:
        print(f"pushed {len(metrics)} metrics -> {ENDP} ({r.status})")
except Exception as e:
    print(f"push failed: {e}")
    raise SystemExit(1)
PY
