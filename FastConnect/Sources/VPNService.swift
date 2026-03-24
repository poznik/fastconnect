import Darwin
import Foundation

enum VPNServiceError: LocalizedError {
    case binaryNotFound
    case commandTimedOut
    case commandFailed(String)
    case connectionFailed(String)
    case staleProcessTerminationFailed(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "Не найден Cisco AnyConnect CLI: /opt/cisco/anyconnect/bin/vpn"
        case .commandTimedOut:
            "Cisco AnyConnect не ответил вовремя. Проверьте VPN host, номер профиля и формат prompt-ов."
        case let .commandFailed(output):
            "Команда AnyConnect завершилась с ошибкой.\n\(output)"
        case let .connectionFailed(output):
            "Подключение не установлено.\n\(output)"
        case let .staleProcessTerminationFailed(output):
            "Не удалось завершить зависший процесс Cisco AnyConnect CLI.\n\(output)"
        }
    }
}

final class VPNService {
    private final class ClosureOperation: Operation, @unchecked Sendable {
        private let block: () -> Void

        init(block: @escaping () -> Void) {
            self.block = block
        }

        override func main() {
            guard !isCancelled else {
                return
            }

            block()
        }
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.fastconnect.vpn"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let binaryURL = URL(fileURLWithPath: "/opt/cisco/anyconnect/bin/vpn")
    private let logger: AppLogger

    init(logger: AppLogger = .shared) {
        self.logger = logger
    }

    func currentState(completion: @escaping @Sendable (Result<VPNConnectionStatus, Error>) -> Void) {
        queue.addOperation(ClosureOperation {
            do {
                let state = try self.currentStateSynchronously()
                OperationQueue.main.addOperation {
                    completion(.success(state))
                }
            } catch {
                OperationQueue.main.addOperation {
                    completion(.failure(error))
                }
            }
        })
    }

    func currentStateSynchronously(timeout: TimeInterval = 15) throws -> VPNConnectionStatus {
        let output = try runScript(["state"], timeout: timeout)
        return parseState(from: output)
    }

    func connect(vpnHost: String, profileSelection: String, username: String, password: String, totp: String, completion: @escaping @Sendable (Result<VPNConnectionStatus, Error>) -> Void) {
        queue.addOperation(ClosureOperation {
            do {
                try self.terminateExistingVPNCLIProcesses()

                let normalizedHost = self.normalizedHost(from: vpnHost)
                let normalizedProfileSelection = profileSelection.trimmingCharacters(in: .whitespacesAndNewlines)

                _ = try self.runScript([
                    "connect \(normalizedHost)",
                    normalizedProfileSelection,
                    username,
                    password,
                    password,
                    totp
                ], timeout: 60)

                Thread.sleep(forTimeInterval: 1.5)
                let stateOutput = try self.runScript(["state"], timeout: 15)
                let state = self.parseState(from: stateOutput)

                guard state == .connected else {
                    throw VPNServiceError.connectionFailed(stateOutput)
                }

                OperationQueue.main.addOperation {
                    completion(.success(state))
                }
            } catch {
                OperationQueue.main.addOperation {
                    completion(.failure(error))
                }
            }
        })
    }

    func disconnect(completion: @escaping @Sendable (Result<VPNConnectionStatus, Error>) -> Void) {
        queue.addOperation(ClosureOperation {
            do {
                _ = try self.runScript(["disconnect"], timeout: 30)
                Thread.sleep(forTimeInterval: 1.5)
                let stateOutput = try self.runScript(["state"], timeout: 15)
                let state = self.parseState(from: stateOutput)

                guard state == .disconnected else {
                    throw VPNServiceError.commandFailed(stateOutput)
                }

                OperationQueue.main.addOperation {
                    completion(.success(state))
                }
            } catch {
                OperationQueue.main.addOperation {
                    completion(.failure(error))
                }
            }
        })
    }

    private func runScript(_ commands: [String], timeout: TimeInterval) throws -> String {
        let input = commands.joined(separator: "\n") + "\n"
        return try runProcess(arguments: ["-s"], stdin: input, timeout: timeout)
    }

    private func terminateExistingVPNCLIProcesses() throws {
        let existingPIDs = try existingVPNProcessIDs()
        guard !existingPIDs.isEmpty else {
            return
        }

        logger.info("VPNService", "Найдены висящие vpn CLI процессы: \(existingPIDs.map(String.init).joined(separator: ", ")). Начинаю завершение.")

        for pid in existingPIDs {
            _ = Darwin.kill(pid, SIGTERM)
        }

        if waitForVPNProcessesToExit(timeout: 2, expectedPIDs: existingPIDs) {
            logger.info("VPNService", "Висящие vpn CLI процессы завершены через SIGTERM.")
            return
        }

        for pid in existingPIDs {
            _ = Darwin.kill(pid, SIGKILL)
        }

        guard waitForVPNProcessesToExit(timeout: 2, expectedPIDs: existingPIDs) else {
            let remaining = try existingVPNProcessIDs()
            let remainingDescription = remaining.map(String.init).joined(separator: ", ")
            logger.error("VPNService", "Не удалось завершить vpn CLI процессы. Оставшиеся PID: \(remainingDescription)")
            throw VPNServiceError.staleProcessTerminationFailed("Оставшиеся PID: \(remainingDescription)")
        }

        logger.info("VPNService", "Висящие vpn CLI процессы завершены через SIGKILL.")
    }

    private func runProcess(arguments: [String], stdin: String, timeout: TimeInterval) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw VPNServiceError.binaryNotFound
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()

        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe

        try process.run()

        let inputData = Data(stdin.utf8)
        inputPipe.fileHandleForWriting.write(inputData)
        try? inputPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            throw VPNServiceError.commandTimedOut
        }

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let combined = (stdout + stderr).trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0 else {
            throw VPNServiceError.commandFailed(combined)
        }

        return combined
    }

    private func existingVPNProcessIDs() throws -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm="]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw VPNServiceError.commandFailed(stderr.isEmpty ? stdout : stderr)
        }

        return stdout
            .split(separator: "\n")
            .compactMap { line -> Int32? in
                let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedLine.isEmpty else {
                    return nil
                }

                let components = trimmedLine.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
                guard components.count == 2 else {
                    return nil
                }

                let pidString = String(components[0]).trimmingCharacters(in: .whitespaces)
                let command = String(components[1]).trimmingCharacters(in: .whitespaces)

                guard command == binaryURL.path else {
                    return nil
                }

                return Int32(pidString)
            }
    }

    private func waitForVPNProcessesToExit(timeout: TimeInterval, expectedPIDs: [Int32]) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let remaining = (try? existingVPNProcessIDs()) ?? expectedPIDs
            if Set(remaining).isDisjoint(with: expectedPIDs) {
                return true
            }

            Thread.sleep(forTimeInterval: 0.1)
        }

        let remaining = (try? existingVPNProcessIDs()) ?? expectedPIDs
        return Set(remaining).isDisjoint(with: expectedPIDs)
    }

    private func normalizedHost(from vpnHost: String) -> String {
        let trimmed = vpnHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "connect "

        if trimmed.lowercased().hasPrefix(prefix) {
            return String(trimmed.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private func parseState(from output: String) -> VPNConnectionStatus {
        let pattern = #"state:\s*([A-Za-z]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return .error("Не удалось разобрать статус VPN.")
        }

        let nsOutput = output as NSString
        let matches = expression.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        guard let stateMatch = matches.last else {
            return .error("Cisco AnyConnect не вернул статус.")
        }

        let rawState = nsOutput.substring(with: stateMatch.range(at: 1)).lowercased()
        switch rawState {
        case "connected":
            return .connected
        case "connecting":
            return .connecting
        case "disconnecting":
            return .disconnecting
        case "disconnected":
            return .disconnected
        default:
            return .error("Неизвестный статус: \(rawState)")
        }
    }
}
