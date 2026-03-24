import AppKit
import Foundation
import UserNotifications

enum AppNotificationEvent {
    case connectStarted
    case connected
    case disconnectStarted
    case disconnected

    var title: String {
        switch self {
        case .connectStarted:
            return "Подключение началось"
        case .connected:
            return "VPN подключен"
        case .disconnectStarted:
            return "Началось отключение"
        case .disconnected:
            return "Отключен VPN"
        }
    }

    var iconName: String {
        switch self {
        case .connectStarted, .connected:
            return "Connected"
        case .disconnectStarted, .disconnected:
            return "Disconnected"
        }
    }
}

@MainActor
final class AppNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationService(logger: .shared)

    private let logger: AppLogger
    private let center = UNUserNotificationCenter.current()
    private let fileManager = FileManager.default
    private var authorizationRequestScheduled = false
    private lazy var notificationAssetsDirectory: URL = {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("FastConnect", isDirectory: true)
            .appendingPathComponent("NotificationAssets", isDirectory: true)
    }()

    init(logger: AppLogger) {
        self.logger = logger
        super.init()
    }

    func configure() {
        center.delegate = self
        center.getNotificationSettings { [weak self] settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self, status] in
                self?.handleAuthorizationStatus(status)
            }
        }
    }

    private func handleAuthorizationStatus(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            logger.info("Notifications", "Уведомления уже разрешены для текущей сборки. Статус: \(authorizationStatusDescription(status)).")
        case .notDetermined:
            logger.info("Notifications", "Уведомления ещё не запрашивались. Готовлю запрос доступа.")
            scheduleAuthorizationRequest()
        case .denied:
            logger.info("Notifications", "Уведомления уже запрещены в системе. Повторный system prompt не появится, пока пользователь не изменит настройку вручную.")
        @unknown default:
            logger.info("Notifications", "Неизвестный статус разрешений уведомлений. Повторно запрашиваю доступ.")
            scheduleAuthorizationRequest()
        }
    }

    private func scheduleAuthorizationRequest() {
        guard !authorizationRequestScheduled else {
            return
        }

        authorizationRequestScheduled = true
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.requestAuthorization()
        }
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [logger] granted, error in
            if let error {
                logger.error("Notifications", "Не удалось запросить разрешение на уведомления: \(error.localizedDescription)")
                return
            }

            logger.info("Notifications", granted ? "Разрешение на уведомления получено." : "Разрешение на уведомления не выдано.")
        }
    }

    func send(_ event: AppNotificationEvent) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.sound = .default

        if let attachment = makeAttachment(for: event) {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: "fastconnect.\(event.iconName).\(UUID().uuidString)",
            content: content,
            trigger: nil
        )

        center.add(request) { [logger] error in
            if let error {
                logger.error("Notifications", "Не удалось отправить уведомление '\(event.title)': \(error.localizedDescription)")
            } else {
                logger.info("Notifications", "Отправлено уведомление '\(event.title)'.")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    private func authorizationStatusDescription(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        case .provisional:
            return "provisional"
        case .ephemeral:
            return "ephemeral"
        @unknown default:
            return "unknown"
        }
    }

    private func makeAttachment(for event: AppNotificationEvent) -> UNNotificationAttachment? {
        do {
            try fileManager.createDirectory(at: notificationAssetsDirectory, withIntermediateDirectories: true)

            guard let sourceURL = Bundle.main.url(forResource: event.iconName, withExtension: "icns"),
                  let image = NSImage(contentsOf: sourceURL),
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                logger.error("Notifications", "Не удалось подготовить иконку '\(event.iconName)' для уведомления.")
                return nil
            }

            let destinationURL = notificationAssetsDirectory.appendingPathComponent("\(event.iconName).png")
            try pngData.write(to: destinationURL, options: .atomic)

            return try UNNotificationAttachment(identifier: event.iconName, url: destinationURL)
        } catch {
            logger.error("Notifications", "Не удалось создать attachment для уведомления: \(error.localizedDescription)")
            return nil
        }
    }
}
