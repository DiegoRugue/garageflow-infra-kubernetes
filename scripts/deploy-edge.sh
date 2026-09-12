#!/usr/bin/env bash
set -Eeuo pipefail
bash "$(dirname -- "${BASH_SOURCE[0]}")/deploy-edge-component.sh" edge
