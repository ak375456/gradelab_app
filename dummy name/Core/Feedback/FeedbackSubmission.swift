import Foundation

struct FeedbackSubmission {
    static let maximumMessageBytes = 4_000
    static let maximumScreenshotBytes = 300_000

    let category: String
    let area: String
    let message: String
    let diagnostics: [String: String]?
    let screenshot: Data?
}

struct FeedbackReceipt {
    let message: String
    let developer: String?

    fileprivate init(message: String, developer: String? = nil) {
        self.message = message
        let reply = developer?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.developer = reply?.isEmpty == false ? reply : nil
    }
}

enum FeedbackService {
    private static let database = "projects/gradelab-feedback/databases/(default)"
    private static let documents = URL(string: "https://firestore.googleapis.com/v1/\(database)/documents")!

    static func localReceipt() async throws -> FeedbackReceipt? {
        let report = try await FeedbackReportStore.shared.report()
        return report?.submittedMessage.map { FeedbackReceipt(message: $0) }
    }

    static func receipt() async throws -> FeedbackReceipt? {
        guard let report = try await FeedbackReportStore.shared.report() else { return nil }
        let receipt = try await receipt(for: report)
        if receipt == nil, report.submittedMessage != nil {
            // A confirmed 404 releases a submitted report. Keep pending IDs for safe retries.
            try await FeedbackReportStore.shared.clearDeletedReport(report)
        }
        return receipt
    }

    static func send(_ feedback: FeedbackSubmission) async throws -> FeedbackReceipt {
        guard let report = try await FeedbackReportStore.shared.report(createIfNeeded: true) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if let message = report.submittedMessage { return FeedbackReceipt(message: message) }
        var fields: [String: Any] = [
            "category": ["stringValue": feedback.category],
            "area": ["stringValue": feedback.area],
            "message": ["stringValue": feedback.message],
            "developer": ["stringValue": ""]
        ]
        if let diagnostics = feedback.diagnostics {
            fields["diagnostics"] = ["mapValue": [
                "fields": diagnostics.mapValues { ["stringValue": $0] }
            ]]
        }
        if let screenshot = feedback.screenshot {
            fields["screenshot"] = ["bytesValue": screenshot.base64EncodedString()]
        }

        let write: [String: Any] = [
            "update": [
                "name": "\(database)/documents/feedback/\(report.id)",
                "fields": fields
            ],
            "updateTransforms": [
                ["fieldPath": "createdAt", "setToServerValue": "REQUEST_TIME"]
            ],
            "currentDocument": ["exists": false]
        ]
        let endpoint = URL(string: documents.absoluteString + ":commit")!
        var request = request(for: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["writes": [write]])

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                throw URLError(.badServerResponse)
            }
            try? await FeedbackReportStore.shared.markSubmitted(report, message: feedback.message)
            return FeedbackReceipt(message: feedback.message)
        } catch {
            // If a previous attempt already created this document, show that receipt.
            if let existing = try? await receipt(for: report) { return existing }
            throw error
        }
    }

    private static func receipt(for report: FeedbackReportStore.Report) async throws -> FeedbackReceipt? {
        let document = documents.appendingPathComponent("feedback").appendingPathComponent(report.id)
        var url = URLComponents(url: document, resolvingAgainstBaseURL: false)!
        url.queryItems = ["message", "developer"].map { URLQueryItem(name: "mask.fieldPaths", value: $0) }
        let (data, response) = try await URLSession.shared.data(for: request(for: url.url!))
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw URLError(.badServerResponse) }
        let fields = try JSONDecoder().decode(Document.self, from: data).fields
        let message = fields.message.stringValue
        if report.submittedMessage == nil {
            try? await FeedbackReportStore.shared.markSubmitted(report, message: message)
        }
        return FeedbackReceipt(message: message, developer: fields.developer?.stringValue)
    }

    private static func request(for url: URL) -> URLRequest {
        URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
    }

    private struct Document: Decodable {
        struct Fields: Decodable {
            struct TextField: Decodable { let stringValue: String }

            let message: TextField
            let developer: TextField?
        }

        let fields: Fields
    }
}
