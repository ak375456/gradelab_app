import SwiftUI
import UIKit

extension TimelineMarkerColor {
    var title: String {
        switch self {
        case .yellow: String(localized: "Yellow")
        case .red: String(localized: "Red")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        }
    }

    /// Both the UIKit ruler and SwiftUI controls use this palette.
    var uiColor: UIColor {
        switch self {
        case .yellow: .systemYellow
        case .red: .systemRed
        case .green: .systemGreen
        case .blue: .systemBlue
        case .purple: .systemPurple
        }
    }

    var tint: Color { Color(uiColor: uiColor) }
}

extension TimelineMarker {
    var displayTitle: String { label.isEmpty ? String(localized: "Marker") : label }
    func timeLabel(in project: VideoProject) -> String {
        TimecodeFormatter.frameString(from: time.seconds,
                                      frameRate: project.canvas.frameRate ?? project.metadata.bestFrameRate)
    }
}

/// Reads the live marker by identity so color choices immediately update the
/// ruler, and a removed marker cannot leave stale controls behind.
struct MarkerEditor: View {
    @ObservedObject var model: EditorViewModel
    let markerID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var marker: TimelineMarker? {
        model.project.timeline.markers.first { $0.id == markerID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Edit marker").font(AppTypography.headline)
                Spacer(minLength: AppSpacing.small)
                Button("Done") { dismiss() }
                    .font(AppTypography.bodyEmphasized)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .padding(.horizontal, AppSpacing.standard)

            ScrollView {
                if let marker {
                    VStack(alignment: .leading, spacing: AppSpacing.standard) {
                        HStack(spacing: AppSpacing.compact) {
                            Image(systemName: "bookmark.fill")
                                .font(.title3).foregroundStyle(marker.color.tint)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                                Text(marker.displayTitle).font(AppTypography.bodyEmphasized)
                                Text(marker.timeLabel(in: model.project)).font(AppTypography.metadataValue)
                                    .foregroundStyle(AppColors.textSecondary)
                            }
                        }
                        .accessibilityElement(children: .combine)

                        VStack(alignment: .leading, spacing: AppSpacing.small) {
                            Text("Color").font(AppTypography.sectionLabel)
                                .foregroundStyle(AppColors.textSecondary)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4),
                                                     count: dynamicTypeSize.isAccessibilitySize ? 2 : 5), spacing: 8) {
                                ForEach(TimelineMarkerColor.allCases, id: \.self) { color in
                                    colorButton(color, selected: marker.color == color)
                                }
                            }
                        }

                        Button {
                            model.seekTimeline(to: marker.time.seconds, finishing: true)
                            dismiss()
                        } label: {
                            Label("Go to marker", systemImage: "arrow.right.to.line")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.appSecondary)

                        Button(role: .destructive) {
                            model.deleteMarker(markerID)
                            dismiss()
                        } label: {
                            Label("Remove marker", systemImage: "trash")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                    }
                    .padding(AppSpacing.standard)
                    .disabled(model.isPreparingTimeline)
                }
            }
        }
        .frame(idealWidth: 340, idealHeight: 400)
        .background(AppColors.surface)
        .preferredColorScheme(.dark)
        .presentationDetents([.height(400), .large])
        .presentationDragIndicator(.visible)
        .presentationCompactAdaptation(.sheet)
        .onChange(of: marker == nil) { _, isMissing in if isMissing { dismiss() } }
    }

    private func colorButton(_ color: TimelineMarkerColor, selected: Bool) -> some View {
        Button { model.setMarkerColor(markerID, to: color) } label: {
            VStack(spacing: AppSpacing.xSmall) {
                Circle().fill(color.tint)
                    .frame(width: 28, height: 28)
                    .overlay {
                        if selected {
                            Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.black)
                        }
                    }
                    .frame(width: 40, height: 40)
                    .overlay {
                        Circle().strokeBorder(selected ? AppColors.textPrimary : .clear, lineWidth: 2)
                    }
                Text(color.title).font(AppTypography.caption)
                    .foregroundStyle(selected ? AppColors.textPrimary : AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 68)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint("Changes the marker color")
    }
}

struct MarkerControls: View {
    @ObservedObject var model: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var editingMarker: TimelineMarker?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        model.addMarker()
                    } label: {
                        Label("Add marker at playhead", systemImage: "plus")
                            .frame(minHeight: 44)
                    }
                    .foregroundStyle(AppColors.accent)
                } footer: {
                    Text("Tap a marker in the timeline or this list to change its color or remove it.")
                }

                Section("Markers") {
                    if model.project.timeline.markers.isEmpty {
                        Text("No markers yet. Add one to remember a moment in your edit.")
                            .font(AppTypography.secondary).foregroundStyle(AppColors.textSecondary)
                            .padding(.vertical, AppSpacing.small)
                    }
                    ForEach(model.project.timeline.markers.sorted { $0.time < $1.time }) { marker in
                        Button { editingMarker = marker } label: {
                            HStack(spacing: AppSpacing.compact) {
                                Image(systemName: "bookmark.fill").foregroundStyle(marker.color.tint)
                                VStack(alignment: .leading, spacing: AppSpacing.xSmall) {
                                    Text(marker.displayTitle).font(AppTypography.bodyEmphasized)
                                    Text(marker.timeLabel(in: model.project)).font(AppTypography.metadataValue)
                                        .foregroundStyle(AppColors.textSecondary)
                                }
                                Spacer(minLength: AppSpacing.small)
                                Image(systemName: "chevron.right").font(.caption)
                                    .foregroundStyle(AppColors.textTertiary)
                            }
                            .frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .accessibilityLabel("\(marker.displayTitle), \(marker.timeLabel(in: model.project))")
                        .accessibilityValue(marker.color.title)
                        .accessibilityHint("Change color or remove marker")
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(model.isPreparingTimeline)
            .navigationTitle("Markers").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .sheet(item: $editingMarker) { marker in MarkerEditor(model: model, markerID: marker.id) }
        }
        .preferredColorScheme(.dark)
    }
}
