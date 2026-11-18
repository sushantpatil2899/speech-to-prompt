import DictateCore
import Foundation

/// The outcome of one rewrite request.
public struct RewriteResult: Sendable {
    /// The model's text, exactly as returned.
    public var modelOutput: String
    /// What the guardrails decided.
    public var verdict: RewriteGuard.Verdict
    public var milliseconds: Double
    public var promptTokens: Int?
    public var outputTokens: Int?
    /// Time Ollama spent loading the model for this request (non-zero after a cold start).
    public var loadMilliseconds: Double?
}

public enum RewriterStatus: Equatable, Sendable {
    case ready
    case disabled
    case notRunning
    case modelMissing(String)
    case misconfigured(String)

    public var summary: String {
        switch self {
        case .ready: return "ready"
        case .disabled: return "off (llm.enabled = false)"
        case .notRunning: return "Ollama not running (brew services start ollama)"
        case .modelMissing(let m): return "model not installed (ollama pull \(m))"
        case .misconfigured(let s): return s
        }
    }
}

public enum RewriterError: Error, CustomStringConvertible {
    case refused(String)
    case notRunning
    case modelMissing(String)
    case timeout(Double)
    case server(Int, String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .refused(let s): return s
        case .notRunning: return "Ollama is not running"
        case .modelMissing(let m): return "model \(m) is not installed (ollama pull \(m))"
        case .timeout(let s): return String(format: "no answer within %.1f s", s)
        case .server(let code, let msg): return "Ollama error \(code): \(msg)"
        case .badResponse(let s): return "unexpected response: \(s)"
        }
    }
}

/// Rewrites transcripts with a local LLM.
public protocol Rewriter: AnyObject {
    var name: String { get }
    func status() async -> RewriterStatus
    /// Loads the model (and keeps it loaded) and primes the prompt cache.
    func warmUp() async throws
    func rewrite(_ transcript: String) async throws -> RewriteResult
}

/// Ollama's /api/chat on this Mac. The model is kept in memory (`keep_alive: -1`).
public final class OllamaRewriter: Rewriter {
    public let config: LLMConfig
    public var guardrails = RewriteGuard()
    private let session: URLSession
    private var sendThinkFlag: Bool

    public init(config: LLMConfig) {
        self.config = config
        self.sendThinkFlag = config.disableThinking
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]  // straight to localhost, never via a proxy
        c.waitsForConnectivity = false
        c.urlCache = nil
        session = URLSession(configuration: c)
    }

    public var name: String { "ollama/\(config.model)" }

    private func checkAllowed() throws {
        if !config.isLocal { throw RewriterError.refused("llm.baseURL must be on this Mac; refusing \(config.baseURL)") }
        if config.isCloudModel { throw RewriterError.refused("refusing Ollama cloud model \(config.model) (would send text off this Mac)") }
    }

    private func url(_ path: String) throws -> URL {
        guard let u = URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw RewriterError.refused("bad llm.baseURL \(config.baseURL)")
        }
        return u
    }

    public func status() async -> RewriterStatus {
        guard config.enabled else { return .disabled }
        do { try checkAllowed() } catch { return .misconfigured(String(describing: error)) }
        do {
            var request = URLRequest(url: try url("/api/tags"))
            request.timeoutInterval = 2
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]]
            else { return .notRunning }
            let names = Set(models.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) })
            let wanted = config.model.contains(":") ? config.model : config.model + ":latest"
            return names.contains(wanted) || names.contains(config.model) ? .ready : .modelMissing(config.model)
        } catch {
            return .notRunning
        }
    }

    public func warmUp() async throws {
        // A cold load can take several seconds, so allow much longer than a normal request.
        _ = try await send(transcript: "okay so this is just a quick warm up, nothing else", timeout: 120)
    }

    public func rewrite(_ transcript: String) async throws -> RewriteResult {
        try await send(transcript: transcript, timeout: config.timeoutSeconds)
    }

    private func send(transcript: String, timeout: Double, retried: Bool = false) async throws -> RewriteResult {
        try checkAllowed()
        var body: [String: Any] = [
            "model": config.model,
            "messages": RewritePrompt.messages(for: transcript).map { ["role": $0.role, "content": $0.content] },
            "stream": false,
            "keep_alive": -1,
            "options": [
                "temperature": config.temperature,
                "num_predict": RewritePrompt.maxOutputTokens(for: transcript),
                "num_ctx": config.contextTokens,
            ],
        ]
        if sendThinkFlag { body["think"] = false }

        var request = URLRequest(url: try url("/api/chat"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw RewriterError.timeout(timeout)
            case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                throw RewriterError.notRunning
            default: throw error
            }
        }
        let ms = Date().timeIntervalSince(start) * 1000

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if code != 200 {
            let message = (json?["error"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            if message.lowercased().contains("does not support thinking"), sendThinkFlag, !retried {
                sendThinkFlag = false  // non-reasoning model: just don't send the flag
                return try await send(transcript: transcript, timeout: timeout, retried: true)
            }
            if code == 404 { throw RewriterError.modelMissing(config.model) }
            throw RewriterError.server(code, message)
        }
        guard let message = json?["message"] as? [String: Any], let content = message["content"] as? String else {
            throw RewriterError.badResponse(String(decoding: data.prefix(300), as: UTF8.self))
        }
        return RewriteResult(
            modelOutput: content,
            verdict: guardrails.check(raw: transcript, output: content),
            milliseconds: ms,
            promptTokens: json?["prompt_eval_count"] as? Int,
            outputTokens: json?["eval_count"] as? Int,
            loadMilliseconds: (json?["load_duration"] as? Double).map { $0 / 1_000_000 }
                ?? (json?["load_duration"] as? Int).map { Double($0) / 1_000_000 })
    }
}
