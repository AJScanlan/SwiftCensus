/// Splits the trailing `[snake_case_id]` (from `-debug-diagnostic-names`) and `[#Group]`
/// (from `-print-diagnostic-groups`) off a rendered message. A1: the identifier is embedded
/// in the text, not exposed as a field.
enum MessageSuffix {
    static func split(_ text: String) -> (message: String, id: String?, group: String?) {
        var message = Substring(text)
        var id: String?
        var group: String?
        // At most one of each, in either order.
        for _ in 0..<2 {
            let trimmed = message.reversed().drop(while: { $0 == " " || $0 == "\n" })
            let body = Substring(String(trimmed.reversed()))
            guard body.hasSuffix("]"), let open = body.lastIndex(of: "["),
                  open > body.startIndex, body[body.index(before: open)] == " "
            else { break }
            let inner = body[body.index(after: open)..<body.index(before: body.endIndex)]
            if inner.hasPrefix("#"), group == nil {
                group = String(inner.dropFirst())
            } else if id == nil, isSnakeCaseIdentifier(inner) {
                id = String(inner)
            } else {
                break
            }
            message = body[..<body.index(before: open)]
        }
        return (String(message), id, group)
    }

    private static func isSnakeCaseIdentifier(_ s: Substring) -> Bool {
        guard let first = s.first, first.isLowercase, first.isASCII else { return false }
        return s.allSatisfy { ($0.isLowercase && $0.isASCII) || $0.isNumber || $0 == "_" }
    }
}
