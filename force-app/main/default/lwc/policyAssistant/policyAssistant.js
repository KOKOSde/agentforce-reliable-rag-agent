import { LightningElement } from 'lwc';
import invokeFromLwc from '@salesforce/apex/PolicyRAGAction.invokeFromLwc';

export default class PolicyAssistant extends LightningElement {
    queryText = '';
    sessionId = '';
    response;
    isLoading = false;
    errorMessage;

    get hasResponse() {
        return !!this.response;
    }

    get citations() {
        return this.response?.citations || [];
    }

    get hasCitations() {
        return this.citations.length > 0;
    }

    get safetyFlags() {
        return this.response?.safetyFlags || [];
    }

    get hasSafetyFlags() {
        return this.safetyFlags.length > 0;
    }

    get safetyFlagsLabel() {
        return this.safetyFlags.join(', ');
    }

    get confidencePercent() {
        const score = this.response?.confidenceScore || 0;
        return `${Math.round(score * 100)}%`;
    }

    handleQueryChange(event) {
        this.queryText = event.target.value;
    }

    handleSessionChange(event) {
        this.sessionId = event.target.value;
    }

    async handleAsk() {
        this.errorMessage = undefined;
        this.response = undefined;

        if (!this.queryText || !this.queryText.trim()) {
            this.errorMessage = 'Enter a policy question before submitting.';
            return;
        }

        this.isLoading = true;
        try {
            const serializedPayload = await invokeFromLwc({
                queryText: this.queryText.trim(),
                sessionId: this.sessionId?.trim()
            });
            this.response = JSON.parse(serializedPayload);
        } catch (error) {
            this.errorMessage = error?.body?.message || error?.message || 'Unable to get a policy answer.';
        } finally {
            this.isLoading = false;
        }
    }
}
