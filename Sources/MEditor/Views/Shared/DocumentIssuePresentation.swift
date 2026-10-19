import Foundation

/// DocumentIssue 的展示信息（图标 + 本地化文案）。
/// 诊断面板（DiagnosticsSheet）与导出前检查清单（ExportPreflightSheet）共用。
extension DocumentIssue.Kind {
    var icon: String {
        switch self {
        case .deadLink:          return "link"
        case .missingImage:      return "photo"
        case .duplicateHeading:  return "doc.on.doc"
        case .headingLevelSkip:  return "list.number"
        case .emptyHeading:      return "character.textbox"
        case .unclosedCodeBlock: return "curlybraces"
        case .mermaidSyntax:     return "chart.bar.doc.horizontal"
        }
    }

    var message: String {
        switch self {
        case .deadLink(let target):
            return L("diagnostics.deadLink", target)
        case .missingImage(let target):
            return L("diagnostics.missingImage", target)
        case .duplicateHeading(let text):
            return L("diagnostics.duplicateHeading", text)
        case .headingLevelSkip(let from, let to):
            return L("diagnostics.headingLevelSkip", from, to)
        case .emptyHeading:
            return L("diagnostics.emptyHeading")
        case .unclosedCodeBlock:
            return L("diagnostics.unclosedCodeBlock")
        case .mermaidSyntax(let message):
            return L("diagnostics.mermaidSyntax", message)
        }
    }
}
