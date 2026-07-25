import SwiftUI

/// Provider configuration, grouped by pipeline stage in the order data flows:
/// speech-to-text → polish → the session that powers the keyboard. Key status
/// is a first-class state (Missing / Unverified / Verified), never a mystery.
struct ConfigurationView: View {
    @State private var settings = SettingsStore.load()
    @State private var editingKey: KeyEditorContext?
    /// Bumped after the key sheet closes so status badges re-read the store.
    @State private var keyStateVersion = 0

    var body: some View {
        NavigationStack {
            Form {
                asrSection
                polishSection
                sessionSection
                translateSection
                aboutSection
            }
            .navigationTitle("Settings")
            .onChange(of: settings) { SettingsStore.save(settings) }
            .sheet(item: $editingKey, onDismiss: { keyStateVersion += 1 }) { context in
                KeyEditorSheet(context: context)
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: Speech to text

    private var asrSection: some View {
        Section {
            // A menu rather than the old two-value segmented control: engines
            // are no longer a binary, and their names don't fit in segments.
            Picker("Engine", selection: $settings.asrBackend) {
                ForEach(ProviderSettings.ASRBackend.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            switch settings.asrBackend {
            case .apple:
                EmptyView()
            case .openAICompatible:
                presetRow(ProviderPreset.asr) { preset in
                    settings.asrBaseURL = preset.baseURL
                    settings.asrModel = preset.model
                }
                LabeledContent("Base URL") {
                    plainField("https://api.openai.com/v1", text: $settings.asrBaseURL)
                }
                LabeledContent("Model") {
                    plainField("gpt-4o-transcribe", text: $settings.asrModel)
                }
                keyRow("API Key", key: .asrAPIKey, target: .openAICompatible(baseURL: settings.asrBaseURL),
                       getKeyURL: ProviderConsole.keyURL(forBaseURL: settings.asrBaseURL))
            case .elevenLabs:
                modelPresetMenu(ProviderSettings.elevenLabsModels, into: \.elevenLabsModel)
                LabeledContent("Model") {
                    plainField("scribe_v1", text: $settings.elevenLabsModel)
                }
                keyRow("API Key", key: .asrElevenLabsKey, target: .elevenLabs,
                       getKeyURL: ProviderConsole.keyURL(forBaseURL: ElevenLabsASR.endpoint.absoluteString))
            }
            LabeledContent("Language") {
                plainField("auto", text: $settings.asrLanguage)
            }
        } header: {
            Text("Speech to text")
        } footer: {
            switch settings.asrBackend {
            case .apple:
                Text("Free, offline, no key needed — Apple on-device recognition. Language is an ISO-639 hint like “en” or “zh”; empty auto-detects.")
            case .openAICompatible:
                Text("Any OpenAI-compatible endpoint: OpenAI, Groq, etc.")
            case .elevenLabs:
                Text("ElevenLabs Scribe — high accuracy across ~99 languages. Your dictionary is applied during polish rather than here; Scribe has no term-biasing field.")
            }
        }
    }

    // MARK: Polish

    /// Entirely data-driven from `PolishBackendSpec` — a new provider needs no
    /// change here, only a registry entry.
    private var polishSection: some View {
        let spec = PolishBackendSpec.for(settings.polishBackend)
        return Section {
            Picker("Provider", selection: $settings.polishBackend) {
                ForEach(ProviderSettings.PolishBackend.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            // Configurable-endpoint providers get base-URL presets + field.
            if let baseURLKeyPath = spec.baseURLKeyPath {
                presetRow(ProviderPreset.polish) { preset in
                    settings[keyPath: baseURLKeyPath] = preset.baseURL
                    settings[keyPath: spec.modelKeyPath] = preset.model
                }
                LabeledContent("Base URL") {
                    plainField("https://api.openai.com/v1", text: binding(baseURLKeyPath))
                }
            }
            // Fixed-model quick-pick (e.g. DeepSeek's flash/pro).
            if !spec.presetModels.isEmpty {
                modelPresetMenu(spec.presetModels, into: spec.modelKeyPath)
            }
            LabeledContent("Model") {
                plainField(ProviderSettings()[keyPath: spec.modelKeyPath], text: binding(spec.modelKeyPath))
            }
            keyRow("API Key", key: spec.keychainKey,
                   target: spec.makeVerifyTarget(settings),
                   getKeyURL: spec.makeGetKeyURL(settings))
        } header: {
            Text("Polish")
        } footer: {
            Text("Keys live in the iOS Keychain and are only read by this app — never by the keyboard.")
        }
    }

    /// Quick-pick menu for an engine that offers a fixed set of models.
    private func modelPresetMenu(
        _ models: [String],
        into keyPath: WritableKeyPath<ProviderSettings, String>
    ) -> some View {
        Menu {
            ForEach(models, id: \.self) { model in
                Button(model) { settings[keyPath: keyPath] = model }
            }
        } label: {
            LabeledContent("Preset") {
                HStack(spacing: 4) {
                    Text("Choose…")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(Color.appAccent)
            }
        }
    }

    /// A two-way binding into a `ProviderSettings` string field by key path,
    /// so the registry's key paths can drive text fields directly.
    private func binding(_ keyPath: WritableKeyPath<ProviderSettings, String>) -> Binding<String> {
        Binding(get: { settings[keyPath: keyPath] }, set: { settings[keyPath: keyPath] = $0 })
    }

    // MARK: Session / Translate / About

    private var sessionSection: some View {
        Section {
            Picker("Turn off after", selection: $settings.sessionAutoEndMinutes) {
                ForEach(ProviderSettings.autoEndChoices, id: \.minutes) { choice in
                    Text(choice.label).tag(choice.minutes)
                }
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("The app keeps the microphone ready in the background so the keyboard can dictate in other apps (you'll see the orange mic indicator). Turning it off after a while saves battery — opening the app turns it back on.")
        }
    }

    private var translateSection: some View {
        Section {
            Picker("Target language", selection: $settings.targetLanguage) {
                ForEach(ProviderSettings.targetLanguages, id: \.self) { language in
                    Text(language).tag(language)
                }
            }
        } header: {
            Text("Translate template")
        } footer: {
            Text("The Translate style rewrites your speech into this language.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            }
            Link(destination: URL(string: "https://github.com/cosmicshuai/open_voice_typer")!) {
                LabeledContent("Source") { Text("GitHub") }
            }
        }
    }

    // MARK: Pieces

    private func presetRow(
        _ presets: [ProviderPreset],
        apply: @escaping (ProviderPreset) -> Void
    ) -> some View {
        Menu {
            ForEach(presets) { preset in
                Button(preset.name) { apply(preset) }
            }
        } label: {
            LabeledContent("Preset") {
                HStack(spacing: 4) {
                    Text("Choose…")
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
                .foregroundStyle(Color.appAccent)
            }
        }
    }


    private func keyRow(
        _ label: String,
        key: KeychainStore.Key,
        target: KeyVerifier.Target,
        getKeyURL: String? = nil
    ) -> some View {
        // keyStateVersion invalidates this row when the sheet saves a key.
        let status = KeyStatusStore.status(for: key)
        _ = keyStateVersion
        return Button {
            editingKey = KeyEditorContext(key: key, target: target, getKeyURL: getKeyURL)
        } label: {
            LabeledContent(label) {
                switch status {
                case .missing:
                    Label("Missing", systemImage: "circle.fill")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.red)
                case .unverified:
                    Text("Saved — not verified")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                case .verified:
                    Label("Verified", systemImage: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .tint(.primary)
    }

    private func plainField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .multilineTextAlignment(.trailing)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.URL)
    }
}

// MARK: - Key editor sheet

private struct KeyEditorContext: Identifiable {
    let key: KeychainStore.Key
    let target: KeyVerifier.Target
    let getKeyURL: String?
    var id: String { key.rawValue }
}

/// Paste, verify (free list-models call), and save a key.
private struct KeyEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let context: KeyEditorContext

    @State private var keyText: String
    @State private var isVerifying = false
    @State private var verifyError: String?

    init(context: KeyEditorContext) {
        self.context = context
        _keyText = State(initialValue: KeychainStore.get(context.key) ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Paste your API key", text: $keyText)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("Verification makes one free request (list models) — it never spends tokens.")
                }
                if let verifyError {
                    Section {
                        Text(verifyError)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                Section {
                    Button {
                        verifyAndSave()
                    } label: {
                        HStack {
                            if isVerifying { ProgressView().controlSize(.small) }
                            Text("Verify & Save")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(isVerifying || keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Save without verifying") {
                        saveOnly()
                        dismiss()
                    }
                    .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Remove key", role: .destructive) {
                        KeychainStore.delete(context.key)
                        KeyStatusStore.clear(context.key)
                        dismiss()
                    }
                    .disabled(KeychainStore.get(context.key) == nil)
                }
                if let getKeyURL = context.getKeyURL, let url = URL(string: getKeyURL) {
                    Section {
                        Link("Get an API key", destination: url)
                    }
                }
            }
            .navigationTitle("API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func saveOnly() {
        KeychainStore.set(keyText, for: context.key)
        KeyStatusStore.clear(context.key)
    }

    private func verifyAndSave() {
        isVerifying = true
        verifyError = nil
        let trimmed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            defer { isVerifying = false }
            do {
                try await KeyVerifier.verify(key: trimmed, target: context.target)
                KeychainStore.set(trimmed, for: context.key)
                KeyStatusStore.markVerified(context.key)
                dismiss()
            } catch {
                // Key is kept in the field so the user can still save it unverified.
                verifyError = error.localizedDescription
            }
        }
    }
}

#Preview {
    ConfigurationView()
}
