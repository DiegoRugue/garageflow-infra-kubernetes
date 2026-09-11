#!/usr/bin/env bash

resolve_runner_public_ipv4() {
  local candidate
  if ! candidate="$(curl \
    --fail \
    --ipv4 \
    --silent \
    --show-error \
    --location \
    --proto '=https' \
    --proto-redir '=https' \
    --connect-timeout 5 \
    --max-time 15 \
    'https://checkip.amazonaws.com')"; then
    echo "Deployment refused: unable to determine the current runner public IPv4." >&2
    return 1
  fi

  "${PYTHON_BIN:-python3}" - "${candidate}" <<'PY'
import ipaddress
import sys

try:
    address = ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit("Deployment refused: runner lookup did not return a valid public IPv4.")

if address.version != 4 or not address.is_global:
    raise SystemExit("Deployment refused: runner lookup did not return a valid public IPv4.")

print(address)
PY
}

merge_runner_access_cidrs() {
  local configured_cidrs="$1"
  local runner_ipv4="$2"

  "${PYTHON_BIN:-python3}" - "${configured_cidrs}" "${runner_ipv4}" <<'PY'
import ipaddress
import json
import sys

try:
    configured = json.loads(sys.argv[1])
except (TypeError, ValueError):
    raise SystemExit("Deployment refused: configured EKS access CIDRs are not valid JSON.")

if not isinstance(configured, list) or not configured:
    raise SystemExit("Deployment refused: configured EKS access CIDRs must be a nonempty JSON array.")

validated = []
for value in configured:
    if not isinstance(value, str) or not value or value != value.strip():
        raise SystemExit("Deployment refused: configured EKS access CIDRs must contain clean IPv4 CIDR strings.")
    try:
        network = ipaddress.ip_network(value, strict=True)
    except ValueError:
        raise SystemExit("Deployment refused: configured EKS access CIDRs must contain valid IPv4 CIDRs.")
    if network.version != 4:
        raise SystemExit("Deployment refused: configured EKS access CIDRs must contain valid IPv4 CIDRs.")
    if value in validated:
        raise SystemExit("Deployment refused: configured EKS access CIDRs must not contain duplicates.")
    validated.append(value)

runner = ipaddress.ip_address(sys.argv[2])
runner_cidr = f"{runner}/32"
if runner_cidr not in validated:
    validated.append(runner_cidr)

print(json.dumps(validated, separators=(",", ":")))
PY
}

resolve_runner_access_cidrs() {
  local configured_cidrs="$1"
  local runner_ipv4

  runner_ipv4="$(resolve_runner_public_ipv4)" || return 1
  merge_runner_access_cidrs "${configured_cidrs}" "${runner_ipv4}"
}

now_epoch_seconds() {
  date +%s
}

wait_for_ready_nodes() {
  local timeout_seconds="$1"
  local poll_interval_seconds="$2"
  local request_timeout="$3"

  [[ "${timeout_seconds}" =~ ^[1-9][0-9]*$ ]] || {
    echo "Platform verification failed: readiness timeout must be a positive integer." >&2
    return 1
  }
  [[ "${poll_interval_seconds}" =~ ^[1-9][0-9]*$ ]] || {
    echo "Platform verification failed: readiness poll interval must be a positive integer." >&2
    return 1
  }
  [[ "${request_timeout}" =~ ^[1-9][0-9]*s$ ]] || {
    echo "Platform verification failed: kubectl request timeout must use a positive number of seconds." >&2
    return 1
  }

  local deadline
  local last_observation="no readiness request completed"
  local node_output
  local ready_nodes
  local request_status
  local now
  deadline=$(( $(now_epoch_seconds) + timeout_seconds ))

  while true; do
    if node_output="$(kubectl get nodes --request-timeout="${request_timeout}" --no-headers 2>&1)"; then
      ready_nodes="$(awk '$2 == "Ready" { count++ } END { print count + 0 }' <<<"${node_output}")"
      if (( ready_nodes >= 2 )); then
        echo "EKS readiness verified: ${ready_nodes} Ready nodes."
        return 0
      fi
      last_observation="last successful request reported ${ready_nodes} Ready nodes"
    else
      request_status=$?
      last_observation="last kubectl request failed with exit status ${request_status}"
    fi

    now="$(now_epoch_seconds)"
    if (( now >= deadline )); then
      break
    fi
    sleep "${poll_interval_seconds}"
  done

  echo "Platform verification failed: readiness deadline reached; ${last_observation}." >&2
  return 1
}
