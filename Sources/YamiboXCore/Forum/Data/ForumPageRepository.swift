import Foundation

public actor ForumPageRepository {
    private let client: YamiboClient

    init(client: YamiboClient) {
        self.client = client
    }

    public func fetchPage(url: URL, confirmedAction: Bool = false) async throws -> ForumPageLoadResult {
        guard ForumWebPagePolicy.requiresForumHandling(url) else { throw ForumPageError.invalidURL }
        guard confirmedAction || !ForumWebPagePolicy.requiresConfirmationToLoad(url) else {
            throw ForumPageError.confirmationRequired
        }
        let response = try await client.fetchPageDocument(url: ForumWebPagePolicy.secureURL(url))
        return try classifyGET(response)
    }

    public func submit(
        form: ForumForm, values: [String: [String]], buttonID: String, referer: URL,
        files: [ForumFormFile] = [], attachments: [ForumUploadedAttachment] = []
    ) async throws -> ForumPageLoadResult {
        guard ForumWebPagePolicy.requiresForumHandling(referer),
              ForumWebPagePolicy.requiresForumHandling(form.actionURL) else { throw ForumPageError.invalidURL }
        var fields = try form.submissionValues(values: values, buttonID: buttonID)
        let fileFields = Set(form.fields.filter { $0.kind == .file }.map(\.name))
        guard files.allSatisfy({ fileFields.contains($0.fieldName) && $0.file.data.count <= 5 * 1024 * 1024 }) else {
            throw ForumPageError.invalidForm
        }
        for field in form.fields where field.kind == .file && field.isRequired {
            guard files.contains(where: { $0.fieldName == field.name }) else {
                throw ForumPageError.requiredField(field.label)
            }
        }
        fields += attachments.flatMap(\.values)
        let response: YamiboHTMLResponse
        if form.method == "GET" {
            guard var components = URLComponents(url: form.actionURL, resolvingAgainstBaseURL: true) else { throw ForumPageError.invalidForm }
            // A GET form replaces the action query, as a browser does. Discuz
            // forms carry routing parameters as hidden successful controls.
            components.queryItems = fields.map { URLQueryItem(name: $0.name, value: $0.value) }
            guard let url = components.url else { throw ForumPageError.invalidForm }
            response = try await client.fetchPageDocument(url: ForumWebPagePolicy.secureURL(url), referer: referer)
        } else {
            guard fields.contains(where: { $0.name == "formhash" && !$0.value.isEmpty }) ||
                    URLComponents(url: form.actionURL, resolvingAgainstBaseURL: true)?.queryItems?.contains(where: { $0.name == "formhash" && $0.value?.isEmpty == false }) == true else {
                throw ForumPageError.invalidForm
            }
            response = try await client.fetchPageDocument(url: form.actionURL, fields: fields, files: files, referer: referer)
        }
        if form.method == "GET" { return try classifyGET(response) }
        let page = try parse(response)
        let route = ForumRouteResolver.resolve(url: response.url)
        if (form.kind == .thread && { if case .thread = route { return true }; return false }()) ||
            (form.kind == .blog && { if case .blog = route { return true }; return false }()) {
            return .page(ForumPageDocument(url: response.url, title: page.title, message: L10n.string("forum.native.submitted"), continuationURL: response.url))
        }
        return .page(page)
    }

    private func classifyGET(_ response: YamiboHTMLResponse) throws -> ForumPageLoadResult {
        if ForumWebPagePolicy.isLoginPage(response.url) { throw YamiboError.notAuthenticated }
        if response.file == nil, response.continuationURL == nil {
            switch ForumRouteResolver.resolve(url: response.url) {
            case .web:
                return .webFallback(response.url)
            case .postEditor, .blogEditor, .actionForm:
                break
            default:
                return .nativeRedirect(response.url)
            }
        }
        let page = try parse(response)
        guard !page.forms.isEmpty || page.message != nil || page.file != nil || page.continuationURL != nil else {
            return .webFallback(response.url)
        }
        return .page(page)
    }

    public func upload(file: ForumAttachmentFile, mimeType: String, configuration: ForumUploadConfiguration, referer: URL) async throws -> ForumUploadedAttachment {
        guard ForumUploadParser.isUploadURL(configuration.url), ForumWebPagePolicy.requiresForumHandling(referer),
              configuration.values.contains(where: { $0.name == "hash" && !$0.value.isEmpty }),
              !file.data.isEmpty else { throw ForumPageError.invalidForm }
        guard file.data.count <= configuration.maximumBytes else { throw ForumPageError.fileTooLarge }
        let ext = URL(fileURLWithPath: file.name).pathExtension.lowercased()
        guard configuration.extensions.isEmpty || configuration.extensions.contains(ext) else { throw ForumPageError.unsupportedUpload }
        let response = try await client.fetchPageDocument(
            url: configuration.url, fields: configuration.values + [.init(name: "filetype", value: mimeType)],
            files: [.init(fieldName: "Filedata", file: file, mimeType: mimeType)], referer: referer
        )
        return try ForumUploadParser.attachment(from: response.html, configuration: configuration, name: file.name)
    }

    private func parse(_ response: YamiboHTMLResponse) throws -> ForumPageDocument {
        if ForumWebPagePolicy.isLoginPage(response.url) { throw YamiboError.notAuthenticated }
        if let continuationURL = response.continuationURL {
            return ForumPageDocument(url: response.url, title: L10n.string("forum.native.continue"), continuationURL: continuationURL)
        }
        if let file = response.file { return ForumPageDocument(url: response.url, title: file.name, file: file) }
        return try LoadDiagnosticError.parsing(html: response.html, context: "ForumFormPageParser.parse") {
            try ForumFormPageParser.parse(html: response.html, url: response.url)
        }
    }
}
