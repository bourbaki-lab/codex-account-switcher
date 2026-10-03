import AppKit

/// 계정 별명을 입력받는 대화상자. 취소하면 nil, 비우고 저장하면 빈 문자열을 돌려준다.
@MainActor
enum NicknamePrompt {
    static func ask(title: String, detail: String, current: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current ?? ""
        field.placeholderString = "예: 메인 Max, 회사 Pro"
        alert.accessoryView = field
        alert.addButton(withTitle: "저장")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
