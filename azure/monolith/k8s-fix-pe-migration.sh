#!/bin/bash
#
# ThingsBoard PE Schema Migration Recovery Script (PE steps only)
# 
# Prerequisites: CE schema already migrated to 3.9.0 (3009000)
# This script runs the PE upgrade steps from 3.9.1 → 4.3.0.1PE
#

set -euo pipefail

NAMESPACE="ckan"
TIMEOUT="300s"

kubectl config set-context --current --namespace=$NAMESPACE

run_upgrade() {
    local IMAGE=$1
    local FROM_VERSION=$2
    local STEP_NAME=$3

    echo ""
    echo "=============================================="
    echo "  STEP: $STEP_NAME"
    echo "  Image: $IMAGE"
    echo "  From Version: $FROM_VERSION"
    echo "=============================================="
    echo ""

    # Clean up any leftover pod
    kubectl delete pod tb-db-setup -n $NAMESPACE --force --ignore-not-found 2>/dev/null || true

    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: tb-db-setup
  namespace: $NAMESPACE
spec:
  volumes:
  - name: tb-node-config
    configMap:
      name: tb-node-config
      items:
      - key: conf
        path: thingsboard.conf
      - key: logback
        path: logback.xml
  - name: tb-node-logs
    emptyDir: {}
  containers:
  - name: tb-db-setup
    imagePullPolicy: Always
    image: $IMAGE
    env:
      - name: TB_SERVICE_ID
        valueFrom:
          fieldRef:
            fieldPath: metadata.name
    envFrom:
    - configMapRef:
        name: tb-node-db-config
    volumeMounts:
      - mountPath: /config
        name: tb-node-config
      - mountPath: /var/log/thingsboard
        name: tb-node-logs
    command: ['sh', '-c', 'while [ ! -f /tmp/install-finished ]; do sleep 2; done;']
  restartPolicy: Never
EOF

    echo "Waiting for pod to be ready..."
    kubectl wait --for=condition=Ready pod/tb-db-setup --timeout=$TIMEOUT

    echo "Running upgrade from version $FROM_VERSION..."
    if ! kubectl exec tb-db-setup -- sh -c 'export UPGRADE_TB=true; export FROM_VERSION='"$FROM_VERSION"'; start-tb-node.sh; touch /tmp/install-finished;' 2>&1; then
        echo ""
        echo "  ⚠️  Upgrade step may have had warnings. Check output above."
        echo ""
    fi

    echo "Cleaning up pod..."
    kubectl delete pod tb-db-setup --wait=true

    echo ""
    echo "  ✅ $STEP_NAME completed!"
    echo ""

    sleep 5
}

echo ""
echo "========================================================="
echo "  ThingsBoard PE Schema Migration Recovery"
echo "  Running PE upgrade steps: 3.9.1 → 4.3.0.1PE"
echo "========================================================="
echo ""
echo "⚠️  Make sure CE schema has been migrated to 3.9.0 first!"
echo ""
read -p "Press Enter to continue or Ctrl+C to abort..."

# Step 1: → PE 4.0.0
run_upgrade "thingsboard/tb-pe-node:4.0.0PE" "3.9.1" "→ PE 4.0.0"

# Step 2: → PE 4.0.2
run_upgrade "thingsboard/tb-pe-node:4.0.2PE" "4.0.0" "→ PE 4.0.2"

# Step 3: → PE 4.1.0
run_upgrade "thingsboard/tb-pe-node:4.1.0PE" "4.0.2" "→ PE 4.1.0"

# Step 4: → PE 4.2.0
run_upgrade "thingsboard/tb-pe-node:4.2.0PE" "4.1.0" "→ PE 4.2.0"

# Step 5: → PE 4.2.1.2
run_upgrade "thingsboard/tb-pe-node:4.2.1.2PE" "4.2.0" "→ PE 4.2.1.2"

# Step 6: → PE 4.3.0.1
run_upgrade "thingsboard/tb-pe-node:4.3.0.1PE" "4.2.1.2" "→ PE 4.3.0.1"

echo ""
echo "========================================================="
echo "  ✅ All PE schema migrations completed!"
echo "  "
echo "  Now restart your ThingsBoard node:"
echo "    kubectl rollout restart statefulset tb-node -n $NAMESPACE"
echo "========================================================="
echo ""
