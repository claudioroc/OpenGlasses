import Foundation

extension AppState {
    /// User-tapped Connect: stop glasses IO, reset a stuck Meta pairing, and reopen the companion.
    func reconnectToMetaAI() async {
        wakeWordService.stopListening()
        await cameraService.tearDown()
        await glassesService.reconnectToMeta()
        guard RegistrationFlow.isRegistered(stateRaw: glassesService.currentRegistrationStateRaw) else { return }
        try? await cameraService.ensurePermission()
    }
}
