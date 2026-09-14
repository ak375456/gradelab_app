import Combine
import Foundation
import UIKit

/// Drives one still-image export.
///
/// Deliberately small next to `ExportViewModel`: an image has no frame rate, no
/// duration, no bitrate, no audio and no codec capability matrix, so there is
/// nothing here to negotiate. The size is the source's, always.
@MainActor
final class ImageExportViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case exporting(Double)
        case completed
        case failed(String)
    }

    let project: ImageProject
    @Published var configuration: ImageExportConfiguration
    @Published private(set) var state: State = .idle
    @Published private(set) var output: ImageExporter.Output?
    @Published private(set) var isSaving = false
    @Published private(set) var savedToPhotos = false
    @Published var message: String?
    @Published var showsShareSheet = false

    private var task: Task<Void, Never>?

    init(project: ImageProject) {
        self.project = project
        configuration = .default(for: project.metadata)
    }

    deinit {
        task?.cancel()
        // The temporary file is removed when the sheet closes rather than here:
        // `deinit` is not main-actor isolated and must not touch the published
        // state. `discardOutput()` is called on the way out.
    }

    var isBusy: Bool { if case .exporting = state { return true }; return false }

    /// The output's dimensions, which are the source's. Shown before the export
    /// runs so there is no doubt about what is being written.
    var outputSizeLabel: String { project.metadata.resolutionLabel }

    /// What writing this still would need from Pro. Full-resolution JPEG of a
    /// free grade is free; HEIC, PNG and the Pro grading tools are not.
    var proRequirements: [ProFeature] {
        ProAccessPolicy.imageExportRequirements(project, configuration: configuration)
    }

    var proRequirement: ProFeature? { proRequirements.first }

    var isLocked: Bool { proRequirement != nil && !ProStore.shared.hasPro }

    func startExport() {
        // The view opens the paywall before reaching this; repeated here as the
        // last check before a file is written.
        guard !isBusy, !isLocked else { return }
        if let existing = output?.url { try? FileManager.default.removeItem(at: existing) }
        output = nil
        savedToPhotos = false
        state = .exporting(0)
        let project = self.project
        let configuration = self.configuration
        task = Task { [weak self] in
            do {
                let result = try await Task.detached(priority: .userInitiated) { () -> ImageExporter.Output in
                    let exporter = try ImageExporter()
                    return try exporter.export(project: project, configuration: configuration) { fraction in
                        Task { @MainActor in
                            guard let model = self, model.isBusy else { return }
                            model.state = .exporting(min(max(fraction, 0), 1))
                        }
                    }
                }.value
                guard !Task.isCancelled, let model = self else { return }
                model.output = result
                model.state = .completed
            } catch is CancellationError {
                self?.state = .idle
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                self?.state = .failed(message)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    func resetAfterFailure() { state = .idle }

    func saveToPhotos() {
        guard let url = output?.url, !isSaving else { return }
        isSaving = true
        Task { [weak self] in
            do {
                try await PhotoLibrarySaveService().saveImage(at: url)
                self?.savedToPhotos = true
                self?.message = "Saved to Photos."
            } catch {
                self?.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self?.isSaving = false
        }
    }

    func discardOutput() {
        if let url = output?.url { try? FileManager.default.removeItem(at: url) }
        output = nil
    }
}
