import Foundation
import Security

actor FeedbackReportStore {
    static let shared = FeedbackReportStore()
    static let bannerDismissedKey = "home.feedbackBanner.dismissed"

    struct Report: Codable {
        let id: String
        var submittedMessage: String?
    }

    private static let keychainItem: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.gradelab.feedback",
        kSecAttrAccount as String: "report-id",
        kSecUseDataProtectionKeychain as String: true
    ]

    func report(createIfNeeded: Bool = false) throws -> Report? {
        var query = Self.keychainItem
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess {
            guard let data = result as? Data else { throw CocoaError(.fileReadCorruptFile) }
            return try JSONDecoder().decode(Report.self, from: data)
        }
        guard status == errSecItemNotFound else { throw CocoaError(.fileReadUnknown) }
        guard createIfNeeded else { return nil }

        // Firestore allows a direct lookup by this private, randomly generated ID.
        let report = Report(id: "report_" + UUID().uuidString.lowercased())
        var item = Self.keychainItem
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = try JSONEncoder().encode(report)
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus == errSecDuplicateItem {
            return try self.report()
        }
        guard addStatus == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        return report
    }

    func markSubmitted(_ report: Report, message: String) throws {
        guard try self.report()?.id == report.id else { return }
        var submitted = report
        submitted.submittedMessage = message
        let attributes = [kSecValueData as String: try JSONEncoder().encode(submitted)]
        let status = SecItemUpdate(Self.keychainItem as CFDictionary, attributes as CFDictionary)
        guard status == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
    }

    func clearDeletedReport(_ report: Report) throws {
        guard try self.report()?.id == report.id else { return }
        let status = SecItemDelete(Self.keychainItem as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
