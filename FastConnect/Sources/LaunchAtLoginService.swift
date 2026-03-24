import Foundation
import ServiceManagement

enum LaunchAtLoginServiceError: LocalizedError {
    case unsupportedOS

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:
            "Автозапуск доступен на macOS 13 и новее."
        }
    }
}

final class LaunchAtLoginService {
    func isEnabled() -> Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }

        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            return true
        case .notFound, .notRegistered:
            return false
        @unknown default:
            return false
        }
    }

    func setEnabled(_ enabled: Bool) throws -> String? {
        guard #available(macOS 13.0, *) else {
            throw LaunchAtLoginServiceError.unsupportedOS
        }

        let service = SMAppService.mainApp
        if enabled {
            try service.register()
        } else {
            try service.unregister()
        }

        if service.status == .requiresApproval {
            return "Автозапуск сохранён, но системе может понадобиться подтверждение в Login Items."
        }

        return nil
    }
}
