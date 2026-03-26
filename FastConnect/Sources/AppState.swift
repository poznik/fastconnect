import Combine
import Foundation
import AppKit

@MainActor
final class AppState: NSObject, ObservableObject {
    @Published private(set) var connectionStatus: VPNConnectionStatus = .disconnected
    @Published private(set) var connectionStage: String?
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

    var menuStatusText: String {
        guard let connectionStage, !connectionStage.isEmpty else {
            return connectionStatus.menuStatusTitle
        }

        return connectionStage
    }

    func loadInitialStatus() {
        do {
            let status = try vpnService.currentStateSynchronously()
            connectionStatus = status
            connectionStage = nil
            logger.info("AppState", "Начальный статус VPN: \(status.menuStatusTitle).")
        } catch {
            let message = error.localizedDescription
            connectionStatus = .error(message)
            connectionStage = nil
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

    func openCurrentLogFile() {
        do {
            try logger.openCurrentLogFileInDefaultApp()
            lastMessage = "Открыт актуальный лог."
            logger.info("AppState", "Открыт актуальный лог: \(logger.currentLogFileURL().path)")
        } catch {
            let message = error.localizedDescription
            lastMessage = message
            logger.error("AppState", "Не удалось открыть актуальный лог: \(message)")
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
            connectionStage = "Запуск подключения..."
            lastMessage = "Подключение началось"
            logger.info("AppState", "Подключение началось.")
            notificationService.send(.connectStarted)

            vpnService.connect(
                vpnHost: configuration.vpnHost,
                profileSelection: configuration.profileSelection,
                username: configuration.username,
                password: configuration.password,
                totp: totpCode,
                progress: { [weak self] line in
                    Task { @MainActor [weak self] in
                        self?.handleVPNProgressLine(line)
                    }
                }
            ) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self else { return }

                    switch result {
                    case let .success(status):
                        self.connectionStatus = status
                        if self.shouldResetConnectionStage(for: status) {
                            self.connectionStage = nil
                        }
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
                        self.connectionStage = nil
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
            connectionStage = nil
            logger.error("AppState", "Ошибка перед подключением: \(message)")
        }
    }

    func disconnect() {
        connectionStatus = .disconnecting
        connectionStage = "Запуск отключения..."
        lastMessage = "Началось отключение"
        logger.info("AppState", "Началось отключение VPN.")
        notificationService.send(.disconnectStarted)

        vpnService.disconnect(progress: { [weak self] line in
            Task { @MainActor [weak self] in
                self?.handleVPNProgressLine(line)
            }
        }) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }

                switch result {
                case let .success(status):
                    self.connectionStatus = status
                    if self.shouldResetConnectionStage(for: status) {
                        self.connectionStage = nil
                    }
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
                    self.connectionStage = nil
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
                    if self.shouldResetConnectionStage(for: status) {
                        self.connectionStage = nil
                    }
                case let .failure(error):
                    let message = error.localizedDescription
                    self.connectionStatus = .error(message)
                    self.connectionStage = nil
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

    private func handleVPNProgressLine(_ line: String) {
        guard let stage = stageMessage(from: line), stage != connectionStage else {
            return
        }

        connectionStage = stage
        lastMessage = stage
    }

    private func shouldResetConnectionStage(for status: VPNConnectionStatus) -> Bool {
        switch status {
        case .connecting, .disconnecting:
            return false
        case .connected, .disconnected, .error:
            return true
        }
    }

    private func stageMessage(from rawLine: String) -> String? {
        var stage = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stage.isEmpty else {
            return nil
        }

        if stage.hasPrefix("Copyright") {
            return nil
        }

        if stage.hasPrefix("Cisco AnyConnect Secure Mobility Client") {
            return "Запущен Cisco AnyConnect CLI..."
        }

        if stage.lowercased().hasPrefix("vpn>") {
            let command = String(stage.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !command.isEmpty else {
                return nil
            }

            stage = "Команда: \(command)"
        } else {
            if stage.hasPrefix(">>") {
                stage = String(stage.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if stage.lowercased().hasPrefix("notice:") {
                stage = String(stage.dropFirst("notice:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if stage == "Password:" || stage == "Second Password:" {
                stage = "Передача учетных данных..."
            }
        }

        if stage.count > 140 {
            stage = String(stage.prefix(137)) + "..."
        }

        return stage
    }
}
