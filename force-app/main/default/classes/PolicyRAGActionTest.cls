@IsTest
private class PolicyRAGActionTest {
    private static final String REST_URI = '/services/apexrest/agentforce/policy-rag/v1';

    @IsTest
    static void testSuccessResponseIncludesCitationsAndConfidence() {
        insertPolicies();
        prepareRestRequest('What is the return policy?', 'session-success');
        Test.setMock(HttpCalloutMock.class, new SteeringAllowMock());

        Test.startTest();
        PolicyRAGAction.run();
        Test.stopTest();

        Map<String, Object> payload = parseRestResponse();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertNotEquals('', (String) payload.get('answer'));
        System.assertNotEquals('', (String) payload.get('correlationId'));
        Decimal confidence = Decimal.valueOf(String.valueOf(payload.get('confidenceScore')));
        System.assert(confidence > 0.70, 'Expected a high confidence score for grounded result.');

        List<Object> citations = (List<Object>) payload.get('citations');
        System.assert(citations.size() > 0, 'Expected grounded citations.');
        System.assert(((String) payload.get('answer')).contains('[1]'));
    }

    @IsTest
    static void testSteeringApiFailureAddsSafetyFlag() {
        insertPolicies();
        prepareRestRequest('What does billing policy say?', 'session-steering-failure');
        Test.setMock(HttpCalloutMock.class, new SteeringErrorMock());

        Test.startTest();
        PolicyRAGAction.run();
        Test.stopTest();

        Map<String, Object> payload = parseRestResponse();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(containsSafetyFlag(payload, 'STEERING_API_UNAVAILABLE'));
    }

    @IsTest
    static void testInvalidInputReturns400() {
        RestRequest request = new RestRequest();
        request.requestUri = REST_URI;
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf('{"queryText":"   ","sessionId":"bad-session"}');
        RestContext.request = request;
        RestContext.response = new RestResponse();

        Test.startTest();
        PolicyRAGAction.run();
        Test.stopTest();

        Map<String, Object> payload = parseRestResponse();
        System.assertEquals(400, RestContext.response.statusCode);
        System.assertEquals(0, ((List<Object>) payload.get('citations')).size());
        System.assert(containsSafetyFlag(payload, 'INVALID_INPUT'));
    }

    @IsTest
    static void testEmptyRetrievalReturnsGroundingWarning() {
        prepareRestRequest('Question with no matching policy', 'session-empty');
        Test.setMock(HttpCalloutMock.class, new SteeringAllowMock());

        Test.startTest();
        PolicyRAGAction.run();
        Test.stopTest();

        Map<String, Object> payload = parseRestResponse();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(0, ((List<Object>) payload.get('citations')).size());
        System.assert(containsSafetyFlag(payload, 'NO_GROUNDING_FOUND'));
        Decimal confidence = Decimal.valueOf(String.valueOf(payload.get('confidenceScore')));
        System.assert(confidence < 0.30, 'Expected lower confidence with no grounding.');
    }

    @IsTest
    static void testCitationFormatting() {
        insert new Policy__c(
            Name = 'Data Retention Policy',
            Policy_Text__c = 'We retain billing records for seven years and remove records beyond retention windows.',
            Source_URL__c = 'https://policies.example.com/data-retention',
            Is_Active__c = true
        );
        prepareRestRequest('How long do you retain billing data?', 'session-citation-format');
        Test.setMock(HttpCalloutMock.class, new SteeringAllowMock());

        Test.startTest();
        PolicyRAGAction.run();
        Test.stopTest();

        Map<String, Object> payload = parseRestResponse();
        List<Object> citations = (List<Object>) payload.get('citations');
        System.assertEquals(1, citations.size());

        Map<String, Object> citation = (Map<String, Object>) citations[0];
        String citationId = (String) citation.get('citationId');
        System.assert(citationId.startsWith('[') && citationId.endsWith(']'));
        System.assert(((String) citation.get('sourceUri')).startsWith('https://'));
        System.assert(((String) citation.get('excerpt')).length() <= 241);
    }

    @IsTest
    static void testAuraEnabledWrapperReturnsStructuredPayload() {
        insertPolicies();
        Test.setMock(HttpCalloutMock.class, new SteeringAllowMock());

        Test.startTest();
        String serialized = PolicyRAGAction.invokeFromLwc('Can a customer return unopened items?', 'session-lwc');
        Test.stopTest();

        Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(serialized);
        System.assertNotEquals(null, payload.get('answer'));
        System.assertNotEquals(null, payload.get('confidenceScore'));
        System.assertNotEquals(null, payload.get('safetyFlags'));
        System.assertNotEquals(null, payload.get('correlationId'));
    }

    @IsTest
    static void testSteeringBlocksResponseAndAddsFlags() {
        insertPolicies();
        prepareRestRequest('Can I return a product?', 'abcd');
        Test.setMock(HttpCalloutMock.class, new SteeringBlockedMock());

        Test.startTest();
        PolicyRAGAction.run();
        Test.stopTest();

        Map<String, Object> payload = parseRestResponse();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(containsSafetyFlag(payload, 'STEERING_BLOCKED'));
        System.assert(containsSafetyFlag(payload, 'STEERING_REVIEWED'));
        System.assertEquals(
            'I can’t answer this from approved policy sources. Please route this request to policy operations.',
            (String) payload.get('answer')
        );
        System.assertEquals('0.05', String.valueOf(payload.get('confidenceScore')));
    }

    @IsTest
    static void testSteeringBlankBodyUsesDefaultDecision() {
        insertPolicies();
        prepareRestRequest('What is the return policy?', 'session-blank-body');
        Test.setMock(HttpCalloutMock.class, new SteeringBlankBodyMock());

        Test.startTest();
        PolicyRAGAction.run();
        Test.stopTest();

        Map<String, Object> payload = parseRestResponse();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(!containsSafetyFlag(payload, 'STEERING_API_UNAVAILABLE'));
        Decimal confidence = Decimal.valueOf(String.valueOf(payload.get('confidenceScore')));
        System.assert(confidence > 0.80);
    }

    @IsTest
    static void testSteeringMalformedBodyHandledAsUnavailable() {
        insertPolicies();
        prepareRestRequest('What does billing policy say?', 'session-malformed');
        Test.setMock(HttpCalloutMock.class, new SteeringMalformedBodyMock());

        Test.startTest();
        PolicyRAGAction.run();
        Test.stopTest();

        Map<String, Object> payload = parseRestResponse();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(containsSafetyFlag(payload, 'STEERING_API_UNAVAILABLE'));
    }

    @IsTest
    static void testInvalidRequestShapesAndLongQuery() {
        RestRequest request = new RestRequest();
        request.requestUri = REST_URI;
        request.httpMethod = 'POST';
        request.requestBody = null;
        RestContext.request = request;
        RestContext.response = new RestResponse();
        PolicyRAGAction.run();
        System.assertEquals(400, RestContext.response.statusCode);

        request = new RestRequest();
        request.requestUri = REST_URI;
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf('[]');
        RestContext.request = request;
        RestContext.response = new RestResponse();
        PolicyRAGAction.run();
        System.assertEquals(400, RestContext.response.statusCode);

        request = new RestRequest();
        request.requestUri = REST_URI;
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf('not-json');
        RestContext.request = request;
        RestContext.response = new RestResponse();
        PolicyRAGAction.run();
        System.assertEquals(400, RestContext.response.statusCode);

        String longQuery = '';
        for (Integer index = 0; index < 2001; index++) {
            longQuery += 'x';
        }
        request = new RestRequest();
        request.requestUri = REST_URI;
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf('{"queryText":"' + longQuery + '","sessionId":"s1"}');
        RestContext.request = request;
        RestContext.response = new RestResponse();
        PolicyRAGAction.run();
        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void testCitationFallbackUriForMissingSourceUrl() {
        insert new Policy__c(
            Name = 'Cancellation Policy',
            Policy_Text__c = 'A customer can cancel without fee within 24 hours.',
            Is_Active__c = true
        );
        prepareRestRequest('What is cancellation policy?', 'abc');
        Test.setMock(HttpCalloutMock.class, new SteeringAllowMock());

        Test.startTest();
        PolicyRAGAction.run();
        Test.stopTest();

        Map<String, Object> payload = parseRestResponse();
        List<Object> citations = (List<Object>) payload.get('citations');
        Map<String, Object> citation = (Map<String, Object>) citations[0];
        System.assert(((String) citation.get('sourceUri')).startsWith('/lightning/r/Policy__c/'));
    }

    private static void insertPolicies() {
        List<Policy__c> policies = new List<Policy__c>{
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
            )
        };
        insert policies;
    }

    private static void prepareRestRequest(String queryText, String sessionId) {
        RestRequest request = new RestRequest();
        request.requestUri = REST_URI;
        request.httpMethod = 'POST';
        request.requestBody = Blob.valueOf(JSON.serialize(new Map<String, String>{
            'queryText' => queryText,
            'sessionId' => sessionId
        }));
        RestContext.request = request;
        RestContext.response = new RestResponse();
    }

    private static Map<String, Object> parseRestResponse() {
        System.assertNotEquals(null, RestContext.response.responseBody);
        return (Map<String, Object>) JSON.deserializeUntyped(RestContext.response.responseBody.toString());
    }

    private static Boolean containsSafetyFlag(Map<String, Object> payload, String flagToFind) {
        List<Object> flags = (List<Object>) payload.get('safetyFlags');
        for (Object rawFlag : flags) {
            if (String.valueOf(rawFlag) == flagToFind) {
                return true;
            }
        }
        return false;
    }

    private class SteeringAllowMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            System.assertEquals('POST', request.getMethod());
            System.assert(request.getEndpoint().startsWith('callout:SteeringAPI'));

            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('{"allowResponse":true,"safetyFlags":["STEERING_CHECKED"],"confidenceMultiplier":0.95}');
            return response;
        }
    }

    private class SteeringErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(503);
            response.setBody('{"error":"service unavailable"}');
            return response;
        }
    }

    private class SteeringBlockedMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('{"allowResponse":false,"safetyFlags":["STEERING_REVIEWED","STEERING_REVIEWED"],"confidenceMultiplier":0.9}');
            return response;
        }
    }

    private class SteeringBlankBodyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('');
            return response;
        }
    }

    private class SteeringMalformedBodyMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest request) {
            HttpResponse response = new HttpResponse();
            response.setStatusCode(200);
            response.setBody('[]');
            return response;
        }
    }
}
