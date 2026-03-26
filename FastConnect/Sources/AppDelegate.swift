import AppKit
import Combine
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum StatusBarIconStyle: Hashable {
        case gray
        case white
        case green
        case red
    }

    private let appState = AppState()
    private let logger = AppLogger.shared
    private let notificationService = AppNotificationService.shared

    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var statusLabelItem: NSMenuItem!
    private var connectMenuItem: NSMenuItem!
    private var disconnectMenuItem: NSMenuItem!
    private var openLogMenuItem: NSMenuItem!
    private var settingsWindowController: SettingsWindowController!

    private var cancellables = Set<AnyCancellable>()
    private var terminationPending = false
    private var statusIcons = [StatusBarIconStyle: NSImage]()

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

    @objc private func openCurrentLog() {
        appState.openCurrentLogFile()
    }

    @objc private func quitApplication() {
        NSApp.terminate(nil)
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageOnly
        statusIcons = makeStatusBarIcons()

        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusMenu.autoenablesItems = false

        statusLabelItem = NSMenuItem(title: "Статус: \(appState.menuStatusText)", action: nil, keyEquivalent: "")
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

        openLogMenuItem = NSMenuItem(title: "Открыть лог", action: #selector(openCurrentLog), keyEquivalent: "l")
        openLogMenuItem.target = self
        statusMenu.addItem(openLogMenuItem)

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

        appState.$connectionStage
            .sink { [weak self] _ in
                self?.refreshMenu()
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
        statusLabelItem.title = "Статус: \(appState.menuStatusText)"
        connectMenuItem.title = status.connectMenuTitle
        connectMenuItem.isEnabled = status.allowsConnect
        disconnectMenuItem.title = status.disconnectMenuTitle
        disconnectMenuItem.isEnabled = status.allowsDisconnect
        updateStatusBarIcon(for: status)
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

    private func updateStatusBarIcon(for status: VPNConnectionStatus) {
        let style: StatusBarIconStyle

        switch status {
        case .disconnected:
            style = .gray
        case .connecting, .disconnecting:
            style = .white
        case .connected:
            style = .green
        case .error:
            style = .red
        }

        guard let icon = statusIcons[style] else {
            logger.error("AppDelegate", "Не удалось получить иконку status bar для состояния: \(style)")
            return
        }

        statusItem.button?.image = icon
    }

    private func makeStatusBarIcons() -> [StatusBarIconStyle: NSImage] {
        [
            .gray: makeStatusBarIcon(
                fillColor: NSColor(srgbRed: 128.0 / 255.0, green: 128.0 / 255.0, blue: 128.0 / 255.0, alpha: 1),
                innerFillColor: NSColor.white
            ),
            .white: makeStatusBarIcon(
                fillColor: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                innerFillColor: nil
            ),
            .green: makeStatusBarIcon(
                fillColor: NSColor(srgbRed: 0, green: 173.0 / 255.0, blue: 33.0 / 255.0, alpha: 1),
                innerFillColor: NSColor.white
            ),
            .red: makeStatusBarIcon(
                fillColor: NSColor(srgbRed: 229.0 / 255.0, green: 57.0 / 255.0, blue: 53.0 / 255.0, alpha: 1),
                innerFillColor: nil
            )
        ]
    }

    private func makeStatusBarIcon(fillColor: NSColor, innerFillColor: NSColor?) -> NSImage {
        let imageSize = NSSize(width: 18, height: 18)
        let sourceSize: CGFloat = 120
        let cornerRadius: CGFloat = 12

        let image = NSImage(size: imageSize, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else {
                return false
            }

            context.saveGState()
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / sourceSize, y: rect.height / sourceSize)

            // Convert to SVG-like coordinates (origin top-left, Y down).
            context.translateBy(x: 0, y: sourceSize)
            context.scaleBy(x: 1, y: -1)

            let backgroundRect = CGRect(x: 0, y: 0, width: sourceSize, height: sourceSize)
            let backgroundPath = CGPath(
                roundedRect: backgroundRect,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )

            context.addPath(backgroundPath)
            context.setFillColor(fillColor.cgColor)
            context.fillPath()

            context.addPath(self.nexignCutoutPath())
            if let innerFillColor {
                context.setBlendMode(.normal)
                context.setFillColor(innerFillColor.cgColor)
                context.fillPath()
            } else {
                context.setBlendMode(.clear)
                context.fillPath()
            }

            context.restoreGState()
            return true
        }

        image.isTemplate = false
        image.size = imageSize
        return image
    }

    private func nexignCutoutPath() -> CGPath {
        let path = CGMutablePath()

        path.move(to: CGPoint(x: 40.1006, y: 14.377))
        path.addLine(to: CGPoint(x: 108.641, y: 106.057))
        path.addLine(to: CGPoint(x: 79.8154, y: 106.057))
        path.addLine(to: CGPoint(x: 10.6348, y: 14.377))
        path.closeSubpath()

        path.move(to: CGPoint(x: 47.1465, y: 105.444))
        path.addLine(to: CGPoint(x: 10.6348, y: 105.444))
        path.addLine(to: CGPoint(x: 47.1465, y: 68.6426))
        path.closeSubpath()

        path.move(to: CGPoint(x: 73.1279, y: 50.5322))
        path.addLine(to: CGPoint(x: 73.1279, y: 14.377))
        path.addLine(to: CGPoint(x: 109, y: 14.377))
        path.closeSubpath()

        return path
    }
}
