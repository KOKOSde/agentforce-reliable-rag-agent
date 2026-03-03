#!/usr/bin/env bash
set -euo pipefail

TARGET_ORG="${1:-${SF_TARGET_ORG:-agentforce-rag}}"
MIN_COVERAGE="${MIN_APEX_COVERAGE:-85}"
RESULT_DIR="artifacts/test-results"
RESULT_FILE="${RESULT_DIR}/apex-test-result.json"
COVERAGE_FILE="artifacts/apex-coverage-summary.json"
SF_CMD="${SF_CMD:-sf}"

if [[ -x "./sf-cli/bin/sf" ]]; then
  SF_CMD="./sf-cli/bin/sf"
fi

export SF_USE_GENERIC_UNIX_KEYCHAIN="${SF_USE_GENERIC_UNIX_KEYCHAIN:-true}"
export SFDX_USE_GENERIC_UNIX_KEYCHAIN="${SFDX_USE_GENERIC_UNIX_KEYCHAIN:-true}"

mkdir -p "${RESULT_DIR}" "artifacts"

echo "Running Apex tests against org ${TARGET_ORG}"
"${SF_CMD}" apex run test \
  --target-org "${TARGET_ORG}" \
  --test-level RunLocalTests \
  --code-coverage \
  --result-format json \
  --wait 60 > "${RESULT_FILE}"

COVERAGE_RAW="$(jq -r '.result.summary.orgWideCoverage // .result.summary.testRunCoverage // .result.summary.orgWideCoveragePercent // .result.summary.testRunCoveragePercent // empty' "${RESULT_FILE}")"
COVERAGE_PERCENT="${COVERAGE_RAW%\%}"

if [[ -z "${COVERAGE_PERCENT}" || "${COVERAGE_PERCENT}" == "null" ]]; then
  echo "Unable to parse Apex coverage from ${RESULT_FILE}" >&2
  exit 1
fi

jq -n \
  --arg generatedAt "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
  --argjson apexCoveragePercent "${COVERAGE_PERCENT}" \
  --argjson minimumRequired "${MIN_COVERAGE}" \
  '{generatedAt:$generatedAt,apexCoveragePercent:$apexCoveragePercent,minimumRequired:$minimumRequired}' \
  > "${COVERAGE_FILE}"

echo "Apex coverage: ${COVERAGE_PERCENT}%"
awk -v coverage="${COVERAGE_PERCENT}" -v minimum="${MIN_COVERAGE}" 'BEGIN { exit (coverage + 0 >= minimum + 0) ? 0 : 1 }' || {
  echo "Coverage gate failed: ${COVERAGE_PERCENT}% < ${MIN_COVERAGE}%" >&2
  exit 1
}

echo "Coverage gate passed."
