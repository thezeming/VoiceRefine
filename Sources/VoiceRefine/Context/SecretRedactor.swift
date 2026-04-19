import Foundation

/// Best-effort scrub for high-signal credential patterns in free-text
/// captured from other apps (before-cursor text and selected text).
///
/// Applied unconditionally — even a local LLM shouldn't ingest secrets,
/// since today's Ollama could be swapped for tomorrow's cloud refiner
/// without the user realising the captured context just became
/// network-bound. The patterns are deliberately conservative: each
/// targets a token format that is very unlikely to appear in normal
/// English dictation, so false positives are rare. When in doubt, we
/// prefer to leave the text alone and let the stop-sequence / leak
/// detector catch downstream copy.
enum SecretRedactor {
    private struct Rule {
        let regex: NSRegularExpression
        let replacement: String
    }

    private static let rules: [Rule] = {
        var out: [Rule] = []
        func add(_ pattern: String, _ replacement: String, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            out.append(Rule(regex: regex, replacement: replacement))
        }

        // AWS access key IDs — fixed prefix + 16 alphanum.
        add(#"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|ANPA|ANVA|ASCA)[0-9A-Z]{16}\b"#, "[REDACTED_AWS_KEY]")

        // GitHub tokens: ghp_/ghu_/ghs_/gho_/ghr_ + 30+ chars.
        add(#"\bgh[pousr]_[A-Za-z0-9]{30,}\b"#, "[REDACTED_GITHUB_TOKEN]")

        // Anthropic API keys: `sk-ant-` prefix.
        add(#"\bsk-ant-[A-Za-z0-9_-]{20,}\b"#, "[REDACTED_ANTHROPIC_KEY]")

        // OpenAI / DeepSeek / generic "sk-" keys.
        add(#"\bsk-[A-Za-z0-9_-]{20,}\b"#, "[REDACTED_API_KEY]")

        // Slack tokens.
        add(#"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#, "[REDACTED_SLACK_TOKEN]")

        // Google API keys.
        add(#"\bAIza[0-9A-Za-z_-]{35}\b"#, "[REDACTED_GOOGLE_KEY]")

        // Bearer headers — at least 20 URL-safe chars after "Bearer ".
        add(#"Bearer\s+[A-Za-z0-9._~+/-]{20,}=*"#, "Bearer [REDACTED]", options: [.caseInsensitive])

        // Key/value-style credentials: `password: ...`, `api_key=...`, etc.
        // Preserves the label so the LLM still sees the surrounding
        // grammar; only the value is swapped.
        add(
            #"(?i)\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\s*[:=]\s*['\"]?[^\s'\"]{6,}"#,
            "$1=[REDACTED_CREDENTIAL]"
        )

        // PEM private key blocks.
        add(
            #"-----BEGIN (?:[A-Z ]+)PRIVATE KEY-----[\s\S]*?-----END (?:[A-Z ]+)PRIVATE KEY-----"#,
            "[REDACTED_PRIVATE_KEY]"
        )

        // JWTs (three base64url segments, dot-separated). The prefix
        // anchors us to the typical `{ "alg": ...` header encoding so we
        // don't false-match arbitrary dotted-base64 strings.
        add(
            #"\beyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
            "[REDACTED_JWT]"
        )

        return out
    }()

    /// Returns `input` with matched credential patterns replaced by
    /// `[REDACTED_*]` placeholders. Idempotent and safe on empty input.
    static func redact(_ input: String) -> String {
        guard !input.isEmpty else { return input }
        var s = input
        for rule in rules {
            let range = NSRange(location: 0, length: (s as NSString).length)
            s = rule.regex.stringByReplacingMatches(
                in: s,
                range: range,
                withTemplate: rule.replacement
            )
        }
        return s
    }
}
