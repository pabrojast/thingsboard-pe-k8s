#!/bin/bash
#
# Schema Migration Recovery Script
# 
# This script fixes the database schema that is stuck at version 3.7.0
# by running each intermediate upgrade step with the correct Docker image.
#
# Current state: schema_version = 3007000 (3.7.0), missing columns:
#   - tb_schema_settings.product
#   - component_descriptor.has_secrets
#
# Upgrade path:
#   CE 3.7.0 -> CE 3.8.0 -> CE 3.9.0 -> PE 4.0.0 -> PE 4.0.2 -> PE 4.1.0 -> PE 4.2.0 -> PE 4.2.1.2 -> PE 4.3.0.1
#

set -e

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

    # Create temporary database-setup pod with the specific image
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
    kubectl exec tb-db-setup -- sh -c "export UPGRADE_TB=true; export FROM_VERSION=$FROM_VERSION; start-tb-node.sh; touch /tmp/install-finished;"

    echo "Cleaning up pod..."
    kubectl delete pod tb-db-setup --wait=true

    echo ""
    echo "  ✅ $STEP_NAME completed successfully!"
    echo ""

    # Small pause between steps
    sleep 5
}

echo ""
echo "========================================================="
echo "  ThingsBoard Schema Migration Recovery"
echo "  Starting from schema version 3.7.0 (3007000)"
echo "========================================================="
echo ""
echo "⚠️  IMPORTANT: Make sure you have a database backup before proceeding!"
echo ""
read -p "Press Enter to continue or Ctrl+C to abort..."

# Step 1: CE 3.7.0 -> CE 3.8.0
run_upgrade "thingsboard/tb-node:3.8.0" "3.7.0" "CE 3.7.0 → CE 3.8.0"

# Step 2: CE 3.8.0 -> CE 3.9.0 (3.8.1 upgrade doesn't have schema changes per official docs)
run_upgrade "thingsboard/tb-node:3.9" "3.8.1" "CE 3.8.x → CE 3.9.0"

# Step 3: CE 3.9.0 -> CE 3.9.1 (no fromVersion needed per official docs, but pass it anyway)
run_upgrade "thingsboard/tb-node:3.9.1" "3.9.0" "CE 3.9.0 → CE 3.9.1"

# Step 4: CE 3.9.1 -> PE 4.0.0
run_upgrade "thingsboard/tb-pe-node:4.0.0PE" "3.9.1" "CE 3.9.1 → PE 4.0.0"

# Step 5: PE 4.0.0 -> PE 4.0.2
run_upgrade "thingsboard/tb-pe-node:4.0.2PE" "4.0.0" "PE 4.0.0 → PE 4.0.2"

# Step 6: PE 4.0.2 -> PE 4.1.0
run_upgrade "thingsboard/tb-pe-node:4.1.0PE" "4.0.2" "PE 4.0.2 → PE 4.1.0"

# Step 7: PE 4.1.0 -> PE 4.2.0
run_upgrade "thingsboard/tb-pe-node:4.2.0PE" "4.1.0" "PE 4.1.0 → PE 4.2.0"

# Step 8: PE 4.2.0 -> PE 4.2.1.2
run_upgrade "thingsboard/tb-pe-node:4.2.1.2PE" "4.2.0" "PE 4.2.0 → PE 4.2.1.2"

# Step 9: PE 4.2.1.2 -> PE 4.3.0.1
run_upgrade "thingsboard/tb-pe-node:4.3.0.1PE" "4.2.1.2" "PE 4.2.1.2 → PE 4.3.0.1"

echo ""
echo "========================================================="
echo "  ✅ All schema migrations completed successfully!"
echo "  "
echo "  Now restart your ThingsBoard node:"
echo "    kubectl rollout restart statefulset tb-node -n $NAMESPACE"
echo "========================================================="
echo ""
