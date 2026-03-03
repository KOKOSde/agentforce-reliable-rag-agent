@RestResource(urlMapping='/agentforce/policy-rag/v1')
global with sharing class PolicyRAGAction {
    private static final Integer MAX_QUERY_LENGTH = 2000;
    private static final Integer RETRIEVAL_LIMIT = 5;
    private static final Integer MAX_EXCERPT_LENGTH = 240;
    private static final Integer STEERING_TIMEOUT_MS = 4000;
    private static final Decimal BASE_CONFIDENCE_WITH_CITATIONS = 0.82;
    private static final Decimal BASE_CONFIDENCE_WITHOUT_CITATIONS = 0.24;
    private static final String STEERING_ENDPOINT = 'callout:SteeringAPI/v1/steer';

    @TestVisible
    private static PolicyRetriever retriever = new SOQLPolicyRetriever();
    @TestVisible
    private static SteeringGateway steeringGateway = new SteeringHttpGateway();

    global class PolicyRAGException extends Exception {}

    global class RequestPayload {
        public String queryText;
        public String sessionId;
    }

    global class Citation {
        public String citationId;
        public String title;
        public String sourceUri;
        public String excerpt;
    }

    global class ResponsePayload {
        public String answer;
        public List<Citation> citations;
        public Decimal confidenceScore;
        public List<String> safetyFlags;
        public String correlationId;
    }

    global class RetrievedPolicy {
        public Id recordId;
        public String title;
        public String sourceUri;
        public String bodyText;
    }

    global class SteeringDecision {
        public Boolean allowResponse;
        public List<String> safetyFlags;
        public Decimal confidenceMultiplier;
    }

    global interface PolicyRetriever {
        List<RetrievedPolicy> retrieve(String queryText, Integer maxRows);
    }

    global interface SteeringGateway {
        SteeringDecision evaluate(String queryText, String candidateAnswer, List<Citation> citations, String correlationId);
    }

    global class SOQLPolicyRetriever implements PolicyRetriever {
        global List<RetrievedPolicy> retrieve(String queryText, Integer maxRows) {
            Integer safeLimit = Math.max(1, Math.min(maxRows, 10));
            String searchPhrase = '%' + queryText.trim() + '%';

            List<Policy__c> matchedPolicies = [
                SELECT Id, Name, Policy_Text__c, Source_URL__c, Is_Active__c
                FROM Policy__c
                WHERE Is_Active__c = true
                AND Name LIKE :searchPhrase
                ORDER BY LastModifiedDate DESC
                LIMIT :safeLimit
            ];

            if (matchedPolicies.isEmpty()) {
                matchedPolicies = [
                    SELECT Id, Name, Policy_Text__c, Source_URL__c, Is_Active__c
                    FROM Policy__c
                    WHERE Is_Active__c = true
                    ORDER BY LastModifiedDate DESC
                    LIMIT :safeLimit
                ];
            }

            List<RetrievedPolicy> records = new List<RetrievedPolicy>();
            for (Policy__c policyRecord : matchedPolicies) {
                RetrievedPolicy dto = new RetrievedPolicy();
                dto.recordId = policyRecord.Id;
                dto.title = policyRecord.Name;
                dto.sourceUri = policyRecord.Source_URL__c;
                dto.bodyText = policyRecord.Policy_Text__c;
                records.add(dto);
            }
            return records;
        }
    }

    global class SteeringHttpGateway implements SteeringGateway {
        global SteeringDecision evaluate(String queryText, String candidateAnswer, List<Citation> citations, String correlationId) {
            if (Limits.getCallouts() >= Limits.getLimitCallouts()) {
                throw new PolicyRAGException('Callout limit reached before steering validation.');
            }

            HttpRequest request = new HttpRequest();
            request.setEndpoint(STEERING_ENDPOINT);
            request.setMethod('POST');
            request.setHeader('Content-Type', 'application/json');
            request.setTimeout(STEERING_TIMEOUT_MS);
            request.setBody(JSON.serialize(buildSteeringPayload(queryText, candidateAnswer, citations, correlationId)));

            HttpResponse response = (new Http()).send(request);
            if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
                throw new PolicyRAGException('Steering API returned status code ' + response.getStatusCode() + '.');
            }
            if (String.isBlank(response.getBody())) {
                return defaultSteeringDecision();
            }

            Object parsed = JSON.deserializeUntyped(response.getBody());
            Map<String, Object> responseMap;
            try {
                responseMap = (Map<String, Object>) parsed;
            } catch (Exception typeError) {
                throw new PolicyRAGException('Steering API response must be a JSON object.');
            }
            SteeringDecision decision = new SteeringDecision();
            decision.allowResponse = responseMap.containsKey('allowResponse')
                ? asBoolean(responseMap.get('allowResponse'))
                : true;
            decision.safetyFlags = parseSafetyFlags(responseMap.get('safetyFlags'));
            decision.confidenceMultiplier = parseConfidenceMultiplier(responseMap.get('confidenceMultiplier'));
            return decision;
        }
    }

    @HttpPost
    global static void run() {
        RestResponse restResponse = RestContext.response;
        if (restResponse == null) {
            restResponse = new RestResponse();
            RestContext.response = restResponse;
        }
        restResponse.addHeader('Content-Type', 'application/json');

        String correlationId = generateCorrelationId('rest');
        try {
            RequestPayload requestPayload = parseRequest(RestContext.request);
            correlationId = generateCorrelationId(requestPayload.sessionId);
            ResponsePayload responsePayload = execute(requestPayload.queryText, requestPayload.sessionId, correlationId);
            restResponse.statusCode = 200;
            restResponse.responseBody = Blob.valueOf(JSON.serialize(responsePayload));
        } catch (PolicyRAGException ex) {
            restResponse.statusCode = 400;
            restResponse.responseBody = Blob.valueOf(JSON.serialize(errorResponse(
                ex.getMessage(),
                new List<String>{ 'INVALID_INPUT' },
                correlationId
            )));
        } catch (Exception ex) {
            restResponse.statusCode = 500;
            restResponse.responseBody = Blob.valueOf(JSON.serialize(errorResponse(
                'Unexpected error while processing policy request.',
                new List<String>{ 'INTERNAL_ERROR' },
                correlationId
            )));
        }
    }

    @AuraEnabled
    public static String invokeFromLwc(String queryText, String sessionId) {
        String correlationId = generateCorrelationId(sessionId);
        ResponsePayload responsePayload = execute(queryText, sessionId, correlationId);
        return JSON.serialize(responsePayload);
    }

    @TestVisible
    private static ResponsePayload execute(String queryText, String sessionId, String correlationId) {
        validateQuery(queryText);
        String effectiveSessionId = String.isBlank(sessionId) ? 'anonymous' : sessionId.trim();
        List<RetrievedPolicy> groundedPolicies = retriever.retrieve(queryText, RETRIEVAL_LIMIT);

        List<Citation> citations = buildCitations(groundedPolicies);
        List<String> safetyFlags = new List<String>();
        String answer;
        Decimal confidenceScore;

        if (citations.isEmpty()) {
            answer = refusalMessage();
            confidenceScore = BASE_CONFIDENCE_WITHOUT_CITATIONS;
            addSafetyFlag(safetyFlags, 'NO_GROUNDING_FOUND');
        } else {
            answer = composeGroundedAnswer(groundedPolicies, citations);
            confidenceScore = BASE_CONFIDENCE_WITH_CITATIONS;

            try {
                SteeringDecision decision = steeringGateway.evaluate(queryText, answer, citations, correlationId);
                if (decision != null) {
                    if (decision.safetyFlags != null) {
                        for (String safetyFlag : decision.safetyFlags) {
                            addSafetyFlag(safetyFlags, safetyFlag);
                        }
                    }
                    if (decision.allowResponse == false) {
                        answer = refusalMessage();
                        addSafetyFlag(safetyFlags, 'STEERING_BLOCKED');
                        confidenceScore = 0.05;
                    } else {
                        confidenceScore = confidenceScore * decision.confidenceMultiplier;
                    }
                }
            } catch (Exception ignoredForAvailability) {
                addSafetyFlag(safetyFlags, 'STEERING_API_UNAVAILABLE');
                confidenceScore = confidenceScore * 0.70;
            }
        }

        ResponsePayload responsePayload = new ResponsePayload();
        responsePayload.answer = answer;
        responsePayload.citations = citations;
        responsePayload.confidenceScore = clampConfidence(confidenceScore);
        responsePayload.safetyFlags = safetyFlags;
        responsePayload.correlationId = correlationId;

        logOutcome(responsePayload, effectiveSessionId);
        return responsePayload;
    }

    private static RequestPayload parseRequest(RestRequest restRequest) {
        if (restRequest == null || restRequest.requestBody == null) {
            throw new PolicyRAGException('Request body is required.');
        }

        try {
            Object raw = JSON.deserializeUntyped(restRequest.requestBody.toString());
            Map<String, Object> payloadMap;
            try {
                payloadMap = (Map<String, Object>) raw;
            } catch (Exception typeError) {
                throw new PolicyRAGException('Request body must be a JSON object.');
            }
            RequestPayload payload = new RequestPayload();
            Object queryValue = payloadMap.get('queryText');
            payload.queryText = queryValue == null ? null : String.valueOf(queryValue);
            Object sessionValue = payloadMap.get('sessionId');
            payload.sessionId = sessionValue == null ? null : String.valueOf(sessionValue);
            validateQuery(payload.queryText);
            return payload;
        } catch (JSONException jsonError) {
            throw new PolicyRAGException('Request body is not valid JSON.');
        }
    }

    private static void validateQuery(String queryText) {
        if (String.isBlank(queryText)) {
            throw new PolicyRAGException('queryText is required.');
        }
        if (queryText.length() > MAX_QUERY_LENGTH) {
            throw new PolicyRAGException('queryText exceeds max length of ' + MAX_QUERY_LENGTH + ' characters.');
        }
    }

    private static String composeGroundedAnswer(List<RetrievedPolicy> groundedPolicies, List<Citation> citations) {
        List<String> fragments = new List<String>();
        Integer maxFacts = Math.min(groundedPolicies.size(), 2);
        for (Integer index = 0; index < maxFacts; index++) {
            RetrievedPolicy source = groundedPolicies[index];
            String citationId = citations[index].citationId;
            String summary = summarize(source.bodyText);
            fragments.add(summary + ' ' + citationId);
        }
        return String.join(fragments, ' ');
    }

    private static String summarize(String bodyText) {
        if (String.isBlank(bodyText)) {
            return 'No policy text was available from the source record.';
        }
        String normalized = bodyText.replace('\n', ' ').trim();
        Integer maxLength = 280;
        if (normalized.length() <= maxLength) {
            return normalized;
        }
        return normalized.substring(0, maxLength) + '…';
    }

    private static List<Citation> buildCitations(List<RetrievedPolicy> groundedPolicies) {
        List<Citation> citations = new List<Citation>();
        for (Integer index = 0; index < groundedPolicies.size(); index++) {
            RetrievedPolicy groundedPolicy = groundedPolicies[index];
            Citation citation = new Citation();
            citation.citationId = '[' + String.valueOf(index + 1) + ']';
            citation.title = groundedPolicy.title;
            citation.sourceUri = String.isBlank(groundedPolicy.sourceUri)
                ? '/lightning/r/Policy__c/' + groundedPolicy.recordId + '/view'
                : groundedPolicy.sourceUri;
            citation.excerpt = summarizeExcerpt(groundedPolicy.bodyText);
            citations.add(citation);
        }
        return citations;
    }

    private static String summarizeExcerpt(String sourceText) {
        if (String.isBlank(sourceText)) {
            return 'No excerpt available.';
        }
        String compacted = sourceText.replace('\n', ' ').trim();
        if (compacted.length() <= MAX_EXCERPT_LENGTH) {
            return compacted;
        }
        return compacted.substring(0, MAX_EXCERPT_LENGTH) + '…';
    }

    private static Map<String, Object> buildSteeringPayload(
        String queryText,
        String candidateAnswer,
        List<Citation> citations,
        String correlationId
    ) {
        List<Object> citationPayload = new List<Object>();
        for (Citation citation : citations) {
            citationPayload.add(new Map<String, Object>{
                'citationId' => citation.citationId,
                'title' => citation.title,
                'sourceUri' => citation.sourceUri
            });
        }
        return new Map<String, Object>{
            'queryText' => queryText,
            'candidateAnswer' => candidateAnswer,
            'citations' => citationPayload,
            'correlationId' => correlationId
        };
    }

    private static SteeringDecision defaultSteeringDecision() {
        SteeringDecision decision = new SteeringDecision();
        decision.allowResponse = true;
        decision.safetyFlags = new List<String>();
        decision.confidenceMultiplier = 1;
        return decision;
    }

    private static Boolean asBoolean(Object value) {
        if (value == null) {
            return false;
        }
        if (value instanceof Boolean) {
            return (Boolean) value;
        }
        String normalized = String.valueOf(value).trim().toLowerCase();
        return normalized == 'true' || normalized == '1' || normalized == 'yes';
    }

    private static Decimal parseConfidenceMultiplier(Object value) {
        Decimal parsed = 1;
        if (value != null) {
            parsed = Decimal.valueOf(String.valueOf(value));
        }
        if (parsed < 0) {
            return 0;
        }
        if (parsed > 1.2) {
            return 1.2;
        }
        return parsed;
    }

    private static List<String> parseSafetyFlags(Object rawFlags) {
        List<String> parsedFlags = new List<String>();
        if (rawFlags == null) {
            return parsedFlags;
        }
        List<Object> rawFlagList;
        try {
            rawFlagList = (List<Object>) rawFlags;
        } catch (Exception typeError) {
            return parsedFlags;
        }

        for (Object rawFlag : rawFlagList) {
            if (rawFlag == null) {
                continue;
            }
            String normalized = String.valueOf(rawFlag).trim();
            if (!String.isBlank(normalized)) {
                addSafetyFlag(parsedFlags, normalized);
            }
        }
        return parsedFlags;
    }

    private static Decimal clampConfidence(Decimal confidenceScore) {
        Decimal normalized = confidenceScore == null ? 0 : confidenceScore;
        if (normalized < 0) {
            normalized = 0;
        } else if (normalized > 1) {
            normalized = 1;
        }
        return normalized.setScale(2, RoundingMode.HALF_UP);
    }

    private static void addSafetyFlag(List<String> safetyFlags, String safetyFlag) {
        if (String.isBlank(safetyFlag) || safetyFlags.contains(safetyFlag)) {
            return;
        }
        safetyFlags.add(safetyFlag);
    }

    private static String refusalMessage() {
        return 'I can’t answer this from approved policy sources. Please route this request to policy operations.';
    }

    private static String generateCorrelationId(String sessionId) {
        String seed = String.valueOf(Crypto.getRandomLong()) + ':' + Datetime.now().getTime();
        if (!String.isBlank(sessionId)) {
            seed += ':' + sessionId.trim();
        }
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(seed))).substring(0, 16).toUpperCase();
    }

    private static ResponsePayload errorResponse(String message, List<String> safetyFlags, String correlationId) {
        ResponsePayload response = new ResponsePayload();
        response.answer = message;
        response.citations = new List<Citation>();
        response.confidenceScore = 0;
        response.safetyFlags = safetyFlags;
        response.correlationId = correlationId;
        return response;
    }

    private static void logOutcome(ResponsePayload responsePayload, String sessionId) {
        System.debug(LoggingLevel.INFO,
            'PolicyRAGAction correlationId=' + responsePayload.correlationId
            + ', sessionId=' + redactSessionId(sessionId)
            + ', citations=' + responsePayload.citations.size()
            + ', safetyFlags=' + String.join(responsePayload.safetyFlags, '|')
        );
    }

    private static String redactSessionId(String sessionId) {
        if (String.isBlank(sessionId)) {
            return 'anonymous';
        }
        String compacted = sessionId.trim();
        if (compacted.length() <= 4) {
            return '***';
        }
        return '***' + compacted.right(4);
    }
}
