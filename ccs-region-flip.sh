#!/usr/bin/env bash
set -euo pipefail

# --- Input validation ---
if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <cluster-label> <role>"
  echo "  Example: $0 aquila-us-west-2 primary"
  exit 1
fi

CLUSTER_LABEL="$1"   # e.g. aquila-us-west-2
ROLE="$2"            # e.g. primary

# Extract prefix (everything before the first "-")
CLUSTER_PREFIX="${CLUSTER_LABEL%%-*}"   # e.g. aquila

TARGET_ANNOTATION="${CLUSTER_PREFIX}-${ROLE}"         # e.g. aquila-primary
SECONDARY_ANNOTATION="${CLUSTER_PREFIX}-secondary"    # e.g. aquila-secondary

NAMESPACE="argocd"
ANNOTATION_KEY="kargo.akuity.io/authorized-stage"
RESOURCE_TYPE="application"

echo "Cluster label   : ${CLUSTER_LABEL}"
echo "Cluster prefix  : ${CLUSTER_PREFIX}"
echo "Target suffix   : ${TARGET_ANNOTATION}"
echo "Secondary suffix: ${SECONDARY_ANNOTATION}"
echo ""

# --- Fetch all Application resources matching the cluster prefix ---
# Stores "name|ccs-cluster-label|existing-annotation" triples using while+read for bash 3.2 compatibility
RESOURCE_TRIPLES=()
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  RESOURCE_TRIPLES+=("${line}")
done < <(
  kubectl get "${RESOURCE_TYPE}" \
    -n "${NAMESPACE}" \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.labels.ccs-cluster}{"|"}{.metadata.annotations.kargo\.akuity\.io/authorized-stage}{"\n"}{end}' \
  | grep "|${CLUSTER_PREFIX}-"
)

if [[ ${#RESOURCE_TRIPLES[@]} -eq 0 ]]; then
  echo "ERROR: No ${RESOURCE_TYPE} resources found with a ccs-cluster label matching prefix '${CLUSTER_PREFIX}' in namespace ${NAMESPACE}."
  exit 1
fi

echo "Found ${#RESOURCE_TRIPLES[@]} resource(s):"
for TRIPLE in "${RESOURCE_TRIPLES[@]}"; do
  echo "  - ${TRIPLE}"
done
echo ""

# --- Apply annotations based on exact label match ---
for TRIPLE in "${RESOURCE_TRIPLES[@]}"; do
  RESOURCE_NAME="${TRIPLE%%|*}"                        # e.g. my-app
  REMAINDER="${TRIPLE#*|}"
  RESOURCE_LABEL="${REMAINDER%%|*}"                    # e.g. aquila-us-west-2
  EXISTING_ANNOTATION="${REMAINDER#*|}"                # e.g. kargo-ccs:aquila-primary

  # Safety check: skip resource if annotation key does not exist
  if [[ -z "${EXISTING_ANNOTATION}" ]]; then
    echo "SKIPPING ${RESOURCE_TYPE}/${RESOURCE_NAME} (ccs-cluster=${RESOURCE_LABEL}) -> annotation '${ANNOTATION_KEY}' does not exist on this resource."
    continue
  fi

  # Extract the value prefix before the colon (e.g. "kargo-ccs")
  ANNOTATION_VALUE_PREFIX="${EXISTING_ANNOTATION%%:*}"

  if [[ -z "${ANNOTATION_VALUE_PREFIX}" || "${ANNOTATION_VALUE_PREFIX}" == "${EXISTING_ANNOTATION}" ]]; then
    echo "ERROR: Could not extract annotation value prefix from '${EXISTING_ANNOTATION}' on resource '${RESOURCE_NAME}'. Expected format: '<prefix>:<value>'."
    exit 1
  fi

  if [[ "${RESOURCE_LABEL}" == "${CLUSTER_LABEL}" ]]; then
    NEW_VALUE="${ANNOTATION_VALUE_PREFIX}:${TARGET_ANNOTATION}"
  else
    NEW_VALUE="${ANNOTATION_VALUE_PREFIX}:${SECONDARY_ANNOTATION}"
  fi

  echo "Patching ${RESOURCE_TYPE}/${RESOURCE_NAME} (ccs-cluster=${RESOURCE_LABEL}) -> ${ANNOTATION_KEY}=${NEW_VALUE}"
  kubectl annotate "${RESOURCE_TYPE}" "${RESOURCE_NAME}" \
    -n "${NAMESPACE}" \
    "${ANNOTATION_KEY}=${NEW_VALUE}" \
    --overwrite
done

echo ""
echo "Done."
