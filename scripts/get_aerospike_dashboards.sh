#!/usr/bin/env bash
set -euo pipefail

VERSION="v3.8.0"
TMP="$(mktemp -d)"
DEST="platform/observability/kube-prometheus-stack/dashboards/aerospike/json"

rm -rf "$DEST"
mkdir -p "$DEST"

curl -L "https://github.com/aerospike/aerospike-monitoring/archive/refs/tags/${VERSION}.tar.gz" \
  -o "$TMP/aerospike-monitoring.tar.gz"

tar -xzf "$TMP/aerospike-monitoring.tar.gz" -C "$TMP"

SRC="$TMP/aerospike-monitoring-${VERSION#v}/config/grafana/dashboards"

find "$SRC" -type f -name '*.json' -exec cp {} "$DEST/" \;

cat >platform/observability/kube-prometheus-stack/dashboards/aerospike/kustomization.yaml <<'EOF'
namespace: monitoring

configMapGenerator:
  - name: grafana-dashboard-aerospike
    files:
EOF

find "$DEST" -maxdepth 1 -type f -name '*.json' -printf '      - json/%f\n' | sort >>platform/observability/kube-prometheus-stack/dashboards/aerospike/kustomization.yaml

cat >>platform/observability/kube-prometheus-stack/dashboards/aerospike/kustomization.yaml <<'EOF'

generatorOptions:
  disableNameSuffixHash: true
  labels:
    grafana_dashboard: "1"
EOF
