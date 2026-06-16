import Foundation
import SwiftData

// MARK: - AIService

/// Central facade for all AI operations.
/// Uses the provider, config, and policy abstractions from Tasks 1–4.
actor AIService {
    let configProvider: any AIConfigProvider
    let providerResolver: any ProviderResolver
    let modelPolicy: any ModelPolicy
    let retryConfig: RetryPolicy
    let circuitBreaker: CircuitBreaker?
    let budget: BudgetTracker

    init(
        configProvider: any AIConfigProvider,
        providerResolver: any ProviderResolver,
        modelPolicy: any ModelPolicy,
        retryConfig: RetryPolicy = .standard,
        circuitBreaker: CircuitBreaker? = nil,
        budget: BudgetTracker = .shared
    ) {
        self.configProvider = configProvider
        self.providerResolver = providerResolver
        self.modelPolicy = modelPolicy
        self.retryConfig = retryConfig
        self.circuitBreaker = circuitBreaker
        self.budget = budget
    }

    // MARK: - Non-streaming

    func send(
        feature: String,
        messages: [AIMessage],
        tools: [AIToolDefinition]? = nil,
        responseFormat: AIRequest.AIResponseFormat? = nil,
        toolChoice: String? = nil,
        override: ModelOverride? = nil
    ) async throws -> AIResponse {
        // 1. Check circuit breaker
        if let cb = circuitBreaker {
            guard cb.allowRequest() else {
                throw ProviderError.requestFailed(statusCode: -1)
            }
        }

        // 2. Model selection via policy
        let budgetState = BudgetState.from(budget)
        let selection = modelPolicy.selectModel(
            for: feature,
            budget: budgetState,
            userTier: nil,
            override: override
        )

        // 3. Params from config (temperature, maxTokens) — SEMPRE
        let params = configProvider.requestParams(
            for: feature,
            model: selection.model,
            override: override
        )

        // 4. Provider resolved
        let preference: ProviderPreference = override?.providerID.map { .specific($0) } ?? .any
        let provider = try await providerResolver.resolve(
            for: feature,
            preference: preference,
            override: override
        )

        // 5. Build internal AIRequest (callers never see temperature/maxTokens directly)
        let request = AIRequest(
            model: selection.model,
            messages: messages,
            temperature: override?.temperature ?? params.temperature,
            maxTokens: override?.maxTokens ?? params.maxTokens,
            responseFormat: responseFormat,
            tools: tools,
            toolChoice: toolChoice
        )

        // 6. Send with retry + circuit breaker
        do {
            let response = try await retryConfig.execute {
                try await provider.send(request)
            }
            circuitBreaker?.recordSuccess()
            return response
        } catch {
            circuitBreaker?.recordFailure()
            throw error
        }
    }

    // MARK: - Streaming

    func sendStreaming(
        feature: String,
        messages: [AIMessage],
        tools: [AIToolDefinition]? = nil,
        toolChoice: String? = nil,
        override: ModelOverride? = nil
    ) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let budgetState = BudgetState.from(budget)
                    let selection = modelPolicy.selectModel(
                        for: feature, budget: budgetState,
                        userTier: nil, override: override
                    )

                    let params = configProvider.requestParams(
                        for: feature, model: selection.model, override: override
                    )

                    let preference: ProviderPreference = override?.providerID.map { .specific($0) } ?? .any
                    let provider = try await providerResolver.resolve(
                        for: feature, preference: preference, override: override
                    )

                    let request = AIRequest(
                        model: selection.model,
                        messages: messages,
                        temperature: override?.temperature ?? params.temperature,
                        maxTokens: override?.maxTokens ?? params.maxTokens,
                        tools: tools,
                        toolChoice: toolChoice
                    )

                    let stream = provider.sendStreaming(request)
                    for try await event in stream {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Embeddings

    func embed(text: String, model: String) async throws -> [Float] {
        let provider = try await providerResolver.resolve(
            for: "embeddings", preference: .any, override: nil
        )
        return try await provider.embed(text, model: model)
    }
}
