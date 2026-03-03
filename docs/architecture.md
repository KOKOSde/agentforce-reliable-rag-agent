# Architecture

## Scope
This implementation delivers a grounded Agentforce customer-service agent for policy Q&A in a scratch org.

## Flow
1. A service rep asks a policy question in Agentforce or the `policyAssistant` LWC.
2. Prompt Builder instructions (versioned in `force-app/main/default/promptTemplates/PolicyAnswer.promptTemplate-meta.xml`) define response tone, refusal behavior, and mandatory citations.
3. `PolicyRAGAction` receives `{ queryText, sessionId }`, retrieves matching `Policy__c` records, and builds citation objects.
4. `PolicyRAGAction` calls `callout:SteeringAPI/v1/steer` to run offline governance checks before releasing an answer.
5. API response is emitted as:
   - `answer`
   - `citations[]`
   - `confidenceScore`
   - `safetyFlags[]`
   - `correlationId`

## Deployment boundaries
- Grounding source is `Policy__c` for scratch-org portability.
- Steering API connectivity uses the `SteeringAPI` Named Credential.
- Least-privilege runtime access is in `AgentforceRAGUser` permission set.
