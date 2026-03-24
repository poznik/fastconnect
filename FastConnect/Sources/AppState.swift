import Combine
import Foundation
import AppKit

@MainActor
final class AppState: NSObject, ObservableObject {
    @Published private(set) var connectionStatus: VPNConnectionStatus = .disconnected
    @Published private(set) var lastMessage: String?
    @Published private(set) var settingsMessage: String?
    @Published private(set) var settingsMessageIsError = false

    private let settingsStore: SettingsStore
    private let vpnService: VPNService
    private let launchAtLoginService: LaunchAtLoginService
    private let logger: AppLogger
    private let notificationService: AppNotificationService

    private var configuration: ConnectionConfiguration
    private var statusTimer: Timer?

    init(
        settingsStore: SettingsStore = SettingsStore(),
        vpnService: VPNService = VPNService(logger: .shared),
        launchAtLoginService: LaunchAtLoginService = LaunchAtLoginService(),
        logger: AppLogger = .shared,
        notificationService: AppNotificationService = .shared
    ) {
        self.settingsStore = settingsStore
        self.vpnService = vpnService
        self.launchAtLoginService = launchAtLoginService
        self.logger = logger
        self.notificationService = notificationService

        var loadedConfiguration = settingsStore.loadConfiguration()
        loadedConfiguration.launchAtLogin = launchAtLoginService.isEnabled()
        self.configuration = loadedConfiguration
    }

    var currentConfiguration: ConnectionConfiguration {
        configuration
    }

    func loadInitialStatus() {
        do {
            let status = try vpnService.currentStateSynchronously()
            connectionStatus = status
            logger.info("AppState", "Начальный статус VPN: \(status.menuStatusTitle).")
        } catch {
            let message = error.localizedDescription
            connectionStatus = .error(message)
            lastMessage = message
            logger.error("AppState", "Ошибка начального чтения статуса VPN: \(message)")
        }
    }

    func startMonitoring() {
        refreshStatus()
        scheduleStatusTimer()
    }

    func stopMonitoring() {
        statusTimer?.invalidate()
        statusTimer = nil
    }

    func saveSettings(vpnHost: String, profileSelection: String, username: String, password: String, totpSecret: String, launchAtLogin: Bool) {
        var updatedConfiguration = ConnectionConfiguration(
            vpnHost: vpnHost.trimmingCharacters(in: .whitespacesAndNewlines),
            profileSelection: profileSelection.trimmingCharacters(in: .whitespacesAndNewlines),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password,
            totpSecret: totpSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            launchAtLogin: launchAtLogin
        )

        do {
            let launchMessage = try applyLaunchAtLogin(enabled: launchAtLogin)
            updatedConfiguration.launchAtLogin = launchAtLoginService.isEnabled()
            try settingsStore.save(configuration: updatedConfiguration)

            configuration = updatedConfiguration
            settingsMessage = launchMessage ?? "Настройки сохранены."
            settingsMessageIsError = false
            lastMessage = "Настройки обновлены."
            logger.info("AppState", "Настройки сохранены.")
        } catch {
            updatedConfiguration.launchAtLogin = launchAtLoginService.isEnabled()
            try? settingsStore.save(configuration: updatedConfiguration)
            configuration = updatedConfiguration
            settingsMessage = error.localizedDescription
            settingsMessageIsError = true
            lastMessage = error.localizedDescription
            logger.error("AppState", "Ошибка при сохранении настроек: \(error.localizedDescription)")
        }
    }

    func openLogsFolder() {
        do {
            try logger.openLogsDirectoryInFinder()
            settingsMessage = "Открыта папка с логами."
            settingsMessageIsError = false
            logger.info("AppState", "Открыта папка с логами: \(logger.logsDirectoryURL.path)")
        } catch {
            settingsMessage = error.localizedDescription
            settingsMessageIsError = true
            logger.error("AppState", "Не удалось открыть папку с логами: \(error.localizedDescription)")
        }
    }

    func connect() {
        settingsMessage = nil
        settingsMessageIsError = false

        guard configuration.isComplete else {
            let message = "Заполните VPN host, номер профиля, логин, пароль и TOTP secret в настройках."
            settingsMessage = message
            settingsMessageIsError = true
            lastMessage = message
            connectionStatus = .error(message)
            logger.error("AppState", message)
            return
        }

        do {
            let totpCode = try TOTPGenerator.generate(secret: configuration.totpSecret)
            connectionStatus = .connecting
            lastMessage = "Подключение началось"
            logger.info("AppState", "Подключение началось.")
            notificationService.send(.connectStarted)

            vpnService.connect(
                vpnHost: configuration.vpnHost,
                profileSelection: configuration.profileSelection,
                username: configuration.username,
                password: configuration.password,
                totp: totpCode
            ) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    switch result {
                    case let .success(status):
                        self.connectionStatus = status
                        if status == .connected {
                            self.lastMessage = "VPN подключен"
                            self.logger.info("AppState", "VPN подключен.")
                            self.notificationService.send(.connected)
                        } else {
                            self.lastMessage = "Статус обновлён."
                            self.logger.info("AppState", "Статус VPN обновлён: \(status.menuStatusTitle).")
                        }
                    case let .failure(error):
                        let message = error.localizedDescription
                        self.connectionStatus = .error(message)
                        self.lastMessage = message
                        self.logger.error("AppState", "Ошибка подключения: \(message)")
                    }
                }
            }
        } catch {
            let message = error.localizedDescription
            settingsMessage = message
            settingsMessageIsError = true
            lastMessage = message
            connectionStatus = .error(message)
            logger.error("AppState", "Ошибка перед подключением: \(message)")
        }
    }

    func disconnect() {
        connectionStatus = .disconnecting
        lastMessage = "Началось отключение"
        logger.info("AppState", "Началось отключение VPN.")
        notificationService.send(.disconnectStarted)

        vpnService.disconnect { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch result {
                case let .success(status):
                    self.connectionStatus = status
                    if status == .disconnected {
                        self.lastMessage = "Отключен VPN"
                        self.logger.info("AppState", "VPN отключен.")
                        self.notificationService.send(.disconnected)
                    } else {
                        self.lastMessage = "Статус обновлён."
                        self.logger.info("AppState", "Статус VPN обновлён: \(status.menuStatusTitle).")
                    }
                case let .failure(error):
                    let message = error.localizedDescription
                    self.connectionStatus = .error(message)
                    self.lastMessage = message
                    self.logger.error("AppState", "Ошибка отключения: \(message)")
                }
            }
        }
    }

    func refreshStatus() {
        vpnService.currentState { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch result {
                case let .success(status):
                    self.connectionStatus = status
                case let .failure(error):
                    let message = error.localizedDescription
                    self.connectionStatus = .error(message)
                    self.lastMessage = message
                    self.logger.error("AppState", "Ошибка обновления статуса VPN: \(message)")
                }
            }
        }
    }

    private func applyLaunchAtLogin(enabled: Bool) throws -> String? {
        if enabled == launchAtLoginService.isEnabled() {
            return nil
        }

        return try launchAtLoginService.setEnabled(enabled)
    }

    private func scheduleStatusTimer() {
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(
            timeInterval: 5,
            target: self,
            selector: #selector(handleStatusTimerTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(statusTimer!, forMode: .common)
    }

    @objc private func handleStatusTimerTick() {
        refreshStatus()
    }
}
