import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState

    @State private var vpnHost: String
    @State private var profileSelection: String
    @State private var username: String
    @State private var password: String
    @State private var totpSecret: String
    @State private var launchAtLogin: Bool

    init(appState: AppState, initialConfiguration: ConnectionConfiguration) {
        self.appState = appState
        _vpnHost = State(initialValue: initialConfiguration.vpnHost)
        _profileSelection = State(initialValue: initialConfiguration.profileSelection)
        _username = State(initialValue: initialConfiguration.username)
        _password = State(initialValue: initialConfiguration.password)
        _totpSecret = State(initialValue: initialConfiguration.totpSecret)
        _launchAtLogin = State(initialValue: initialConfiguration.launchAtLogin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Form {
                TextField("VPN host", text: $vpnHost)
                TextField("Номер профиля", text: $profileSelection)
                TextField("Логин", text: $username)
                SecureField("Пароль", text: $password)
                SecureField("TOTP secret", text: $totpSecret)
                Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
            }
            .formStyle(.grouped)

            Text("Сценарий подключения: `connect <VPN host>` -> `номер профиля` -> `логин` -> `пароль` -> `пароль` -> `TOTP`. Например: `vpn.example.com` и профиль `1`.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let message = appState.settingsMessage, !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(appState.settingsMessageIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Открыть папку логов") {
                    appState.openLogsFolder()
                }

                Spacer()

                Button("Закрыть") {
                    NSApp.keyWindow?.close()
                }

                Button("Сохранить") {
                    appState.saveSettings(
                        vpnHost: vpnHost,
                        profileSelection: profileSelection,
                        username: username,
                        password: password,
                        totpSecret: totpSecret,
                        launchAtLogin: launchAtLogin
                    )
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
