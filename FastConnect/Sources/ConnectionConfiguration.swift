import Foundation

struct ConnectionConfiguration: Equatable {
    var vpnHost: String = ""
    var profileSelection: String = ""
    var username: String = ""
    var password: String = ""
    var totpSecret: String = ""
    var launchAtLogin: Bool = false

    var isComplete: Bool {
        !vpnHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !profileSelection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !password.isEmpty &&
        !totpSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum VPNConnectionStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case error(String)

    var menuStatusTitle: String {
        switch self {
        case .disconnected:
            return "Отключено"
        case .connecting:
            return "Подключение..."
        case .connected:
            return "Подключено"
        case .disconnecting:
            return "Отключение..."
        case let .error(message):
            if message.isEmpty {
                return "Ошибка"
            }

            return "Ошибка"
        }
    }

    var connectMenuTitle: String {
        switch self {
        case .connected:
            "Подключено"
        case .connecting:
            "Подключение..."
        default:
            "Подключить"
        }
    }

    var disconnectMenuTitle: String {
        switch self {
        case .disconnecting:
            "Отключение..."
        default:
            "Отключить"
        }
    }

    var allowsConnect: Bool {
        switch self {
        case .disconnected, .error:
            true
        case .connecting, .connected, .disconnecting:
            false
        }
    }

    var allowsDisconnect: Bool {
        switch self {
        case .connected:
            true
        case .disconnected, .connecting, .disconnecting, .error:
            false
        }
    }

    var trayIconName: String {
        switch self {
        case .connected:
            "Connected"
        default:
            "Disconnected"
        }
    }
}
