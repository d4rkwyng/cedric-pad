import AppKit
import CedricCore
import CedricAI

extension OwlChatCheck {
    /// CEDRIC_OWL_CHECK_CHAT=picture, on an SVG (the binoculars icon):
    /// "What is it a picture of?" typed into Ask Cedric. With the fake
    /// engine and tools gated off (CEDRIC_OWL_TOOLS=0), describe_image is
    /// still offered for a picture, is called, renders the SVG with the
    /// preview's WebKit renderer, and its output reaches the answer.
    /// Without the fake (a real engine), the answer is printed: Apple
    /// Intelligence with image input sees the rendered picture attached.
    static func runPicture(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window else { OwlCheck.finish(out); return }
        check(OwlPicture.isPicture(fileName: tab.doc.fileURL?.lastPathComponent), "the open document is an SVG")
        check(SVGSnapshotter.count == 0, "nothing rendered before the question")
        OwlCheck.key(window, "/", code: 44, [.command, .option])
        after(0.3) {
            guard let chat = tab.owlChat, chat.isShown else { check(false, "⌥⌘/ opens Ask Cedric"); OwlCheck.finish(out); return }
            type(chat, "What is it a picture of?")
            OwlCheck.key(chat.panel, "\r", code: 36, [])
            check(chat.running, "Return asks the question")
            waitDone(chat, timeout: 45) { _ in
                after(0.3) {
                    let t = chat.transcriptText
                    // Live, Apple Intelligence on macOS 27 may get the picture
                    // attached instead of calling the tool: rendered either way.
                    check(SVGSnapshotter.count == 1, "the SVG was rendered once, by the preview's WebKit renderer (\(SVGSnapshotter.count))")
                    if DevEnvironment.values["CEDRIC_AI_FAKE"] != nil {
                        check(t.contains(String(localized: "Looked at the picture")), "describe_image ran (the transcript says so)")
                        check(chat.lastOutcome?.toolCalls == 1, "one tool call (\(chat.lastOutcome?.toolCalls ?? -1))")
                        check(t.contains("describe_image saw") && t.contains("picture: 53×53"), "the answer includes describe_image's output")
                        check(t.contains("on white"), "with the picture's colours")
                    }
                    print("owlcheck: picture answer: \(t.components(separatedBy: "Cedric\n").last?.replacingOccurrences(of: "\n", with: " | ") ?? "")")
                    OwlCheck.snapshot(chat.panel, "\(out)/chat-picture.png") {
                        chat.close()
                        OwlCheck.finish(out)
                    }
                }
            }
        }
    }
}
