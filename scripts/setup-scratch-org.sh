#!/usr/bin/env bash
set -euo pipefail

ORG_ALIAS="${1:-agentforce-rag}"
DURATION_DAYS="${2:-1}"
SF_CMD="${SF_CMD:-sf}"

if [[ -x "./sf-cli/bin/sf" ]]; then
  SF_CMD="./sf-cli/bin/sf"
fi

export SF_USE_GENERIC_UNIX_KEYCHAIN="${SF_USE_GENERIC_UNIX_KEYCHAIN:-true}"
export SFDX_USE_GENERIC_UNIX_KEYCHAIN="${SFDX_USE_GENERIC_UNIX_KEYCHAIN:-true}"

echo "Creating scratch org: ${ORG_ALIAS}"
"${SF_CMD}" org create scratch \
  --definition-file config/project-scratch-def.json \
  --alias "${ORG_ALIAS}" \
  --duration-days "${DURATION_DAYS}" \
  --set-default \
  --wait 30

echo "Deploying metadata to ${ORG_ALIAS}"
"${SF_CMD}" project deploy start --target-org "${ORG_ALIAS}" --source-dir force-app --wait 30

echo "Assigning permission set AgentforceRAGUser"
"${SF_CMD}" org assign permset --target-org "${ORG_ALIAS}" --name AgentforceRAGUser

SEED_FILE="$(mktemp -t policy_seed.XXXXXX.apex)"
cat <<'APEX' > "${SEED_FILE}"
insert new List<Policy__c>{
    new Policy__c(
        Name = 'Return Policy',
        Policy_Text__c = 'Customers can return unopened products within 30 calendar days from delivery with proof of purchase.',
        Source_URL__c = 'https://policies.example.com/returns',
        Is_Active__c = true
    ),
    new Policy__c(
        Name = 'Billing Dispute Policy',
        Policy_Text__c = 'Billing disputes must be submitted within 60 days from invoice date through the service portal.',
        Source_URL__c = 'https://policies.example.com/billing-disputes',
        Is_Active__c = true
    ),
    new Policy__c(
        Name = 'Data Retention Policy',
        Policy_Text__c = 'Billing and service records are retained for seven years to satisfy audit obligations.',
        Source_URL__c = 'https://policies.example.com/data-retention',
        Is_Active__c = true
    )
};
System.debug('Seeded Policy__c records for Agentforce RAG demo.');
APEX

echo "Seeding baseline policy records"
"${SF_CMD}" apex run --target-org "${ORG_ALIAS}" --file "${SEED_FILE}"
rm -f "${SEED_FILE}"

echo "Scratch org ${ORG_ALIAS} is ready."
