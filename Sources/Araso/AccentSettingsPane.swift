import SwiftUI
import ArasoCore

struct AccentSettingsPane: View {
    @ObservedObject var model: SettingsModel
    @State private var editing: AccentProfile?
    @State private var deleting: AccentProfile?
    @State private var error: String?

    var body: some View {
        Pane(tab: .accents) {
            Text(L("Hold a letter to choose a character. Enabled languages are combined; duplicate characters appear once."))
                .foregroundStyle(Seam.ink2)
            HStack {
                Button(L("Add Language")) { editing = AccentProfile(name: "", rules: [AccentRule()]) }
                Menu(L("Add Preset")) {
                    ForEach(AccentProfile.presets) { preset in
                        Button(preset.name) {
                            var copy = preset
                            copy.id = UUID()
                            editing = copy
                        }
                    }
                }
            }
            Group {
                VStack(spacing: 10) {
                    ForEach(model.settings.accentProfiles) { profile in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(get: { profile.enabled }, set: { enabled in
                                var copy = profile; copy.enabled = enabled
                                save(copy)
                            })).labelsHidden().accessibilityLabel(profile.name)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(profile.name).font(.headline)
                                Text(profile.rules.map { "\($0.key): \($0.lower) / \($0.upper)" }.joined(separator: "   "))
                                    .font(.callout).foregroundStyle(Seam.ink2).lineLimit(3)
                            }
                            Spacer()
                            Button(L("Edit")) { editing = profile }
                            Button(role: .destructive) { deleting = profile } label: { Image(systemName: "trash") }
                                .accessibilityLabel(L("Delete Language"))
                        }
                        .padding(12)
                        .background(Seam.card, in: RoundedRectangle(cornerRadius: 10))
                    }
                    if model.settings.accentProfiles.isEmpty {
                        Text(L("No languages added. Long presses use normal typing."))
                            .foregroundStyle(Seam.ink2).padding()
                    }
                }
            }
            Text(L("Use arrows to select, 1–9 for the current page, or Return / Space / click to confirm. Esc keeps the original letter."))
                .font(.callout).foregroundStyle(Seam.ink2)
        }
        .sheet(item: $editing) { profile in
            AccentProfileEditor(profile: profile) { updated in
                try model.saveAccentProfile(updated)
            }
        }
        .alert(L("Delete Language"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("Cancel"), role: .cancel) { deleting = nil }
            Button(L("Delete"), role: .destructive) {
                if let deleting { save(deleting, deleting: true) }
                deleting = nil
            }
        } message: { Text(deleting?.name ?? "") }
        .alert(L("Could Not Save"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func save(_ profile: AccentProfile, deleting: Bool = false) {
        do { try model.saveAccentProfile(profile, deleting: deleting) }
        catch { self.error = error.localizedDescription }
    }
}

private struct AccentProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: AccentProfile
    let save: (AccentProfile) throws -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Edit Accent Characters")).font(.title2.bold())
            TextField(L("Language Name"), text: $profile.name)
            Text(L("Enter a lowercase a–z key and characters in display order, without spaces. Uppercase candidates are entered separately (for example ß / ẞ)."))
                .font(.callout).foregroundStyle(Seam.ink2)
            HStack {
                Text(L("Key")).frame(width: 48, alignment: .leading)
                Text(L("Lowercase")).frame(maxWidth: .infinity, alignment: .leading)
                Text(L("Uppercase")).frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: 28)
            }.font(.caption).foregroundStyle(Seam.ink2)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($profile.rules) { $rule in
                        HStack {
                            TextField("a", text: $rule.key).frame(width: 48)
                            TextField("àáâä", text: $rule.lower)
                            TextField("ÀÁÂÄ", text: $rule.upper)
                            Button {
                                profile.rules.removeAll { $0.id == rule.id }
                            } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).frame(width: 28).accessibilityLabel(L("Remove Key"))
                        }
                    }
                }
            }
            Button(L("Add Key")) { profile.rules.append(AccentRule()) }
            if !profile.isValid {
                Text(L("A name and at least one valid row are required. Keys must be unique lowercase a–z letters; candidates cannot contain spaces or control characters."))
                    .font(.caption).foregroundStyle(Seam.ink2)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save")) {
                    do { try save(profile); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction).disabled(!profile.isValid)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(24).frame(width: 620, height: 480).background(Seam.bg)
    }
}
