#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-noppflow-local}"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_PORT="${REGISTRY_PORT:-5001}"
CONTROLLER_NS="${CONTROLLER_NS:-noppflow}"
APPS_NS="${APPS_NS:-apps}"
APP_IMAGE="${APP_IMAGE:-localhost:${REGISTRY_PORT}/noppflow:kind}"
RUNNER_IMAGE="${RUNNER_IMAGE:-localhost:${REGISTRY_PORT}/noppflow-runner:kind}"
CONTAINER_CLI="${CONTAINER_CLI:-docker}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.30.8}"
DB_MODE="${DB_MODE:-sqlite}"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "error: required command not found: $1" >&2
    exit 1
  fi
}

push_image() {
  local image="$1"
  if [ "${CONTAINER_CLI}" = "podman" ]; then
    "${CONTAINER_CLI}" push --tls-verify=false "${image}"
  else
    "${CONTAINER_CLI}" push "${image}"
  fi
}

require_container_runtime() {
  if ! "${CONTAINER_CLI}" info >/dev/null 2>&1; then
    if [ "${CONTAINER_CLI}" = "podman" ]; then
      cat >&2 <<'MSG'
error: Podman is not running/ready.

Start Podman machine and rerun:
- podman machine start

Then run:
- CONTAINER_CLI=podman ./k8s/setup-kind-local.sh
MSG
    else
      cat >&2 <<'MSG'
error: Docker daemon is not running.

Start Docker and rerun:
- Docker Desktop (macOS): open -a Docker
- Colima: colima start
MSG
    fi
    exit 1
  fi
}

require_podman_rootful() {
  if [ "${CONTAINER_CLI}" != "podman" ]; then
    return
  fi
  if ! podman machine inspect 2>/dev/null | grep -q '"Rootful": true'; then
    cat >&2 <<'MSG'
error: kind with Podman requires rootful podman machine in most environments.

Fix:
1) podman machine stop
2) podman machine set --rootful --cpus 4 --memory 8192
3) podman machine start
4) rerun: CONTAINER_CLI=podman ./k8s/setup-kind-local.sh
MSG
    exit 1
  fi
}

for cmd in "${CONTAINER_CLI}" kind kubectl; do
  require_cmd "$cmd"
done
require_container_runtime
require_podman_rootful

if [ "${CONTAINER_CLI}" = "podman" ]; then
  export KIND_EXPERIMENTAL_PROVIDER="${KIND_EXPERIMENTAL_PROVIDER:-podman}"
fi

echo "[1/9] Ensuring local registry container (${REGISTRY_NAME})"
if ! "${CONTAINER_CLI}" inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" >/dev/null 2>&1; then
  "${CONTAINER_CLI}" run -d --restart=always -p "127.0.0.1:${REGISTRY_PORT}:5000" --name "${REGISTRY_NAME}" registry:2
else
  echo "- registry already running"
fi

echo "[2/9] Ensuring kind cluster (${CLUSTER_NAME})"
if ! kind get clusters | grep -qx "${CLUSTER_NAME}"; then
  KIND_CONFIG="$(mktemp)"
  cat > "${KIND_CONFIG}" <<CFG
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REGISTRY_PORT}"]
      endpoint = ["http://${REGISTRY_NAME}:5000"]
nodes:
  - role: control-plane
CFG
  kind create cluster --name "${CLUSTER_NAME}" --image "${KIND_NODE_IMAGE}" --config "${KIND_CONFIG}"
  rm -f "${KIND_CONFIG}"
else
  echo "- cluster already exists"
fi

echo "[3/9] Connecting registry to kind network"
if [ "$("${CONTAINER_CLI}" inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}")" = 'null' ]; then
  if ! "${CONTAINER_CLI}" network connect kind "${REGISTRY_NAME}"; then
    echo "error: failed to connect ${REGISTRY_NAME} to 'kind' network" >&2
    echo "hint: verify kind cluster is running and Podman/Docker can see network 'kind'" >&2
    exit 1
  fi
else
  echo "- registry already connected to kind network"
fi

echo "[4/9] Configuring local registry discovery in cluster"
cat <<MAP | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
MAP

echo "[5/9] Building and pushing images"
"${CONTAINER_CLI}" build -t "${APP_IMAGE}" -f Dockerfile .
push_image "${APP_IMAGE}"
"${CONTAINER_CLI}" build -t "${RUNNER_IMAGE}" -f Dockerfile.runner .
push_image "${RUNNER_IMAGE}"

echo "[6/9] Creating namespaces"
kubectl get ns "${CONTROLLER_NS}" >/dev/null 2>&1 || kubectl create ns "${CONTROLLER_NS}"
kubectl get ns "${APPS_NS}" >/dev/null 2>&1 || kubectl create ns "${APPS_NS}"

echo "[7/9] Preparing database mode (${DB_MODE})"
if [ "${DB_MODE}" = "mysql" ]; then
  kubectl -n "${CONTROLLER_NS}" apply -f k8s/mysql.kind.yaml
  kubectl -n "${CONTROLLER_NS}" create secret generic noppflow-db \
    --from-literal=dsn="noppflow:noppflow@tcp(mysql.${CONTROLLER_NS}.svc.cluster.local:3306)/noppflow?parseTime=true" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "${CONTROLLER_NS}" rollout status deploy/mysql --timeout=240s
else
  echo "- using sqlite for local setup (default)"
fi

echo "[8/9] Applying RBAC"
cat <<SA | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: noppflow-controller
  namespace: ${CONTROLLER_NS}
SA

cat <<CTRL | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: noppflow-controller
  namespace: ${APPS_NS}
rules:
  - apiGroups: ["batch"]
    resources: ["jobs"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: noppflow-controller
  namespace: ${APPS_NS}
subjects:
  - kind: ServiceAccount
    name: noppflow-controller
    namespace: ${CONTROLLER_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: noppflow-controller
CTRL

cat <<RUNNER | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: noppflow-runner
  namespace: ${APPS_NS}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: noppflow-runner
  namespace: ${APPS_NS}
rules:
  - apiGroups: ["", "apps", "batch", "networking.k8s.io"]
    resources: ["pods", "services", "configmaps", "secrets", "deployments", "statefulsets", "jobs", "cronjobs", "ingresses"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: noppflow-runner
  namespace: ${APPS_NS}
subjects:
  - kind: ServiceAccount
    name: noppflow-runner
    namespace: ${APPS_NS}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: noppflow-runner
RUNNER

echo "[9/9] Deploying NoppFlow"
kubectl -n "${CONTROLLER_NS}" apply -f k8s/deployment.yaml
kubectl -n "${CONTROLLER_NS}" apply -f k8s/service.yaml
kubectl -n "${CONTROLLER_NS}" set image deploy/noppflow noppflow="${APP_IMAGE}"
if [ "${DB_MODE}" = "mysql" ]; then
  kubectl -n "${CONTROLLER_NS}" set env deploy/noppflow DB_DRIVER=mysql
else
  kubectl -n "${CONTROLLER_NS}" set env deploy/noppflow DB_DRIVER=sqlite3 DB_DSN-
fi
kubectl -n "${CONTROLLER_NS}" rollout status deploy/noppflow --timeout=300s

echo
echo "Local kind environment is ready."
echo "- Cluster: ${CLUSTER_NAME}"
echo "- NoppFlow namespace: ${CONTROLLER_NS}"
echo "- Apps namespace: ${APPS_NS}"
echo "- App image: ${APP_IMAGE}"
echo "- Runner image: ${RUNNER_IMAGE}"
echo
echo "Access UI with:"
echo "kubectl -n ${CONTROLLER_NS} port-forward svc/noppflow 8080:80"
echo "Then open: http://localhost:8080 (admin/admin)"
echo
echo "When creating an app with k8s_deploy, use:"
echo "- k8s_namespace: ${APPS_NS}"
echo "- k8s_service_account: noppflow-runner"
echo "- k8s_runner_image: ${RUNNER_IMAGE}"
