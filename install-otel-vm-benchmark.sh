#!/usr/bin/env bash
#
# install-otel-vm-benchmark.sh — one-shot installer for otel-vm-benchmark.
#
# What it does:
#   1. installs runtime deps            (sysbench, fio, iperf3 — apt/dnf/apk)
#   2. copies otel-vm-benchmark.sh  ->  /opt/otel-vm-benchmark/
#   3. writes /etc/otel-vm-benchmark.env (systemd EnvironmentFile: endpoint,
#      headers, provider/size, iperf3 host)
#   4. installs otel-vm-benchmark.{service,timer} — daily, persistent
#   5. optionally wires the OTLP/HTTP receiver into your *existing* OTel
#      Collector config so bench metrics join your current pipeline
#      (--collector-config PATH)
#
# Idempotent: safe to re-run; it overwrites env + units and reloads systemd.
#
# Usage:
#   sudo ./install-otel-vm-benchmark.sh [options]
#
# Options:
#   --endpoint URL       OTLP/HTTP metrics endpoint
#                        default: http://127.0.0.1:4318/v1/metrics
#                        (your existing collector — Mode B)
#   --headers "H: v"     extra headers, pipe-separated: "Authorization: Basic xyz"
#   --provider NAME      vm.provider attribute, e.g. hetzner (default: unknown)
#   --size NAME          vm.size attribute, e.g. cpx31   (default: unknown)
#   --iperf3-host HOST   enable the network benchmark against this iperf3 server
#   --ob-host HOST       OpenObserve convenience (Mode A): build endpoint +
#                        Authorization header from host/user/pass, e.g. 10.0.0.5:5081
#   --ob-user USER       OpenObserve username   (used with --ob-host)
#   --ob-pass PASS       OpenObserve password   (used with --ob-host)
#   --collector-config P existing collector YAML to wire the otlp receiver into
#                        (backed up, merged conservatively; diff shown)
#   --source DIR         directory containing otel-vm-benchmark.sh
#                        (default: directory of this script)
#   --no-packages        skip installing sysbench/fio/iperf3
#   --no-timer           install service + env only; do not enable the timer
#   --test               run the benchmark once after install to verify the push
#   --uninstall          remove service, timer and env file (keeps /opt copy)
#   --purge              with --uninstall: also delete /opt/otel-vm-benchmark
#   -h, --help           show this help
#
set -euo pipefail

# ---------------- defaults ----------------
INSTALL_DIR="/opt/otel-vm-benchmark"
ENV_FILE="/etc/otel-vm-benchmark.env"
SERVICE_UNIT="/etc/systemd/system/otel-vm-benchmark.service"
TIMER_UNIT="/etc/systemd/system/otel-vm-benchmark.timer"
SERVICE_NAME="otel-vm-benchmark.service"
TIMER_NAME="otel-vm-benchmark.timer"

ENDPOINT="http://127.0.0.1:4318/v1/metrics"
HEADERS=""
PROVIDER="unknown"
SIZE="unknown"
IPERF3_HOST=""
OB_HOST="" OB_USER="" OB_PASS=""
COLLECTOR_CONFIG=""
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DO_PACKAGES=1
DO_TIMER=1
DO_TEST=0
UNINSTALL=0
PURGE=0

log() { echo "[install] $*"; }
die() {
	echo "!! $*" >&2
	exit 1
}

usage() { sed -n '2,50p' "${BASH_SOURCE[0]}" | grep -v '^#' | head -40; }

# ---------------- collector wiring helper ----------------
# Conservative YAML merge: backs up the config, adds the otlp http receiver
# under 'receivers:' if missing, and adds 'otlp' to the metrics pipeline
# (block or flow list style) if missing. Anything ambiguous -> prints the
# fragment to merge by hand instead of touching the file.
wire_collector() {
	local cfg="$1" bak frag_changed=0
	[ -f "$cfg" ] || {
		log "!! collector config not found: $cfg"
		return 1
	}
	bak="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
	cp -a "$cfg" "$bak"
	log "collector config backed up: $bak"

	if grep -qE '^[[:space:]]*otlp:' "$cfg"; then
		log "collector already defines an 'otlp' receiver — nothing to add"
	else
		if grep -qE '^receivers:' "$cfg"; then
			awk '
				/^receivers:/ && !done_rx {
					print
					print "  otlp:"
					print "    protocols:"
					print "      http:"
					print "        endpoint: 0.0.0.0:4318"
					done_rx = 1
					next
				}
				{ print }
			' "$cfg" >"${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
			frag_changed=1
			log "added 'otlp' receiver (http 0.0.0.0:4318) to $cfg"
		else
			log "!! no top-level 'receivers:' found — add this block manually (fragment below)"
			frag_changed=1
		fi
	fi

	# pipeline-entry check: '- otlp' (block) or '[otlp' (flow); avoids false
	# positives on exporter endpoints like '.../api/default/otlp'
	if grep -qE '\[ *otlp|- *otlp([, ]|$)' "$cfg"; then
		log "collector metrics pipeline already lists 'otlp'"
	elif grep -qE '^service:' "$cfg"; then
		if awk '/^service:/{s=1} s&&/^[[:space:]]+pipelines:/{p=1} p&&/^[[:space:]]+metrics:/{m=1} m&&/^[[:space:]]+receivers:/{print; exit}' "$cfg" | grep -q .; then
			awk '
				/^service:/  { s = 1 }
				s && /^[[:space:]]+pipelines:/ { p = 1 }
				p && /^[[:space:]]+metrics:/   { m = 1 }
				m && /^[[:space:]]+receivers:/ && !done_pipe {
					if ($0 ~ /\[/) { sub(/\]/, ", otlp]", $0); print }
					else { print; print "        - otlp" }
					done_pipe = 1
					next
				}
				{ print }
			' "$cfg" >"${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
			frag_changed=1
			log "added 'otlp' to the metrics pipeline in $cfg"
		else
			log "!! no service.pipelines.metrics.receivers found — add '- otlp' manually"
			frag_changed=1
		fi
	else
		log "!! no 'service:' section found — add the pipeline wiring manually"
		frag_changed=1
	fi

	if [ "$frag_changed" = 1 ]; then
		log "changed config (diff vs backup):"
		diff -u "$bak" "$cfg" | sed 's/^/    /' || true
		if command -v otelcol >/dev/null 2>&1 || command -v otelcol-contrib >/dev/null 2>&1; then
			bin="$(command -v otelcol || command -v otelcol-contrib)"
			if "$bin" validate --config "$cfg"; then
				log "collector validate: OK"
			else
				log "!! collector validate failed — restore with: cp $bak $cfg"
			fi
		fi
	fi
	cat <<'FRAG'
--- fragment to merge manually (if the auto-merge could not find a spot) ---
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
# ...then add otlp to the receivers of your metrics pipeline:
#   service:
#     pipelines:
#       metrics:
#         receivers: [otlp, <your existing receivers>]
FRAG
}

# ---------------- arg parsing ----------------
while [ $# -gt 0 ]; do
	case "$1" in
	--endpoint)
		ENDPOINT="$2"
		shift 2
		;;
	--headers)
		HEADERS="$2"
		shift 2
		;;
	--provider)
		PROVIDER="$2"
		shift 2
		;;
	--size)
		SIZE="$2"
		shift 2
		;;
	--iperf3-host)
		IPERF3_HOST="$2"
		shift 2
		;;
	--ob-host)
		OB_HOST="$2"
		shift 2
		;;
	--ob-user)
		OB_USER="$2"
		shift 2
		;;
	--ob-pass)
		OB_PASS="$2"
		shift 2
		;;
	--collector-config)
		COLLECTOR_CONFIG="$2"
		shift 2
		;;
	--source)
		SOURCE_DIR="$2"
		shift 2
		;;
	--no-packages)
		DO_PACKAGES=0
		shift
		;;
	--no-timer)
		DO_TIMER=0
		shift
		;;
	--test)
		DO_TEST=1
		shift
		;;
	--uninstall)
		UNINSTALL=1
		shift
		;;
	--purge)
		PURGE=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*) die "unknown option: $1 (see --help)" ;;
	esac
done

# OpenObserve convenience -> Mode A endpoint + auth header
if [ -n "$OB_HOST" ]; then
	[ -n "$OB_USER" ] && [ -n "$OB_PASS" ] || die "--ob-host requires --ob-user and --ob-pass"
	ENDPOINT="http://${OB_HOST}/api/default/otlp/v1/metrics"
	AUTH="$(printf '%s:%s' "$OB_USER" "$OB_PASS" | base64 | tr -d '\n')"
	HEADERS="Authorization: Basic ${AUTH}"
	log "Mode A (direct): $ENDPOINT"
fi

# ---------------- uninstall ----------------
if [ "$UNINSTALL" = 1 ]; then
	[ "$(id -u)" = 0 ] || die "run as root (sudo)"
	log "stopping + disabling timer..."
	systemctl disable --now "$TIMER_NAME" >/dev/null 2>&1 || true
	rm -f "$SERVICE_UNIT" "$TIMER_UNIT" "$ENV_FILE"
	systemctl daemon-reload
	log "removed $SERVICE_UNIT, $TIMER_UNIT, $ENV_FILE"
	if [ "$PURGE" = 1 ]; then
		rm -rf "$INSTALL_DIR"
		log "removed $INSTALL_DIR"
	else
		log "kept $INSTALL_DIR (pass --purge to remove)"
	fi
	log "packages (sysbench/fio/iperf3) were left installed"
	exit 0
fi

# ---------------- root check ----------------
[ "$(id -u)" = 0 ] || die "run as root (sudo)"

# ---------------- 1. packages ----------------
if [ "$DO_PACKAGES" = 1 ]; then
	if command -v sysbench >/dev/null 2>&1 && command -v fio >/dev/null 2>&1; then
		log "sysbench + fio already installed"
	else
		log "installing sysbench, fio, iperf3..."
		if command -v apt-get >/dev/null 2>&1; then
			export DEBIAN_FRONTEND=noninteractive
			apt-get update -qq && apt-get install -y -qq sysbench fio iperf3
		elif command -v dnf >/dev/null 2>&1; then
			dnf install -y sysbench fio iperf3 || die "dnf failed (sysbench needs EPEL: dnf install epel-release)"
		elif command -v apk >/dev/null 2>&1; then
			apk add --no-cache sysbench fio iperf3
		else
			log "no supported package manager — install sysbench, fio, iperf3 manually"
		fi
	fi
else
	log "skipping package install (--no-packages)"
fi
command -v python3 >/dev/null 2>&1 || die "python3 is required by otel-vm-benchmark.sh"

# ---------------- 2. copy script ----------------
[ -f "$SOURCE_DIR/otel-vm-benchmark.sh" ] || die "otel-vm-benchmark.sh not found in $SOURCE_DIR (--source DIR)"
mkdir -p "$INSTALL_DIR"
install -m 0755 "$SOURCE_DIR/otel-vm-benchmark.sh" "$INSTALL_DIR/otel-vm-benchmark.sh"
log "installed $INSTALL_DIR/otel-vm-benchmark.sh"

# ---------------- 3. env file ----------------
{
	echo "# otel-vm-benchmark — systemd EnvironmentFile (written by install-otel-vm-benchmark.sh)"
	echo "# Re-run the installer (or edit this file) to change values, then: systemctl restart otel-vm-benchmark.timer"
	echo "OTLP_ENDPOINT=$ENDPOINT"
	[ -n "$HEADERS" ] && echo "OTLP_HEADERS=$HEADERS"
	echo "VM_PROVIDER=$PROVIDER"
	echo "VM_SIZE=$SIZE"
	[ -n "$IPERF3_HOST" ] && echo "IPERF3_HOST=$IPERF3_HOST"
} >"$ENV_FILE"
chmod 600 "$ENV_FILE"
log "wrote $ENV_FILE"

# ---------------- 4. systemd units ----------------
cat >"$SERVICE_UNIT" <<'UNIT'
[Unit]
Description=VM benchmark + degradation telemetry -> OpenTelemetry
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/otel-vm-benchmark.env
ExecStart=/opt/otel-vm-benchmark/otel-vm-benchmark.sh
SyslogIdentifier=otel-vm-benchmark
TimeoutStartSec=600
UNIT

cat >"$TIMER_UNIT" <<'UNIT'
[Unit]
Description=Run VM benchmark daily

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=1h
Unit=otel-vm-benchmark.service

[Install]
WantedBy=timers.target
UNIT

systemctl daemon-reload
if [ "$DO_TIMER" = 1 ]; then
	systemctl enable --now "$TIMER_NAME" >/dev/null
	log "enabled + started $TIMER_NAME (daily, persistent, randomized delay)"
else
	log "timer not enabled (--no-timer); run manually with: systemctl start $SERVICE_NAME"
fi
log "installed $SERVICE_UNIT + $TIMER_UNIT"

# ---------------- 5. wire into existing collector ----------------
if [ -n "$COLLECTOR_CONFIG" ]; then
	wire_collector "$COLLECTOR_CONFIG" || true
fi
# (wire_collector is defined above, near the helpers)

# ---------------- 6. endpoint sanity check ----------------
if command -v curl >/dev/null 2>&1; then
	code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
		-X POST -H 'Content-Type: application/json' -d '{}' "$ENDPOINT" 2>/dev/null || true)"
	case "$code" in
	200 | 202 | 204 | 400 | 404 | 405 | 413) log "endpoint reachable (HTTP $code on $ENDPOINT)" ;;
	"") log "warning: no HTTP response from $ENDPOINT — is the collector/OpenObserve up?" ;;
	*) log "warning: unexpected HTTP $code from $ENDPOINT" ;;
	esac
fi

# ---------------- 7. optional test run ----------------
if [ "$DO_TEST" = 1 ]; then
	log "running benchmark once (takes ~2.5 min)..."
	"$INSTALL_DIR/otel-vm-benchmark.sh" || log "benchmark run exited nonzero — check journalctl -u $SERVICE_NAME"
fi

# ---------------- summary ----------------
echo
log "done. summary:"
echo "  script:  $INSTALL_DIR/otel-vm-benchmark.sh"
echo "  env:     $ENV_FILE"
echo "  timer:   $TIMER_NAME (next: $(systemctl list-timers "$TIMER_NAME" --no-pager -l 2>/dev/null | grep -o '[0-9].*ago\|[0-9].*left' | head -1 || echo 'see systemctl list-timers'))"
echo "  logs:    journalctl -u $SERVICE_NAME -f"
echo "  manual:  systemctl start $SERVICE_NAME"
if [ -n "$COLLECTOR_CONFIG" ]; then
	echo "  note:    restart your collector to pick up the otlp receiver (config backed up in $COLLECTOR_CONFIG.bak.*)"
fi
