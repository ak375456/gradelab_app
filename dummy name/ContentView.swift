import SwiftUI

struct ContentView: View {
    @StateObject private var coordinator = AppCoordinator()
    /// Shown once. Skipping and finishing set it alike — both mean the user is
    /// done with the flow.
    @AppStorage("onboarding.completed") private var onboardingCompleted = false

    var body: some View {
        ZStack {
            workspace
            if !onboardingCompleted {
                // Above the workspace rather than in place of it, so the app
                // behind has already loaded its projects by the time the last
                // page is dismissed.
                OnboardingView {
                    withAnimation(.easeInOut(duration: 0.28)) { onboardingCompleted = true }
                }
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }

    private var workspace: some View {
        ZStack {
            switch coordinator.screen {
            case .home:
                HomeView(coordinator: coordinator).transition(.opacity)
            case .analyzing:
                AnalyzingView(fileName: coordinator.analyzingFileName).transition(.opacity)
            case .source:
                if let project = coordinator.activeProject {
                    SourceInfoView(
                        project: project,
                        onBack: coordinator.showHome,
                        onEdit: coordinator.openEditor,
                        onSetColorMode: coordinator.setColorMode
                    )
                    .transition(.opacity)
                }
            case .editor:
                if let model = coordinator.editorModel {
                    EditorView(
                        model: model,
                        onBack: coordinator.closeEditor,
                        onShowSource: { coordinator.closeEditor(project: model.project) },
                        onSettingsChanged: coordinator.persistEditorSettings
                    )
                    .transition(.opacity)
                }
            case .imageEditor:
                if let model = coordinator.imageEditorModel {
                    ImageEditorView(
                        model: model,
                        onBack: coordinator.closeImageEditor,
                        onSettingsChanged: coordinator.persistImageProject
                    )
                    .transition(.opacity)
                }
            }
        }
        .alert(item: $coordinator.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}
