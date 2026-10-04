import SwiftUI
import PhotosUI

/// Bottom control bar — ergonomic layout for thumb and index finger use.
///
/// Layout:
///   Row 1 (primary):  [Mute]  wide mic/action capsule  [Video]
///   Row 2 (secondary): horizontally scrollable utility chips (never overflow the screen edge)
struct BottomControlBar: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var session: GeminiLiveSessionManager
    @ObservedObject var openAISession: OpenAIRealtimeSessionManager
    @ObservedObject private var assistive = AssistiveModeService.shared
    @Environment(\.appAccent) private var accent
    @Environment(\.horizontalSizeClass) private var hSize

    @Binding var showSettings: Bool
    @Binding var showModelPicker: Bool
    @Binding var showPreview: Bool
    @Binding var showPersonaPicker: Bool
    var showChatInput: Binding<Bool>? = nil

    private var isRealtime: Bool { appState.currentMode.isRealtime }
    private var isGemini: Bool { appState.currentMode == .geminiLive }
    private var isOpenAI: Bool { appState.currentMode == .openaiRealtime }

    private var realtimeSessionActive: Bool {
        isGemini ? session.isActive : (isOpenAI ? openAISession.isActive : false)
    }

    private var previewVisible: Bool { appState.isConnected }

    private var photoDisabledForLocalModel: Bool {
        guard let model = Config.activeModel, model.llmProvider == .local else { return false }
        return !model.visionEnabled
    }

    /// Side chips next to the hero capsule — fixed, never stretch.
    private let sideChipWidth: CGFloat = 56

    var body: some View {
        VStack(spacing: 8) {
            // Primary: Mute | mic capsule | Video
            HStack(spacing: 8) {
                BarButton(
                    icon: appState.micMuted ? "mic.slash.fill" : "mic.fill",
                    label: appState.micMuted ? "Unmute" : "Mute",
                    isActive: appState.micMuted,
                    compact: true
                ) {
                    appState.micMuted.toggle()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                .frame(width: sideChipWidth)

                heroCapsule
                    .frame(maxWidth: .infinity)
                    .layoutPriority(1)
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in
                                appState.micMuted.toggle()
                            }
                    )

                BarButton(
                    icon: appState.videoRecorder.isRecording ? "stop.circle.fill" : "record.circle",
                    label: appState.videoRecorder.isRecording ? "Stop" : "Video",
                    isActive: appState.videoRecorder.isRecording,
                    compact: true
                ) {
                    Task { await appState.toggleRecording() }
                }
                .frame(width: sideChipWidth)
            }

            // Secondary: scroll so extra chips never run off the edge
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    cameraButton

                    BarButton(
                        icon: appState.audioRecorder.isRecording ? "stop.fill" : "waveform",
                        label: appState.audioRecorder.isRecording ? "Stop" : "Audio",
                        isActive: appState.audioRecorder.isRecording,
                        compact: true
                    ) {
                        Task { await appState.toggleAudioRecording() }
                    }

                    if previewVisible {
                        BarButton(
                            icon: "eye",
                            label: "Preview",
                            isActive: appState.videoRecorder.isRecording,
                            compact: true
                        ) {
                            showPreview = true
                        }
                    }

                    BarButton(
                        icon: "brain",
                        label: shortModelLabel,
                        isActive: false,
                        compact: true,
                        truncateLabel: true
                    ) {
                        showModelPicker = true
                    }

                    BarButton(
                        icon: "theatermasks",
                        label: shortPersonaLabel,
                        isActive: false,
                        compact: true,
                        truncateLabel: true
                    ) {
                        showPersonaPicker = true
                    }

                    if let chatBinding = showChatInput {
                        BarButton(icon: "keyboard", label: "Type", compact: true) {
                            chatBinding.wrappedValue = true
                        }
                    }

                    if Config.accessibilityModeEnabled {
                        BarButton(
                            icon: assistive.isActive ? "eye.fill" : "eye",
                            label: "Assist",
                            isActive: assistive.isActive,
                            compact: true
                        ) {
                            appState.toggleAssistiveMode()
                        }
                    }

                    if appState.isConnected {
                        BarButton(icon: "moon.fill", label: "Sleep", compact: true) {
                            appState.disconnectGlasses()
                        }
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .onReceive(appState.glassesService.objectWillChange) { _ in }
        // Keep clear of home indicator / Dynamic Island safe areas
        .safeAreaPadding(.bottom, 2)
    }

    private var shortModelLabel: String {
        let name = appState.llmService.activeModelName
        if name.count <= 10 { return name }
        return String(name.prefix(8)) + "…"
    }

    private var shortPersonaLabel: String {
        let name = appState.activePersona?.name
            ?? Config.persona(named: "Claude")?.name
            ?? "Modes"
        if name.count <= 10 { return name }
        return String(name.prefix(8)) + "…"
    }

    // MARK: - Hero Capsule

    @ViewBuilder
    private var heroCapsule: some View {
        if isGemini {
            ActionCapsule(
                icon: session.isActive ? "stop.fill" : "play.fill",
                label: session.isActive ? "Stop" : "Gemini Live",
                isActive: session.isActive,
                color: session.isActive ? .red : accent
            ) {
                Task {
                    if session.isActive { session.stopSession() }
                    else { await session.startSession() }
                }
            }
        } else if isOpenAI {
            ActionCapsule(
                icon: openAISession.isActive ? "stop.fill" : "play.fill",
                label: openAISession.isActive ? "Stop" : "Realtime",
                isActive: openAISession.isActive,
                color: openAISession.isActive ? .red : accent
            ) {
                Task {
                    if openAISession.isActive { openAISession.stopSession() }
                    else { await openAISession.startSession() }
                }
            }
        } else if appState.isProcessing || appState.speechService.isSpeaking {
            ActionCapsule(
                icon: "stop.fill",
                label: appState.speechService.isSpeaking ? "Stop" : "Cancel",
                isActive: true,
                color: .orange
            ) {
                appState.cancelCurrentResponse()
            }
        } else if appState.isListening {
            ActionCapsule(
                icon: "stop.circle.fill",
                label: "Stop",
                isActive: true,
                color: .orange,
                showMuteBadge: appState.micMuted
            ) {
                appState.endListeningSession()
            }
        } else if !appState.glassesService.isConnected {
            ActionCapsule(
                icon: "OpenGlassesLogo",
                label: appState.glassesService.isPairing ? "Connecting…" : "Connect",
                color: accent
            ) {
                Task { await appState.reconnectToMetaAI() }
            }
        } else {
            ActionCapsule(
                icon: "mic.fill",
                label: "Talk",
                color: accent,
                showMuteBadge: appState.micMuted
            ) {
                Task {
                    appState.wakeWordService.stopListening()
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    await appState.handleWakeWordDetected(manual: true)
                }
            }
        }
    }

    // MARK: - Secondary Buttons

    @ViewBuilder
    private var cameraButton: some View {
        if !appState.glassesService.isConnected {
            BarButton(
                icon: "OpenGlassesLogo",
                label: appState.glassesService.isPairing ? "Wait" : "Connect",
                compact: true
            ) {
                Task { await appState.reconnectToMetaAI() }
            }
        } else if isRealtime {
            BarButton(
                icon: "video.fill",
                label: appState.cameraService.isStreaming ? "Live" : "Cam",
                isActive: appState.cameraService.isStreaming,
                isDisabled: !realtimeSessionActive,
                compact: true
            ) {
                if realtimeSessionActive && !appState.cameraService.isStreaming {
                    Task {
                        do { try await appState.cameraService.startStreaming() }
                        catch { appState.errorMessage = "Camera: \(error.localizedDescription)" }
                    }
                }
            }
        } else {
            BarButton(
                icon: "camera.fill",
                label: "Photo",
                isActive: appState.cameraService.isCaptureInProgress,
                isDisabled: appState.cameraService.isCaptureInProgress || photoDisabledForLocalModel,
                compact: true
            ) {
                if !photoDisabledForLocalModel {
                    Task { await appState.captureAndAnalyzePhoto() }
                }
            }
        }
    }

}

// MARK: - Action Capsule (primary touch target)

private struct ActionCapsule: View {
    let icon: String
    let label: String
    var isActive: Bool = false
    var color: Color = .white
    var showMuteBadge: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    if icon == "OpenGlassesLogo" {
                        LogoIcon(size: 16)
                            .foregroundStyle(color)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(color)
                    }

                    if showMuteBadge {
                        Image(systemName: "mic.slash.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.red)
                            .padding(2)
                            .background(.black.opacity(0.7), in: Circle())
                            .offset(x: 10, y: -7)
                    }
                }

                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color(.label))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .padding(.horizontal, 12)
            .background(isActive ? color.opacity(0.15) : Color.clear)
            .glassEffect(in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showMuteBadge ? "\(label), microphone muted" : label)
    }
}

// MARK: - Bar Button (secondary / side chips)

private struct BarButton: View {
    let icon: String
    var label: String = ""
    var isActive: Bool = false
    var isDisabled: Bool = false
    var badge: String? = nil
    var compact: Bool = false
    var truncateLabel: Bool = false
    var action: () -> Void = {}

    private var foreground: Color {
        if isDisabled { return .secondary }
        return isActive ? Color.accentColor : .primary
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                ZStack {
                    if icon == "OpenGlassesLogo" {
                        LogoIcon(size: compact ? 16 : 18)
                            .foregroundStyle(foreground)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: compact ? 15 : 16, weight: .medium))
                            .foregroundStyle(foreground)
                    }

                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Color(.label))
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Color.accentColor, in: Capsule())
                            .offset(x: 10, y: -8)
                    }
                }
                .frame(width: compact ? 28 : 32, height: compact ? 24 : 28)

                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: compact ? 8 : 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .truncationMode(truncateLabel ? .middle : .tail)
                        .frame(maxWidth: compact ? 52 : 64)
                }
            }
            .frame(width: compact ? 56 : 64, height: compact ? 44 : 48)
            .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.4 : 1)
        .accessibilityLabel(label.isEmpty ? icon.replacingOccurrences(of: ".fill", with: "").replacingOccurrences(of: ".", with: " ") : label)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
