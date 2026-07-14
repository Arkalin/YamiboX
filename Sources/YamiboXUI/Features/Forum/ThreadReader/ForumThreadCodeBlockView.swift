import SwiftUI

struct ForumThreadCodeBlockView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(Color.white.opacity(0.92))
            .textSelection(.enabled)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 8))
    }
}
