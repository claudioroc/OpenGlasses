import SwiftUI

/// Settings for speaker diarization ("who said what"). Off by default — it sends audio to
/// Deepgram's cloud, so it requires an explicit opt-in + key and is unavailable under HIPAA mode.
struct DiarizationSettingsView: View {
    @State private var enabled = Config.diarizationEnabled
    @State private var keyInput = Config.deepgramAPIKey
    @State private var model = Config.diarizationModel

    /// Renamed in the captions view by tapping a speaker chip; listed here for editing.
    private let registry = SpeakerRegistry()
    @State private var names: [Int: String] = [:]

    private let models = ["nova-3", "nova-2", "nova-2-meeting"]

    var body: some View {
        Form {
            if Config.hipaaMode {
                Section {
                    Label("Disabled in HIPAA mode", systemImage: "lock.shield")
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Cloud diarization is hard-disabled while HIPAA mode is on, so clinical audio never leaves the device.")
                }
            }

            Section {
                Toggle("Enable Diarization", isOn: $enabled)
                    .disabled(Config.hipaaMode)
                    .onChange(of: enabled) { _, newValue in
                        Config.diarizationEnabled = newValue
                        // AppState picks this up if injected; also post for any listener.
                        NotificationCenter.default.post(name: .diarizationConfigChanged, object: nil)
                    }
            } footer: {
                Text("General use — not just Meeting Mode. Ambient captions, recordings, summaries, and the assistant’s room context all get speaker labels (Alice / Speaker 2). When off, transcription is a single unlabeled stream.")
            }

            Section {
                Toggle("Auto-start captions when glasses connect", isOn: Binding(
                    get: { Config.diarizationAutoStartCaptions },
                    set: { Config.diarizationAutoStartCaptions = $0 }
                ))
                .disabled(!enabled || Config.hipaaMode)
            } footer: {
                Text("When diarization is on, start listening to the room as soon as the glasses connect so every mode can hear who is speaking.")
            }

            Section {
                SecretInputField(placeholder: "Deepgram API Key", text: $keyInput)
                    .onChange(of: keyInput) { _, newValue in
                        Config.setDeepgramAPIKey(newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                        NotificationCenter.default.post(name: .diarizationConfigChanged, object: nil)
                    }
                if keyInput.isEmpty {
                    Link(destination: URL(string: "https://console.deepgram.com/")!) {
                        HStack {
                            Label("Get API Key", systemImage: "arrow.up.right.square")
                            Spacer()
                            Text("deepgram.com").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Deepgram")
            } footer: {
                Text("""
                Raw audio is streamed to Deepgram's cloud for transcription — including the voices \
                of anyone nearby, not just you. Many places (two-party-consent jurisdictions) \
                require everyone's consent before their speech is recorded, and Deepgram may retain \
                or use audio under its own terms. Unlike the on-device visual bystander filter, \
                there is no audio equivalent — nearby speech is sent as captured. The key is stored \
                in the Keychain; only enable this where recording bystanders is lawful and \
                acceptable.
                """)
            }

            Section {
                Picker("Model", selection: $model) {
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                .onChange(of: model) { _, newValue in
                    Config.diarizationModel = newValue
                }
            } header: {
                Text("Model")
            } footer: {
                Text("nova-3 has the strongest diarization. Streaming is billed per minute of audio.")
            }

            Section {
                if names.isEmpty {
                    Text("No named speakers yet. Tap a speaker chip on a caption to name them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(names.keys.sorted(), id: \.self) { id in
                        HStack {
                            Text("Speaker \(id + 1)").foregroundStyle(.secondary)
                            Spacer()
                            TextField("Name", text: bindingForName(id))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            } header: {
                Text("Speakers")
            }
        }
        .navigationTitle("Diarization")
        .onAppear { reloadNames() }
    }

    private func reloadNames() {
        names = Dictionary(uniqueKeysWithValues: registry.namedSpeakerIds.compactMap { id in
            registry.name(for: id).map { (id, $0) }
        })
    }

    private func bindingForName(_ id: Int) -> Binding<String> {
        Binding(
            get: { names[id] ?? "" },
            set: { newValue in
                names[id] = newValue
                registry.setName(newValue, for: id)
            }
        )
    }
}
