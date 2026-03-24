import AppKit
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let appState = AppState()
    private let logger = AppLogger.shared
    private let notificationService = AppNotificationService.shared

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusLabelItem: NSMenuItem!
    private var connectMenuItem: NSMenuItem!
    private var disconnectMenuItem: NSMenuItem!
    private var settingsWindowController: SettingsWindowController!

    private var cancellables = Set<AnyCancellable>()
    private var terminationPending = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("AppDelegate", "Приложение запущено.")
        settingsWindowController = SettingsWindowController(appState: appState)

        appState.loadInitialStatus()
        setupStatusItem()
        bindState()
        notificationService.configure()
        appState.startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        logger.info("AppDelegate", "Приложение завершает работу.")
        appState.stopMonitoring()
    }

    func menuWillOpen(_ menu: NSMenu) {
        appState.refreshStatus()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch appState.connectionStatus {
        case .connected:
            guard !terminationPending else {
                return .terminateLater
            }

            terminationPending = true
            logger.info("AppDelegate", "Запрошен выход при активном VPN. Сначала выполняю отключение.")
            appState.stopMonitoring()
            appState.disconnect()
            return .terminateLater
        case .disconnecting:
            guard !terminationPending else {
                return .terminateLater
            }

            terminationPending = true
            logger.info("AppDelegate", "Запрошен выход во время отключения VPN. Ожидаю завершения.")
            appState.stopMonitoring()
            return .terminateLater
        case .disconnected, .connecting, .error:
            return .terminateNow
        }
    }

    @objc private func connectVPN() {
        appState.connect()
    }

    @objc private func disconnectVPN() {
        appState.disconnect()
    }

    @objc private func openSettings() {
        settingsWindowController.show()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly

        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false

        statusLabelItem = NSMenuItem(title: "Статус: \(appState.connectionStatus.menuStatusTitle)", action: nil, keyEquivalent: "")
        statusLabelItem.isEnabled = false
        statusMenu.addItem(statusLabelItem)
        statusMenu.addItem(.separator())

        connectMenuItem = NSMenuItem(title: "Подключить", action: #selector(connectVPN), keyEquivalent: "")
        connectMenuItem.target = self
        statusMenu.addItem(connectMenuItem)

        disconnectMenuItem = NSMenuItem(title: "Отключить", action: #selector(disconnectVPN), keyEquivalent: "")
        disconnectMenuItem.target = self
        statusMenu.addItem(disconnectMenuItem)

        statusMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Настройки...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        statusMenu.addItem(settingsItem)

        statusMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Выйти", action: #selector(quitApplication), keyEquivalent: "q")
        quitItem.target = self
        statusMenu.addItem(quitItem)

        statusItem.menu = statusMenu
        refreshMenu()
    }

    private func bindState() {
        appState.$connectionStatus
            .sink { [weak self] status in
                self?.refreshMenu()
                self?.finishTerminationIfNeeded(for: status)
            }
            .store(in: &cancellables)

        appState.$lastMessage
            .sink { [weak self] message in
                self?.statusItem.button?.toolTip = message
            }
            .store(in: &cancellables)
    }

    private func refreshMenu() {
        let status = appState.connectionStatus
        statusLabelItem.title = "Статус: \(status.menuStatusTitle)"
        connectMenuItem.title = status.connectMenuTitle
        connectMenuItem.isEnabled = status.allowsConnect
        disconnectMenuItem.title = status.disconnectMenuTitle
        disconnectMenuItem.isEnabled = status.allowsDisconnect
        updateStatusBarIcon(isVPNConnected: status.isVPNConnected)
    }

    private func finishTerminationIfNeeded(for status: VPNConnectionStatus) {
        guard terminationPending else {
            return
        }

        switch status {
        case .disconnected:
            logger.info("AppDelegate", "VPN отключен. Завершаю приложение.")
            terminationPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
        case let .error(message):
            logger.error("AppDelegate", "Завершаю приложение после ошибки при отключении VPN: \(message)")
            terminationPending = false
            NSApp.reply(toApplicationShouldTerminate: true)
        case .connected, .connecting, .disconnecting:
            break
        }
    }

    private func updateStatusBarIcon(isVPNConnected: Bool) {
        let assetName = isVPNConnected ? "vpn_lock_closed" : "vpn_lock_open"

        guard let icon = NSImage(named: NSImage.Name(assetName)) else {
            logger.error("AppDelegate", "Не удалось загрузить asset status bar иконки: \(assetName)")
            return
        }

        icon.isTemplate = false
        icon.size = NSSize(width: 18, height: 18)
        statusItem.button?.image = icon
    }
}
