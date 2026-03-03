#!/usr/bin/env bash
set -euo pipefail

ORG_ALIAS="${1:-agentforce-rag}"
SF_CMD="${SF_CMD:-sf}"

if [[ -x "./sf-cli/bin/sf" ]]; then
  SF_CMD="./sf-cli/bin/sf"
fi

export SF_USE_GENERIC_UNIX_KEYCHAIN="${SF_USE_GENERIC_UNIX_KEYCHAIN:-true}"
export SFDX_USE_GENERIC_UNIX_KEYCHAIN="${SFDX_USE_GENERIC_UNIX_KEYCHAIN:-true}"

echo "Deleting scratch org ${ORG_ALIAS}"
"${SF_CMD}" org delete scratch --target-org "${ORG_ALIAS}" --no-prompt
echo "Scratch org ${ORG_ALIAS} deleted."
