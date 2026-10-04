import Foundation
import MWDATCore

/// Service for connecting to Ray-Ban Meta smart glasses
/// Uses Meta Wearables Device Access Toolkit (MWDAT)
@MainActor
class GlassesConnectionService: ObservableObject {
    @Published var isConnected: Bool = false
    @Published var connectionStatus: String = "Not connected"
    @Published var deviceName: String?
    @Published var batteryLevel: Int?
    /// True while a user-tapped Connect is unregistering / opening Meta / waiting for approval.
    @Published var isPairing: Bool = false

    private var devicesListenerToken: (any AnyListenerToken)?
    private var connectedDeviceId: DeviceIdentifier?
    private var isPairingInFlight = false

    init() {
        // Wearables observers are attached explicitly after successful SDK configure.
    }

    /// Begin observing connected devices. Call after Wearables.configure().
    func startObserving() {
        guard devicesListenerToken == nil else { return }
        observeDevices()
    }

    private func observeDevices() {
        devicesListenerToken = Wearables.shared.addDevicesListener { [weak self] deviceIds in
            Task { @MainActor in
                self?.handleDevicesChanged(deviceIds)
            }
        }
    }

    private func handleDevicesChanged(_ deviceIds: [DeviceIdentifier]) {
        if let firstId = deviceIds.first {
            let device = Wearables.shared.deviceForIdentifier(firstId)
            connectedDeviceId = firstId
            isConnected = true
            deviceName = device?.name
            connectionStatus = "Connected to \(device?.nameOrId() ?? "glasses")"
        } else {
            connectedDeviceId = nil
            isConnected = false
            deviceName = nil
            batteryLevel = nil
            if !isPairing {
                connectionStatus = "Disconnected"
            }
        }
    }

    var currentRegistrationStateRaw: Int {
        Wearables.shared.registrationState.rawValue
    }

    var hasDevice: Bool {
        !Wearables.shared.devices.isEmpty || connectedDeviceId != nil
    }

    /// Start (or restart) DAT registration. Does not mark the glasses connected — that happens
    /// when a device appears on the listener.
    func connect() async {
        await reconnectToMeta()
    }

    /// User-initiated Connect. Mirrors onboarding: `startRegistration()` is what deep-links
    /// Meta AI with the DAT authorization request. Opening `fb-viewapp://` ourselves would
    /// replace that sheet with Meta's home screen.
    func reconnectToMeta() async {
        guard !isPairingInFlight else { return }
        isPairingInFlight = true
        isPairing = true
        defer {
            isPairingInFlight = false
            isPairing = false
        }

        startObserving()

        let state = Wearables.shared.registrationState.rawValue
        let devicePresent = hasDevice
        print("📋 Reconnect to Meta — state=\(state) hasDevice=\(devicePresent)")

        if RegistrationFlow.needsFreshMetaPairing(stateRaw: state, hasDevice: devicePresent) {
            connectionStatus = "Resetting Meta pairing…"
            do {
                try await Wearables.shared.startUnregistration()
                print("📋 Unregistered before retry")
            } catch {
                print("📋 Unregistration failed: \(error)")
            }
            isConnected = false
            connectedDeviceId = nil
            deviceName = nil
            UserDefaults.standard.set(false, forKey: "hasRegisteredWithMeta")
            try? await Task.sleep(nanoseconds: 800_000_000)
        }

        connectionStatus = RegistrationFlow.status(stateRaw: Wearables.shared.registrationState.rawValue)
        do {
            try await Wearables.shared.startRegistration()
            print("📋 startRegistration — DAT should present the Meta authorization sheet")
        } catch {
            print("❌ startRegistration() failed: \(error)")
            connectionStatus = "Connection failed: \(error.localizedDescription)"
        }

        var stateAfter = Wearables.shared.registrationState
        let deadline = ContinuousClock.now + .seconds(RegistrationFlow.approvalDeadlineSeconds)
        while !RegistrationFlow.isRegistered(stateRaw: stateAfter.rawValue), ContinuousClock.now < deadline {
            connectionStatus = RegistrationFlow.status(stateRaw: stateAfter.rawValue)
            try? await Task.sleep(nanoseconds: 500_000_000)
            stateAfter = Wearables.shared.registrationState
        }

        if RegistrationFlow.isRegistered(stateRaw: stateAfter.rawValue) {
            connectionStatus = "Approve camera in Meta AI…"
            do {
                let camera = try await Wearables.shared.requestPermission(.camera)
                print("📋 Meta camera permission: \(camera)")
            } catch {
                print("📋 Meta camera permission request failed: \(error)")
            }
            connectionStatus = hasDevice
                ? "Connected to \(deviceName ?? "glasses")"
                : RegistrationFlow.status(stateRaw: stateAfter.rawValue)
        } else {
            connectionStatus = RegistrationFlow.retryHint(stateRaw: stateAfter.rawValue, hasDevice: false)
        }
    }

    func disconnect() {
        connectedDeviceId = nil
        isConnected = false
        deviceName = nil
        batteryLevel = nil
        connectionStatus = "Disconnected"
    }
}

// MARK: - Errors
enum GlassesError: LocalizedError {
    case connectionFailed(String)
    case notConnected
    case streamingFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .notConnected: return "Glasses not connected"
        case .streamingFailed(let msg): return "Streaming failed: \(msg)"
        }
    }
}
