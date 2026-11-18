import PhotosUI
import SwiftUI
import UIKit

struct FeedbackView: View {
    private enum Category: String, CaseIterable {
        case issue, suggestion, other

        var title: LocalizedStringKey {
            switch self {
            case .issue: "Report a problem"
            case .suggestion: "Suggest a feature"
            case .other: "Other feedback"
            }
        }
    }

    private enum Area: String, CaseIterable {
        case general, importMedia, editing, camera, export, purchases

        var title: LocalizedStringKey {
            switch self {
            case .general: "General"
            case .importMedia: "Import"
            case .editing: "Editing"
            case .camera: "Camera"
            case .export: "Export"
            case .purchases: "Purchases"
            }
        }
    }

    @State private var category = Category.issue
    @State private var area = Area.general
    @State private var message = ""
    @State private var includeDiagnostics = true
    @State private var isSending = false
    @State private var receipt: FeedbackReceipt?
    @State private var hasChecked = false
    @State private var isChecking = false
    @State private var statusFailed = false
    @State private var photoItem: PhotosPickerItem?
    @State private var screenshot: Data?
    @State private var screenshotFailed = false
    @AppStorage(FeedbackReportStore.bannerDismissedKey) private var feedbackBannerDismissed = false
    @State private var isPreparingScreenshot = false
    @State private var sendFailed = false
    @FocusState private var messageFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var exceedsLimit: Bool { trimmedMessage.utf8.count > FeedbackSubmission.maximumMessageBytes }
    private var canSend: Bool { !trimmedMessage.isEmpty && !exceedsLimit && !isSending && !isPreparingScreenshot && photoItem == nil }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
    }

    private var osName: String {
        if AppPlatform.isMac { return "macOS" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : UIDevice.current.systemName
    }

    private var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private var deviceModel: String {
        #if targetEnvironment(simulator)
        let identifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]
        return identifier.map { "\($0) (Simulator)" } ?? "Simulator"
        #else
        var size = 0
        let key = AppPlatform.isMac ? "hw.model" : "hw.machine"
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else {
            return AppPlatform.isMac ? "Mac" : UIDevice.current.model
        }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &bytes, &size, nil, 0) == 0 else {
            return AppPlatform.isMac ? "Mac" : UIDevice.current.model
        }
        return String(cString: bytes)
        #endif
    }

    var body: some View {
        Group {
            if let receipt {
                receiptView(receipt)
            } else if !hasChecked || isChecking {
                ProgressView("Checking feedback…")
            } else if statusFailed {
                ContentUnavailableView {
                    Label("Couldn’t load feedback", systemImage: "exclamationmark.circle")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    AppButton("Try again") { Task { await refreshReceipt() } }
                }
            } else {
                form
            }
        }
        .navigationTitle("Feedback")
        .navigationBarTitleDisplayMode(.inline)
        .tint(AppColors.accent)
        .task { await refreshReceipt() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, receipt != nil {
                Task { await refreshReceipt() }
            }
        }
        .task(id: photoItem) {
            if let photoItem { await prepareScreenshot(photoItem) }
        }
    }

    private func receiptView(_ receipt: FeedbackReceipt) -> some View {
        Form {
            Section {
                Label("Feedback sent", systemImage: "checkmark.circle")
                    .foregroundStyle(AppColors.accent)
                Text(receipt.message)
                    .textSelection(.enabled)
            } header: {
                Text("Your feedback")
            } footer: {
                Text("If the developer replies, it will appear here. You can send another report if this one is deleted.")
            }

            if let developer = receipt.developer {
                Section("Developer reply") {
                    Text(developer)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button {
                    Task { await refreshReceipt() }
                } label: {
                    if isChecking {
                        ProgressView("Checking…")
                    } else {
                        Label("Check for a reply", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isChecking)

                if statusFailed {
                    Text("Couldn’t check for a new reply. Try again.")
                        .foregroundStyle(AppColors.destructive)
                        .font(.footnote)
                }
            }
        }
        .refreshable { await refreshReceipt() }
    }

    private var screenshotSection: some View {
        Section {
            if let screenshot, let image = UIImage(data: screenshot) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 180)
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("Selected screenshot")
                Button("Remove screenshot", role: .destructive) {
                    self.screenshot = nil
                }
            } else if isPreparingScreenshot || photoItem != nil {
                ProgressView("Preparing screenshot…")
            } else {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Add screenshot", systemImage: "photo.badge.plus")
                }
            }

            if screenshotFailed {
                Text("Couldn’t prepare this image. Try choosing a different screenshot.")
                    .font(.footnote)
                    .foregroundStyle(AppColors.destructive)
            }
        } header: {
            Text("Screenshot (optional)")
        } footer: {
            Text("Only the image you pick is attached. Check it for anything private before sending.")
        }
    }

    private func prepareScreenshot(_ item: PhotosPickerItem) async {
        isPreparingScreenshot = true
        screenshotFailed = false
        let data = try? await item.loadTransferable(type: Data.self)
        let prepared: Data?
        if let data, !Task.isCancelled {
            prepared = await Task.detached(priority: .userInitiated) {
                FeedbackScreenshot.compressedJPEG(from: data)
            }.value
        } else {
            prepared = nil
        }
        guard !Task.isCancelled else { return }
        screenshot = prepared
        screenshotFailed = prepared == nil
        photoItem = nil
        isPreparingScreenshot = false
    }

    private func refreshReceipt() async {
        guard !isChecking, !isSending else { return }
        isChecking = true
        statusFailed = false
        defer {
            isChecking = false
            hasChecked = true
        }
        if receipt == nil {
            receipt = try? await FeedbackService.localReceipt()
        }
        if receipt != nil { feedbackBannerDismissed = true }
        do {
            receipt = try await FeedbackService.receipt()
            if receipt != nil { feedbackBannerDismissed = true }
        } catch {
            if !Task.isCancelled { statusFailed = true }
        }
    }

    private var form: some View {
        Form {
            Section {
                Picker("Feedback type", selection: $category) {
                    ForEach(Category.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("App area", selection: $area) {
                    ForEach(Area.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } footer: {
                Text("GradeLab stores feedback under a random report ID. You can send it directly to the developer without a name, email address, or account. Keep personal information out of your message and screenshot to stay anonymous.")
            }

            Section("Message") {
                TextField(
                    "Feedback message",
                    text: $message,
                    prompt: Text(category == .issue ? "What did you try, and what happened?" : "What would you like us to know?"),
                    axis: .vertical
                )
                .lineLimit(5...10)
                .focused($messageFocused)

                if exceedsLimit {
                    Text("Please shorten your message before sending.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.destructive)
                }
            }

            screenshotSection

            Section {
                Toggle("Include app and device details", isOn: $includeDiagnostics)
                if includeDiagnostics {
                    LabeledContent("GradeLab", value: "\(appVersion) (\(buildNumber))")
                    LabeledContent("Operating system", value: "\(osName) \(osVersion)")
                    LabeledContent("Device model", value: deviceModel)
                }
            } footer: {
                Text("These optional details help the developer reproduce issues.")
            }

            Section {
                Button(action: send) {
                    Group {
                        if isSending {
                            ProgressView("Sending…")
                        } else {
                            Label("Send feedback", systemImage: "paperplane")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.appPrimary)
                .disabled(!canSend)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if sendFailed {
                    Text("Couldn’t send your feedback. Your message is still here. Please try again.")
                        .font(.footnote)
                        .foregroundStyle(AppColors.destructive)
                }
            } footer: {
                Text("You can have one report at a time. Check back here for a reply.")
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .disabled(isSending)
    }

    private func send() {
        guard canSend else { return }
        let diagnostics = includeDiagnostics ? [
            "appVersion": appVersion,
            "appBuild": buildNumber,
            "os": osName,
            "osVersion": osVersion,
            "deviceModel": deviceModel
        ] : nil
        let report = FeedbackSubmission(category: category.rawValue, area: area.rawValue,
                                        message: trimmedMessage, diagnostics: diagnostics, screenshot: screenshot)
        messageFocused = false
        sendFailed = false
        isSending = true

        Task {
            defer { isSending = false }
            do {
                receipt = try await FeedbackService.send(report)
                feedbackBannerDismissed = true
                message = ""
                screenshot = nil
            } catch {
                sendFailed = true
            }
        }
    }
}
