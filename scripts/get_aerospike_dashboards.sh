#!/usr/bin/env bash
set -euo pipefail

VERSION="v3.8.0"
TMP="$(mktemp -d)"
DEST="platform/observability/kube-prometheus-stack/dashboards/aerospike/json"
KUSTOMIZATION="platform/observability/kube-prometheus-stack/dashboards/aerospike/kustomization.yaml"

cleanup() {
  rm -rf "$TMP"
}
trap cleanup EXIT

rm -rf "$DEST"
mkdir -p "$DEST"

curl -L "https://github.com/aerospike/aerospike-monitoring/archive/refs/tags/${VERSION}.tar.gz" \
  -o "$TMP/aerospike-monitoring.tar.gz"

tar -xzf "$TMP/aerospike-monitoring.tar.gz" -C "$TMP"

SRC="$TMP/aerospike-monitoring-${VERSION#v}/config/grafana/dashboards"

# Copy all nested dashboard JSON files into one flat json/ dir.
# Prefix with relative path to avoid filename collisions.
find "$SRC" -type f -name '*.json' | sort | while read -r file; do
  rel="${file#"$SRC"/}"
  flat="$(echo "$rel" | tr '/' '-' | tr '[:upper:]' '[:lower:]')"
  cp "$file" "$DEST/$flat"
done

cat >"$KUSTOMIZATION" <<'EOF'
namespace: monitoring

configMapGenerator:
EOF

# One ConfigMap per dashboard JSON to avoid Kubernetes object size limits.
find "$DEST" -maxdepth 1 -type f -name '*.json' | sort | while read -r file; do
  base="$(basename "$file" .json)"
  safe="$(echo "$base" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' | sed 's/^-//; s/-$//')"

  cat >>"$KUSTOMIZATION" <<EOF
  - name: grafana-dashboard-aerospike-${safe}
    files:
      - json/$(basename "$file")
EOF
done

cat >>"$KUSTOMIZATION" <<'EOF'

generatorOptions:
  disableNameSuffixHash: true
  labels:
    grafana_dashboard: "1"
EOF
