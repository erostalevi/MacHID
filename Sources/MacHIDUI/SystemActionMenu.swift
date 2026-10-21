import SwiftUI
import MacHIDDomain

/// A menu of macOS actions (Mission Control, switch desktop, media keys...) with one submenu per category.
struct SystemActionMenu: View {
    var selection: String?
    var placeholder: Text = Text("Choose…")
    let pick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(SystemActionCatalog.grouped, id: \.category) { group in
                Menu(LocalizedStringKey(group.category.title)) {
                    ForEach(group.actions) { action in
                        Button { pick(action.id) } label: {
                            Label(LocalizedStringKey(action.title), systemImage: action.id == selection ? "checkmark" : action.symbol)
                        }
                    }
                }
            }
        } label: {
            HStack {
                if let action = selection.flatMap(SystemActionCatalog.action(id:)) {
                    Image(systemName: action.symbol)
                    Text(LocalizedStringKey(action.title))
                } else { placeholder }
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.chipRadius - 2, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
    }

    /// Plain title for labels outside views.
    static func title(for id: String) -> String {
        SystemActionCatalog.action(id: id).map { String(localized: String.LocalizationValue($0.title)) } ?? id
    }
}
