#!/usr/bin/env bash
# deploy-extras.sh — Deploy Chaos Mesh, Chatbot RAG App, and Snowem to the
# GKE cluster, all pointed at the Elastic Observability serverless project.
#
# Prerequisites:
#   - kubectl configured for the GKE cluster
#   - helm repos: chaos-mesh.org/chaos-mesh
#   - GitHub Actions has already pushed the Docker images to DockerHub:
#       {DOCKERHUB_USERNAME}/o11y-metrics-snowem:latest
#       {DOCKERHUB_USERNAME}/elastic-inference-proxy:latest
#   - o11y-metrics namespace exists (created by deploy-k8s.sh)
#
# Usage:
#   export OBSERVABILITY_ES_URL=https://kenneth-sandbox-d54ee0.es.asia-southeast1.gcp.elastic.cloud
#   export OBSERVABILITY_API_KEY=<key>
#   export DOCKERHUB_USERNAME=<your-dockerhub-username>
#   ./scripts/deploy-extras.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TERRAFORM_DIR="${SCRIPT_DIR}/../terraform"

ES_URL="${OBSERVABILITY_ES_URL:-https://kenneth-sandbox-d54ee0.es.asia-southeast1.gcp.elastic.cloud}"
API_KEY="${OBSERVABILITY_API_KEY:?ERROR: set OBSERVABILITY_API_KEY}"
DOCKERHUB_USER="${DOCKERHUB_USERNAME:-}"
DEMO_NS="o11y-metrics"

step() { echo; echo "══════════════════════════════════════════════"; echo "▶  $*"; echo "══════════════════════════════════════════════"; }

if [[ -z "${DOCKERHUB_USER}" ]]; then
  echo "ERROR: Set DOCKERHUB_USERNAME to your DockerHub username"
  exit 1
fi

# ── Step 1: Chaos Mesh ────────────────────────────────────────────────────
step "1/4  Install Chaos Mesh"
helm repo add chaos-mesh https://charts.chaos-mesh.org 2>/dev/null || true
helm repo update chaos-mesh

helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh \
  --create-namespace \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
  --set dashboard.securityMode=false \
  --wait --timeout 5m
echo "  Chaos Mesh installed."

# Expose the dashboard via LoadBalancer
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: chaos-dashboard-lb
  namespace: chaos-mesh
spec:
  type: LoadBalancer
  selector:
    app.kubernetes.io/name: chaos-mesh
    app.kubernetes.io/component: chaos-dashboard
  ports:
  - port: 2333
    targetPort: 2333
EOF
echo "  Chaos Dashboard LoadBalancer created."

# ── Step 2: Chaos Experiments ─────────────────────────────────────────────
step "2/4  Apply chaos experiments (paused — resume via Chaos Dashboard)"
helm upgrade --install chaos-experiments "${TERRAFORM_DIR}/chaos-experiments" \
  --namespace "${DEMO_NS}" \
  --wait --timeout 2m
echo "  7 experiments installed (paused). Resume via Chaos Dashboard."

# ── Step 3: Elastic Inference Proxy + Chatbot RAG ─────────────────────────
step "3/4  Deploy elastic-inference-proxy + chatbot-rag-app"

# Secret for the proxy and chatbot-rag (ES credentials + ELSER model)
kubectl create secret generic chatbot-rag-es-creds \
  --namespace "${DEMO_NS}" \
  --from-literal=ES_URL="${ES_URL}" \
  --from-literal=ES_API_KEY="${API_KEY}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f - <<EOF
# ── elastic-inference-proxy ──────────────────────────────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: elastic-inference-proxy
  namespace: ${DEMO_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: elastic-inference-proxy
  template:
    metadata:
      labels:
        app: elastic-inference-proxy
    spec:
      containers:
      - name: proxy
        image: ${DOCKERHUB_USER}/elastic-inference-proxy:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 8080
        env:
        - name: ES_URL
          valueFrom:
            secretKeyRef:
              name: chatbot-rag-es-creds
              key: ES_URL
        - name: ES_API_KEY
          valueFrom:
            secretKeyRef:
              name: chatbot-rag-es-creds
              key: ES_API_KEY
        - name: INFERENCE_ID
          value: ".anthropic-claude-4.6-sonnet-chat_completion"
        resources:
          requests:
            cpu: "10m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "128Mi"
        readinessProbe:
          httpGet:
            path: /health
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: elastic-inference-proxy
  namespace: ${DEMO_NS}
spec:
  selector:
    app: elastic-inference-proxy
  ports:
  - port: 8080
    targetPort: 8080
---
# ── chatbot-rag-app ──────────────────────────────────────────────────────
apiVersion: apps/v1
kind: Deployment
metadata:
  name: chatbot-rag-app
  namespace: ${DEMO_NS}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: chatbot-rag-app
  template:
    metadata:
      labels:
        app: chatbot-rag-app
    spec:
      initContainers:
      - name: create-index
        image: ghcr.io/elastic/elasticsearch-labs/chatbot-rag-app:latest
        command: ["opentelemetry-instrument"]
        args: ["flask", "create-index"]
        env:
        - name: FLASK_APP
          value: "api/app.py"
        - name: PYTHONUNBUFFERED
          value: "1"
        - name: ELASTICSEARCH_URL
          valueFrom:
            secretKeyRef:
              name: chatbot-rag-es-creds
              key: ES_URL
        - name: ELASTICSEARCH_API_KEY
          valueFrom:
            secretKeyRef:
              name: chatbot-rag-es-creds
              key: ES_API_KEY
        - name: ES_INDEX
          value: "workplace-app-docs"
        - name: ES_INDEX_CHAT_HISTORY
          value: "workplace-app-docs-chat-history"
        - name: ELSER_MODEL
          value: ".elser-2-elastic"
        # LLM — routed through elastic-inference-proxy
        - name: LLM_TYPE
          value: "openai"
        - name: OPENAI_BASE_URL
          value: "http://elastic-inference-proxy:8080/v1"
        - name: OPENAI_API_KEY
          value: "elastic-managed"
        - name: CHAT_MODEL
          value: "claude-sonnet"
        # OTEL
        - name: OTEL_SDK_DISABLED
          value: "false"
        - name: OTEL_SERVICE_NAME
          value: "chatbot-rag"
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          value: "http/protobuf"
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://opentelemetry-kube-stack-daemon-collector.opentelemetry-operator-system.svc.cluster.local:4318"
        - name: OTEL_EXPORTER_OTLP_HEADERS
          value: "Authorization=ApiKey ${API_KEY}"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "deployment.environment=chatbot-rag"
        - name: OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT
          value: "true"
      containers:
      - name: api-frontend
        image: ghcr.io/elastic/elasticsearch-labs/chatbot-rag-app:latest
        imagePullPolicy: Always
        command: ["opentelemetry-instrument"]
        args: ["python", "api/app.py"]
        ports:
        - containerPort: 4000
        env:
        - name: FLASK_APP
          value: "api/app.py"
        - name: PYTHONUNBUFFERED
          value: "1"
        - name: ELASTICSEARCH_URL
          valueFrom:
            secretKeyRef:
              name: chatbot-rag-es-creds
              key: ES_URL
        - name: ELASTICSEARCH_API_KEY
          valueFrom:
            secretKeyRef:
              name: chatbot-rag-es-creds
              key: ES_API_KEY
        - name: ES_INDEX
          value: "workplace-app-docs"
        - name: ES_INDEX_CHAT_HISTORY
          value: "workplace-app-docs-chat-history"
        - name: ELSER_MODEL
          value: ".elser-2-elastic"
        - name: LLM_TYPE
          value: "openai"
        - name: OPENAI_BASE_URL
          value: "http://elastic-inference-proxy:8080/v1"
        - name: OPENAI_API_KEY
          value: "elastic-managed"
        - name: CHAT_MODEL
          value: "claude-sonnet"
        - name: OTEL_SDK_DISABLED
          value: "false"
        - name: OTEL_SERVICE_NAME
          value: "chatbot-rag"
        - name: OTEL_EXPORTER_OTLP_PROTOCOL
          value: "http/protobuf"
        - name: OTEL_EXPORTER_OTLP_ENDPOINT
          value: "http://opentelemetry-kube-stack-daemon-collector.opentelemetry-operator-system.svc.cluster.local:4318"
        - name: OTEL_EXPORTER_OTLP_HEADERS
          value: "Authorization=ApiKey ${API_KEY}"
        - name: OTEL_RESOURCE_ATTRIBUTES
          value: "deployment.environment=chatbot-rag"
        - name: OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT
          value: "true"
        - name: OTEL_METRIC_EXPORT_INTERVAL
          value: "3000"
        - name: OTEL_BSP_SCHEDULE_DELAY
          value: "3000"
        - name: OTEL_EXPERIMENTAL_RESOURCE_DETECTORS
          value: "process_runtime,os,otel,telemetry_distro"
        resources:
          requests:
            cpu: "15m"
            memory: "512Mi"
          limits:
            cpu: "500m"
            memory: "1Gi"
---
apiVersion: v1
kind: Service
metadata:
  name: chatbot-rag-app
  namespace: ${DEMO_NS}
spec:
  selector:
    app: chatbot-rag-app
  ports:
  - port: 4000
    targetPort: 4000
  type: LoadBalancer
EOF
echo "  elastic-inference-proxy + chatbot-rag-app deployed."

# ── Step 4: Snowem ────────────────────────────────────────────────────────
step "4/4  Deploy Snowem (mock ServiceNow)"
kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: snowem-data
  namespace: ${DEMO_NS}
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: snowem
  namespace: ${DEMO_NS}
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: snowem
  template:
    metadata:
      labels:
        app: snowem
    spec:
      containers:
      - name: snowem
        image: ${DOCKERHUB_USER}/o11y-metrics-snowem:latest
        imagePullPolicy: Always
        ports:
        - containerPort: 3000
        env:
        - name: NO_TLS
          value: "1"
        - name: SNOWEM_DB_PATH
          value: "/data/snowem.db"
        volumeMounts:
        - name: data
          mountPath: /data
        resources:
          requests:
            cpu: "30m"
            memory: "128Mi"
          limits:
            cpu: "300m"
            memory: "256Mi"
      volumes:
      - name: data
        persistentVolumeClaim:
          claimName: snowem-data
---
apiVersion: v1
kind: Service
metadata:
  name: snowem
  namespace: ${DEMO_NS}
spec:
  selector:
    app: snowem
  ports:
  - port: 3000
    targetPort: 3000
  type: LoadBalancer
EOF
echo "  Snowem deployed."

echo
echo "✅  deploy-extras.sh complete."
echo
echo "Waiting for LoadBalancer IPs (may take 60s)..."
sleep 15

CHATBOT_IP=$(kubectl get svc chatbot-rag-app -n "${DEMO_NS}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
SNOWEM_IP=$(kubectl get svc snowem -n "${DEMO_NS}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")
CHAOS_IP=$(kubectl get svc chaos-dashboard-lb -n chaos-mesh -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "pending")

echo
echo "Service endpoints:"
echo "  Chatbot RAG:    http://${CHATBOT_IP}:4000"
echo "  Snowem:         http://${SNOWEM_IP}:3000"
echo "  Chaos Dashboard: http://${CHAOS_IP}:2333"
echo
echo "If IPs show 'pending', check with:"
echo "  kubectl get svc -n ${DEMO_NS} chatbot-rag-app snowem"
echo "  kubectl get svc -n chaos-mesh chaos-dashboard-lb"
echo
echo "Chaos experiments are installed PAUSED. Resume them in the Chaos Dashboard."
echo "All 7 experiments target pods in namespace: ${DEMO_NS}"
