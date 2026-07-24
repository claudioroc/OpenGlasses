import SwiftUI

/// Voice tab — the primary interaction screen.
///
/// Layout (top to bottom):
///   1. Two status pills (Glasses + OpenClaw) at top
///   2. StatusIndicator (center, with quick actions)
///   3. Transcript overlay
///   4. Chat input bar (text + image attach) or hero capsule
///   5. Hero capsule + floating action buttons (bottom)
struct VoiceTab: View {
    @EnvironmentObject var appState: AppState
    @AppStorage("silentMode") private var qcSilent = false
    @AppStorage("smartCameraEnabled") private var qcSmartCam = false
    @State private var showPreview = false
    @State private var showModelPicker = false
    @State private var showPersonaPicker = false
    @State private var showChatInput = false

    private var session: GeminiLiveSessionManager { appState.geminiLiveSession }
    private var openAISession: OpenAIRealtimeSessionManager { appState.openAIRealtimeSession }

    private var isRealtime: Bool { appState.currentMode.isRealtime }

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                // Quick controls (added 2026-07-24): mic / silent / smart-cam / live / persona
                HStack(spacing: 22) {
                    Button { appState.micMuted.toggle() } label: {
                        Image(systemName: appState.micMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundColor(appState.micMuted ? .red : .primary)
                    }
                    Button { qcSilent.toggle() } label: {
                        Image(systemName: qcSilent ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .foregroundColor(qcSilent ? .orange : .primary)
                    }
                    Button { qcSmartCam.toggle() } label: {
                        Image(systemName: qcSmartCam ? "camera.fill" : "camera")
                            .foregroundColor(qcSmartCam ? .blue : .primary)
                    }
                    Button {
                        appState.switchMode(to: appState.currentMode == .geminiLive ? .direct : .geminiLive)
                    } label: {
                        Image(systemName: appState.currentMode == .geminiLive ? "dot.radiowaves.left.and.right" : "waveform")
                            .foregroundColor(appState.currentMode == .geminiLive ? .green : .primary)
                    }
                    Menu {
                        ForEach(Config.enabledPersonas, id: \.id) { p in
                            Button(p.name) {
                                appState.activePersona = p
                                Config.setActiveModelId(p.modelId)
                                Config.setActivePresetId(p.presetId)
                                appState.llmService.refreshActiveModel()
                            }
                        }
                    } label: {
                        Image(systemName: "theatermasks.fill")
                            .foregroundColor(appState.activePersona != nil ? .purple : .primary)
                    }
                }
                .font(.title3)
                .padding(.vertical, 8)
                // Recording indicator
                if appState.videoRecorder.isRecording {
                    recordingBadge
                        .padding(.top, 8)
                }

                // Status pills row
                StatusPillsRow(
                    openClawBridge: appState.openClawBridge
                )
                .padding(.top, 8)

                // Status card
                StatusIndicator(session: session, openAISession: openAISession)
                    .padding(.top, 12)

                Spacer()

                // Ambient captions
                if appState.ambientCaptions.isActive {
                    AmbientCaptionOverlay(captionService: appState.ambientCaptions)
                        .padding(.bottom, 8)
                }

                // Transcript
                TranscriptOverlay(session: session, openAISession: openAISession)
                    .padding(.bottom, 8)

                // Load the on-device model on demand — only shown when the active
                // model is local, so it's not lazy-loaded (slowly) on first query.
                if let local = appState.llmService.localLLMService {
                    LocalModelBar(service: local)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                }

                // Quick actions (above hero capsule)
                if !showChatInput {
                    QuickActionsGrid()
                }

                // Chat input bar (when active) or voice controls
                if showChatInput && !isRealtime {
                    ChatInputBar(showChatInput: $showChatInput)
                } else {
                    VoiceTabControls(
                        session: session,
                        openAISession: openAISession,
                        showPreview: $showPreview,
                        showModelPicker: $showModelPicker,
                        showChatInput: $showChatInput
                    )
                }
            }
        }
        .fullScreenCover(isPresented: $showPreview) {
            LivePreviewView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $showModelPicker) {
            ModelPickerSheet(appState: appState)
        }
        .sheet(isPresented: $showPersonaPicker) {
            PersonaPickerSheet(appState: appState)
        }
        .sheet(item: $appState.pendingShareItem) { item in
            ShareSheet(items: item.items)
        }
    }

    // MARK: - Recording Badge

    private var recordingBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text("REC \(appState.videoRecorder.formattedDuration)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(.red.opacity(0.3)))
        .accessibilityLabel("Recording: \(appState.videoRecorder.formattedDuration)")
    }
}

// MARK: - Local Model Bar (home-screen load/unload)

/// Home-screen control to load/unload the on-device model on demand. Shown only when
/// the active model is a local (MLX) model, so the user isn't waiting on a lazy load
/// at first query — and can free memory when done.
private struct LocalModelBar: View {
    @ObservedObject var service: LocalLLMService
    @Environment(\.appAccent) private var accent

    var body: some View {
        if let active = Config.activeModel, active.llmProvider == .local {
            content(active)
        }
    }

    @ViewBuilder
    private func content(_ active: ModelConfig) -> some View {
        let modelId = active.model
        let isLoaded = service.isModelLoaded && service.loadedModelId == modelId

        if service.isLoadingModel {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading \(active.name)…")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                if service.downloadProgress > 0, service.downloadProgress < 1 {
                    Text("\(Int(service.downloadProgress * 100))%")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.4), in: Capsule())
        } else if isLoaded {
            Button { service.unloadModel() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(active.name) loaded")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Color(.label))
                    Text("· Unload").font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(.green.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(active.name) loaded. Tap to unload.")
        } else {
            Button { Task { try? await service.loadModel(modelId) } } label: {
                HStack(spacing: 7) {
                    Image(systemName: "cpu")
                    Text("Load \(active.name)")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(accent, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Load on-device model \(active.name)")
        }
    }
}

// MARK: - Voice Tab Controls (hero capsule + secondary buttons)

/// Bottom controls for the Voice tab — reuses the original BottomControlBar patterns.
private struct VoiceTabControls: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager

    @Binding var showPreview: Bool
    @Binding var showModelPicker: Bool
    @Binding var showChatInput: Bool

    var body: some View {
        BottomControlBar(
            session: session,
            openAISession: openAISession,
            showSettings: .constant(false),
            showModelPicker: $showModelPicker,
            showPreview: $showPreview,
            showChatInput: $showChatInput
        )
    }
}

// MARK: - Status Pills Row

struct StatusPillsRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var openClawBridge: OpenClawBridge

    var body: some View {
        HStack {
            glassesPill
            Spacer()
            if Config.isOpenClawConfigured {
                openClawPill
            }
        }
        .padding(.horizontal, 16)
    }

    @State private var showDisconnectConfirm = false

    private var glassesPill: some View {
        let connected = appState.isConnected
        let color: Color = connected ? .green : .red.opacity(0.7)
        let label = connected ? (appState.glassesService.deviceName ?? "Glasses") : "Disconnected"

        return Button {
            if connected {
                showDisconnectConfirm = true
            } else {
                Task { await appState.glassesService.connect() }
            }
        } label: {
            HStack(spacing: 6) {
                LogoIcon(size: 15)
                    .foregroundStyle(color)
                if connected {
                    Circle().fill(color).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(in: .capsule)
        }
        .buttonStyle(.plain)
        .confirmationDialog("Disconnect Glasses", isPresented: $showDisconnectConfirm) {
            Button("Disconnect", role: .destructive) {
                appState.disconnectGlasses()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stop mic, camera, and TTS. Gateway tasks keep running.")
        }
        .accessibilityLabel("Glasses: \(label)")
    }

    private var openClawPill: some View {
        let (color, label): (Color, String) = {
            switch openClawBridge.connectionState {
            case .connected: return (.green, "Connected")
            case .checking: return (.orange, "Checking")
            case .unreachable: return (.red, "Unreachable")
            case .notConfigured: return (.gray, "Not Set Up")
            }
        }()

        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("OpenClaw")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(.label))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassEffect(in: .capsule)
        .accessibilityLabel("OpenClaw: \(label)")
    }
}

// MARK: - Chat Input Bar

/// Voice-tab inline chat input — the hero capsule's typed-message alternative.
/// A thin wrapper over the shared `ChatComposer`: the mic button switches back to voice,
/// and sends route through the standard voice pipeline (spoken reply preserved).
struct ChatInputBar: View {
    @EnvironmentObject var appState: AppState
    @Binding var showChatInput: Bool

    var body: some View {
        ChatComposer(autoFocus: true, voiceAction: { showChatInput = false }) { text, image in
            Task { await appState.sendTextMessage(text, imageData: image) }
        }
    }
}

