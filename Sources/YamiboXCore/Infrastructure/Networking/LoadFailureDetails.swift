import Foundation

/// A display-safe, transient snapshot. Never persist this alongside cached content.
public struct LoadFailureDetails: Hashable, Sendable {
    public struct Item: Hashable, Sendable {
        public let title: String
        public let details: LoadFailureDetails

        public init(title: String, details: LoadFailureDetails) {
            self.title = LoadFailureRedactor.redact(title)
            self.details = details
        }
    }

    public struct Cause: Hashable, Sendable {
        public let message: String
        public let type: String
        public let domain: String
        public let code: Int
        public let failureReason: String?
        public let recoverySuggestion: String?
    }

    public let summary: String
    public let causes: [Cause]
    public let requestContext: String?
    public let httpStatus: Int?
    public let isHTMLParsingFailure: Bool
    /// Whether the typed recovery error requires authentication, independent of diagnostic text.
    public private(set) var requiresAuthentication: Bool
    public let html: String?
    public let failures: [Item]

    public init(message: String, failures: [Item] = []) {
        summary = LoadFailureRedactor.redact(message)
        causes = []
        requestContext = nil
        httpStatus = nil
        isHTMLParsingFailure = false
        requiresAuthentication = false
        html = nil
        self.failures = failures
    }

    public init(error: any Error, requestContext: String? = nil, html: String? = nil) {
        let classificationError = LoadDiagnosticError.classificationError(error)
        let requiresAuthentication: Bool
        if let yamibo = classificationError as? YamiboError {
            switch yamibo {
            case .notAuthenticated, .loginVerificationRequired, .invalidResponse(statusCode: 401):
                requiresAuthentication = true
            default:
                requiresAuthentication = false
            }
        } else {
            requiresAuthentication = (classificationError as? URLError)?.code == .userAuthenticationRequired
        }
        if let diagnostic = error as? LoadDiagnosticError {
            self = diagnostic.details.adding(requestContext: requestContext, html: html)
            self.requiresAuthentication = requiresAuthentication
            return
        }
        self.requiresAuthentication = requiresAuthentication
        summary = LoadFailureRedactor.redact(error.localizedDescription)
        var causes: [Cause] = []
        var current: (any Error)? = error
        var visited: [NSError] = []
        var status: Int?
        var parsing = html != nil
        var failingURL: String?
        // NSError chains can contain cycles supplied by third-party libraries.
        while let source = current, causes.count < 12 {
            let nsError = source as NSError
            guard !visited.contains(where: { $0 === nsError }) else { break }
            visited.append(nsError)
            causes.append(Cause(
                message: LoadFailureRedactor.redact(source.localizedDescription),
                type: String(reflecting: Swift.type(of: source)),
                domain: LoadFailureRedactor.redact(nsError.domain),
                code: nsError.code,
                failureReason: nsError.localizedFailureReason.map(LoadFailureRedactor.redact),
                recoverySuggestion: nsError.localizedRecoverySuggestion.map(LoadFailureRedactor.redact)
            ))
            if let yamibo = source as? YamiboError {
                if case let .invalidResponse(code) = yamibo { status = code }
                if case .parsingFailed = yamibo { parsing = true }
            }
            if failingURL == nil {
                failingURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
                    ?? nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            }
            current = (source as? YamiboPersistenceError)?.underlying
                ?? nsError.userInfo[NSUnderlyingErrorKey] as? any Error
        }
        self.causes = causes
        self.requestContext = (requestContext ?? failingURL).map(LoadFailureRedactor.redact)
        httpStatus = status
        isHTMLParsingFailure = parsing
        self.html = html.map(LoadFailureRedactor.redact)
        failures = []
    }

    private init(
        summary: String, causes: [Cause], requestContext: String?,
        httpStatus: Int?, isHTMLParsingFailure: Bool, requiresAuthentication: Bool, html: String?, failures: [Item]
    ) {
        self.summary = summary
        self.causes = causes
        self.requestContext = requestContext
        self.httpStatus = httpStatus
        self.isHTMLParsingFailure = isHTMLParsingFailure
        self.requiresAuthentication = requiresAuthentication
        self.html = html
        self.failures = failures
    }

    public func adding(requestContext: String? = nil, httpStatus: Int? = nil, html: String? = nil) -> Self {
        Self(
            summary: summary,
            causes: causes,
            requestContext: self.requestContext ?? requestContext.map(LoadFailureRedactor.redact),
            httpStatus: self.httpStatus ?? httpStatus,
            isHTMLParsingFailure: isHTMLParsingFailure || html != nil,
            requiresAuthentication: requiresAuthentication,
            html: self.html ?? html.map(LoadFailureRedactor.redact),
            failures: failures
        )
    }

    /// The same sanitized text is used by the viewer and clipboard.
    public var diagnosticText: String {
        var sections = [summary]
        if let requestContext { sections.append("\(L10n.string("load_failure.context"))\n\(requestContext)") }
        if let httpStatus { sections.append("HTTP: \(httpStatus)") }
        if causes.isEmpty, failures.isEmpty { sections.append(L10n.string("load_failure.no_underlying_error")) }
        for (index, cause) in causes.enumerated() {
            var lines = [
                "\(L10n.string("load_failure.cause")) \(index + 1)",
                cause.message,
                "Type: \(cause.type)",
                "Domain: \(cause.domain)",
                "Code: \(cause.code)"
            ]
            if let reason = cause.failureReason { lines.append(reason) }
            if let suggestion = cause.recoverySuggestion { lines.append(suggestion) }
            sections.append(lines.joined(separator: "\n"))
        }
        if isHTMLParsingFailure, html == nil { sections.append(L10n.string("load_failure.html_unavailable")) }
        for failure in failures {
            sections.append("\(failure.title)\n\(failure.details.summary)")
        }
        return sections.joined(separator: "\n\n")
    }

    public var copyText: String {
        var text = diagnosticText
        if let html { text += "\n\n" + L10n.string("load_failure.html") + "\n" + html }
        for failure in failures { text += "\n\n\(failure.title)\n\(failure.details.copyText)" }
        return text
    }
}

/// Carries diagnostics without changing the error used for recovery decisions.
public struct LoadDiagnosticError: LocalizedError, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let underlying: any Error
    public let details: LoadFailureDetails
    private let recoveryError: any Error

    public init(underlying: any Error, details: LoadFailureDetails, recoveryError: (any Error)? = nil) {
        self.underlying = underlying
        self.details = details
        self.recoveryError = recoveryError ?? underlying
    }

    public var errorDescription: String? { recoveryError.localizedDescription }
    // Existing logs interpolate errors. Do not let them dump response HTML.
    public var description: String { details.summary }
    public var debugDescription: String { description }

    public static func classificationError(_ error: any Error) -> any Error {
        if let diagnostic = error as? Self { return classificationError(diagnostic.recoveryError) }
        return error
    }

    public static func isCancellation(_ error: any Error) -> Bool {
        let source = classificationError(error)
        return source is CancellationError || (source as? URLError)?.code == .cancelled
    }

    public static func attaching(
        to error: any Error, requestContext: String? = nil, httpStatus: Int? = nil, html: String? = nil
    ) -> any Error {
        guard !isCancellation(error) else { return error }
        return Self(
            underlying: error,
            details: LoadFailureDetails(error: error)
                .adding(requestContext: requestContext, httpStatus: httpStatus, html: html)
        )
    }

    public static func mapping(_ error: any Error, to recoveryError: any Error) -> any Error {
        guard !isCancellation(error) else { return error }
        return Self(underlying: error, details: LoadFailureDetails(error: error), recoveryError: recoveryError)
    }

    public static func parsing<Value>(html: String, context: String? = nil, _ parse: () throws -> Value) throws -> Value {
        do {
            return try parse()
        } catch {
            // Recognized server rejections are not HTML parse failures.
            if let source = classificationError(error) as? YamiboError {
                switch source {
                case .parsingFailed:
                    break
                default:
                    throw error
                }
            }
            throw attaching(to: error, requestContext: context, html: html)
        }
    }
}
