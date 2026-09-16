#!/usr/bin/env bash
#
# Build (package) charts EXACTLY the way the release workflow does, so a PR can
# be validated locally before it is opened:
#
#   - lint:    helm lint charts/*   (.github/workflows/lint.yaml)
#   - release: cr package <chart>   (.github/workflows/release.yaml via
#              helm/chart-releaser-action — cr re-downloads dependencies from
#              Chart.yaml repositories; vendored tgz are IGNORED)
#
# Dependencies resolve from the repositories declared in Chart.yaml (our GAR
# OCI mirror for clustercontrol) — anonymous pull, no auth needed.
#
# Usage:
#   ./scripts/build-charts.sh [CHART_NAME ...]   # default: clustercontrol
#
# Output packages land in .cr-release-packages/ (same as CI), wiped per run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CR_VERSION="${CR_VERSION:-1.7.0}"   # release-dev.yaml pins 1.7.0
PKG_DIR="${REPO_ROOT}/.cr-release-packages"

CHARTS=("$@")
[[ ${#CHARTS[@]} -gt 0 ]] || CHARTS=(clustercontrol)

# --- ensure cr (chart-releaser) is available, same install as release-dev.yaml
ensure_cr() {
  command -v cr >/dev/null && return
  local arch os url cache="${HOME}/.cache/chart-releaser"
  if [[ -x "${cache}/cr" ]]; then PATH="${cache}:${PATH}"; return; fi
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "ERR  unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  url="https://github.com/helm/chart-releaser/releases/download/v${CR_VERSION}/chart-releaser_${CR_VERSION}_${os}_${arch}.tar.gz"
  echo "INFO installing cr v${CR_VERSION} to ${cache}"
  mkdir -p "${cache}"
  curl -fsSL "${url}" | tar -xz -C "${cache}" cr
  PATH="${cache}:${PATH}"
}
ensure_cr
echo "INFO using cr $(cr version 2>/dev/null | grep GitVersion || true)"

rm -rf "${PKG_DIR}"
mkdir -p "${PKG_DIR}"

fail=0
for name in "${CHARTS[@]}"; do
  chart="${REPO_ROOT}/charts/${name}"
  [[ -d "${chart}" ]] || { echo "ERR  no such chart: ${name}" >&2; exit 1; }
  echo "=== ${name} ==="

  echo "==> helm lint (lint.yaml)"
  helm lint "${chart}" || fail=1

  echo "==> cr package (release.yaml)"
  cr package "${chart}" --package-path "${PKG_DIR}" || fail=1
done

echo
if (( fail )); then
  echo "BUILD FAILED — fix the above before opening a PR"
  exit 1
fi
echo "BUILD OK — packages in ${PKG_DIR#"${REPO_ROOT}"/}:"
ls -l "${PKG_DIR}" | grep -v '^total' | sed 's/^/  /'
