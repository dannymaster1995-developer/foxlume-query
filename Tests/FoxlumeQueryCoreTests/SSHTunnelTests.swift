import Foundation
import Testing
@testable import FoxlumeQueryCore

@Suite struct SSHTunnelArgumentTests {
    let knownHosts = URL(fileURLWithPath: "/tmp/eq-known-hosts")

    @Test func keyFileWithoutPassphraseRunsInBatchMode() {
        let tunnel = SSHTunnel(config: SSHConfig(isEnabled: true, host: "bastion", port: 2222, user: "deploy", authMethod: .keyFile, keyPath: "/keys/id"), secret: nil, remoteHost: "db.internal", remotePort: 5432)
        let arguments = tunnel.arguments(timeout: 10, knownHostsFile: knownHosts)
        #expect(arguments.contains("-i"))
        #expect(arguments.contains("/keys/id"))
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("IdentitiesOnly=yes"))
        #expect(arguments.contains("UserKnownHostsFile=/tmp/eq-known-hosts"))
        #expect(arguments.last == "deploy@bastion")
        #expect(arguments[arguments.firstIndex(of: "-p")! + 1] == "2222")
        let forward = arguments[arguments.firstIndex(of: "-L")! + 1]
        #expect(forward.hasSuffix(":db.internal:5432"))
        #expect(forward.hasPrefix("127.0.0.1:"))
    }

    @Test func passwordDisablesKeysAndPrompts() {
        let tunnel = SSHTunnel(config: SSHConfig(isEnabled: true, host: "bastion", user: "", authMethod: .password), secret: "pw", remoteHost: "db", remotePort: 3306)
        let arguments = tunnel.arguments(timeout: 10, knownHostsFile: knownHosts)
        #expect(arguments.contains("PubkeyAuthentication=no"))
        #expect(!arguments.contains("BatchMode=yes"))
        #expect(arguments.last == "bastion")
    }

    @Test func freeLocalPortIsUsable() throws {
        let port = try SSHTunnel.freeLocalPort()
        #expect(port > 1024)
        #expect(!SSHTunnel.portAcceptsConnections(port))
    }
}

/// Runs against the project-local sshd from `.sshtest` (port 52222) and PostgreSQL on 55432; skipped when either is down.
@Suite(.serialized) struct SSHTunnelLiveTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var keyPath: String { root.appendingPathComponent(".sshtest/client_key_pass").path }
    static var available: Bool {
        FileManager.default.fileExists(atPath: keyPath)
            && SSHTunnel.portAcceptsConnections(52222)
            && SSHTunnel.portAcceptsConnections(55432)
    }

    func parameters(secret: String) -> ConnectionParameters {
        let ssh = SSHConfig(isEnabled: true, host: "127.0.0.1", port: 52222, user: NSUserName(), authMethod: .keyFile, keyPath: Self.keyPath)
        let config = ConnectionConfig(kind: .postgresql, host: "127.0.0.1", port: 55432, user: "postgres", database: "foxlume", ssh: ssh)
        return ConnectionParameters(config: config, password: "postgres", sshSecret: secret)
    }

    @Test(.enabled(if: available)) func queriesThroughTunnelAndStopsSSH() async throws {
        let session = DatabaseSession(parameters: parameters(secret: "tunnelpass"))
        try await session.connect()
        let result = try await session.execute("SELECT current_database()")
        #expect(result[0].rows == [[.text("foxlume")]])
        await session.close()
    }

    @Test(.enabled(if: available)) func wrongPassphraseReportsSSHFailure() async throws {
        let session = DatabaseSession(parameters: parameters(secret: "wrong"))
        do {
            try await session.connect()
            Issue.record("Connected with a wrong passphrase")
        } catch {
            #expect(error.localizedDescription.contains("SSH tunnel"))
        }
    }
}
