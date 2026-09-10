import Foundation

enum ForumMultipart {
    static func body(fields: [ForumFormValue], files: [ForumFormFile], boundary: String) -> Data {
        var data = Data()
        for field in fields {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(field.name))\"\r\n\r\n\(field.value)\r\n".utf8))
        }
        for upload in files {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(quoted(upload.fieldName))\"; filename=\"\(quoted(upload.file.name))\"\r\nContent-Type: \(headerValue(upload.mimeType))\r\n\r\n".utf8))
            data.append(upload.file.data)
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    private static func quoted(_ value: String) -> String {
        headerValue(value).replacingOccurrences(of: "\"", with: "%22")
    }

    private static func headerValue(_ value: String) -> String {
        value.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\0", with: "")
    }
}
