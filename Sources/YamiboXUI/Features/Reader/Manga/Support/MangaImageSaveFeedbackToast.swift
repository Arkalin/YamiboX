import SwiftUI

#if os(iOS)
struct MangaImageSaveFeedbackToast: View {
    let feedback: MangaImageSaveFeedback

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(feedback.title)
                    .font(.headline)
                Text(feedback.message)
                    .font(.subheadline)
            }
        } icon: {
            Image(systemName: systemImageName)
                .font(.title3.weight(.semibold))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .combine)
    }

    private var systemImageName: String {
        switch feedback.kind {
        case .success, .custom:
            "checkmark.circle.fill"
        case .failure:
            "exclamationmark.triangle.fill"
        }
    }
}
#endif
