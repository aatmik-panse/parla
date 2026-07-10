import SwiftUI

/// Card-style settings section: heading, bordered rounded card, optional footer.
struct HubSection<Content: View>: View {
    let title: String
    let footer: String?
    let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.text)
            VStack(spacing: 0) { content }
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border))
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

/// Label + optional description on the left, any control on the right.
struct HubRow<Control: View>: View {
    let label: String
    let detail: String?
    let control: Control

    init(_ label: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.text)
                if let detail {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

struct HubDivider: View {
    var body: some View {
        Divider().overlay(Theme.border).padding(.leading, 14)
    }
}

struct HubButtonStyle: ButtonStyle {
    enum Kind { case primary, normal, danger }
    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .foregroundStyle(kind == .primary ? Theme.onAccent : kind == .danger ? Theme.danger : Theme.text)
            .background(RoundedRectangle(cornerRadius: 8)
                .fill(kind == .primary ? Theme.accent : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(kind == .primary ? .clear : kind == .danger ? Theme.danger.opacity(0.5) : Theme.border))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

/// Colored-dot status capsule (Granted / Loaded / …).
struct StatusChip: View {
    let text: String
    var color: Color = Theme.success

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.13)))
    }
}

/// Read-only keyboard shortcut pill.
struct ShortcutPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accentFill))
    }
}

/// Warning banner with an optional action, shown above page content.
struct HubBanner: View {
    let text: String
    var actionTitle: String? = nil
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.danger)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if let actionTitle {
                Button(actionTitle, action: action).buttonStyle(HubButtonStyle())
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.danger.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.danger.opacity(0.35)))
    }
}

/// Muted centered placeholder for empty lists.
struct EmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
    }
}

extension View {
    /// Themed text-field chrome (use with TextField/SecureField, .plain style).
    func hubField() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
    }
}

/// Bridges an optional-String setting to a TextField: "" <-> nil.
func optBinding(_ source: Binding<String?>) -> Binding<String> {
    Binding(get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
}

/// Secret field: masked at rest, revealed while hovered or focused, with a ✕
/// button to remove the stored key. Stays revealed while focused so the
/// hover-out view swap can't steal the cursor mid-edit.
struct SecretField: View {
    let placeholder: String
    @Binding var text: String
    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if hovering || focused {
                TextField(placeholder, text: $text)
                    .focused($focused)
            } else {
                SecureField(placeholder, text: $text)
            }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Remove key")
            }
        }
        .hubField()
        .onHover { hovering = $0 }
    }
}
