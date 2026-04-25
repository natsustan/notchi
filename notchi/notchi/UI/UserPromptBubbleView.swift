import SwiftUI

struct UserPromptBubbleView: View {
    let text: String?
    let hasAttachment: Bool

    var body: some View {
        promptText
            .font(.system(size: 13))
            .foregroundColor(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(TerminalColors.iMessageBlue)
            )
    }

    private var promptText: Text {
        let prompt = text ?? ""
        guard hasAttachment else {
            return Text(prompt)
        }

        guard !prompt.isEmpty else {
            return Text("Attached file").bold()
        }

        return Text("Attached file").bold() + Text("\n\(prompt)")
    }
}
