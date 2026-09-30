import SwiftUI

struct CompositionPreviewPresentation: Identifiable {
    let id = UUID()
}

/// Presentation holds immutable in-memory previews only for the sheet's lifetime.
/// Selecting a thumbnail does not start tracking; the explicit action confirms it.
struct CompositionPreviewSheet: View {
    let choices: [LocalCompositionChoice]
    let onSelect: (UUID) -> Void
    let onCancel: () -> Void
    @State private var selectedID: UUID?
    private let accent = Color(red: 0.92, green: 0.73, blue: 0.34)

    private var selection: LocalCompositionChoice? {
        choices.first(where: { $0.id == selectedID }) ?? choices.first
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let compactHeight = geometry.size.height < 600
                ScrollView {
                    if let choice = selection {
                        VStack(alignment: .leading, spacing: compactHeight ? 12 : 18) {
                            HStack {
                                Text("PHƯƠNG ÁN \((choices.firstIndex(where: { $0.id == choice.id }) ?? 0) + 1) / \(choices.count)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.1f×", Double(choice.plan.zoom)))
                                    .font(.callout.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(accent)
                            }

                            Image(decorative: choice.preview, scale: 1)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: .infinity)
                                .frame(height: min(300, geometry.size.height * (compactHeight ? 0.28 : 0.38)))
                                .background(Color.black, in: RoundedRectangle(cornerRadius: 16))
                                .accessibilityLabel("Xem trước bố cục \(choice.plan.intent.title)")

                            VStack(alignment: .leading, spacing: 6) {
                                Text(choice.plan.intent.title)
                                    .font(.title3.weight(.semibold))
                                Text(choice.plan.explanation)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, compactHeight ? 12 : 20)
                        .frame(maxWidth: 540)
                        .frame(maxWidth: .infinity)
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 8) {
                        if let choice = selection, choices.count > 1 {
                            HStack(alignment: .top, spacing: 10) {
                                ForEach(Array(choices.enumerated()), id: \.element.id) { index, option in
                                    thumbnail(option, number: index + 1, selected: option.id == choice.id,
                                              imageHeight: compactHeight ? 56 : 76)
                                }
                            }
                            .padding(.bottom, 4)
                        }
                        Button {
                            if let choice = selection { onSelect(choice.id) }
                        } label: {
                            Label("Dùng khung này", systemImage: "viewfinder")
                                .font(.headline)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accent)
                        .foregroundStyle(.black)
                        .disabled(selection == nil)
                        Text("Ảnh gợi ý không lưu vào thư viện.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 540)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
                }
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Chọn bố cục")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Hủy", action: onCancel)
                        .tint(.white)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }

    private func thumbnail(_ choice: LocalCompositionChoice, number: Int, selected: Bool,
                           imageHeight: CGFloat) -> some View {
        Button {
            selectedID = choice.id
        } label: {
            VStack(spacing: 6) {
                Image(decorative: choice.preview, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(height: imageHeight)
                    .frame(maxWidth: .infinity)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 8))
                Text("\(number). \(choice.plan.intent.title)")
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .top)
            }
            .padding(7)
            .frame(maxWidth: .infinity)
            .background(selected ? accent.opacity(0.12) : Color.white.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? accent : Color.white.opacity(0.12), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel("Phương án \(number), \(choice.plan.intent.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
