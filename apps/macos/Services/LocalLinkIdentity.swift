import CryptoKit
import Foundation
import Security

enum LocalLinkIdentityError: LocalizedError {
    case entropy
    case keychain(OSStatus)
    case certificateGeneration(String)
    case importFailure(OSStatus)
    case missingCertificate

    var errorDescription: String? {
        switch self {
        case .entropy: "Could not create a secure pairing secret."
        case .keychain(let status): "Could not access the local-link Keychain secret (\(status))."
        case .certificateGeneration(let text): "Could not create the local TLS identity: \(text)"
        case .importFailure(let status): "Could not import the local TLS identity (\(status))."
        case .missingCertificate: "The local TLS identity has no certificate."
        }
    }
}

struct LocalLinkIdentity {
    let identity: SecIdentity
    let leafSHA256: String

    private static let service = "io.materiallab.desktop.local-link"
    private static let account = "pkcs12-passphrase"
    private static var folder: URL {
        MaterialLibrary.appSupport.appendingPathComponent("LinkIdentity", isDirectory: true)
    }
    private static var p12URL: URL { folder.appendingPathComponent("identity.p12") }

    static func loadOrCreate() throws -> LocalLinkIdentity {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let password: String
        if FileManager.default.fileExists(atPath: p12URL.path) {
            guard let saved = try loadPassword() else {
                throw LocalLinkIdentityError.certificateGeneration(
                    "The certificate exists but its Keychain passphrase is missing. Reset device trust to create a new identity."
                )
            }
            password = saved
        } else {
            password = try randomSecret()
            // Save the passphrase before the archive becomes visible, so a crash never leaves
            // an identity.p12 whose passphrase is missing from the Keychain.
            try generateIdentity(password: password) { try savePassword(password) }
        }
        let bytes = try Data(contentsOf: p12URL)
        var items: CFArray?
        let status = SecPKCS12Import(
            bytes as CFData,
            [
                kSecImportExportPassphrase as String: password,
                // Keep the private key in process memory; avoids accumulating copies in the login keychain.
                kSecImportToMemoryOnly as String: true
            ] as CFDictionary,
            &items
        )
        guard status == errSecSuccess,
              let record = (items as? [[String: Any]])?.first,
              let identityObject = record[kSecImportItemIdentity as String]
        else { throw LocalLinkIdentityError.importFailure(status) }
        let identity = identityObject as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate
        else { throw LocalLinkIdentityError.missingCertificate }
        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        return LocalLinkIdentity(identity: identity, leafSHA256: fingerprint)
    }

    static func reset() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LocalLinkIdentityError.keychain(status)
        }
        if FileManager.default.fileExists(atPath: p12URL.path) {
            try FileManager.default.removeItem(at: p12URL)
        }
    }

    static func randomSecret() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalLinkIdentityError.entropy
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func loadPassword() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let text = String(data: data, encoding: .utf8)
        else { throw LocalLinkIdentityError.keychain(status) }
        return text
    }

    private static func savePassword(_ password: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(password.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let selector: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let update: [String: Any] = [kSecValueData as String: Data(password.utf8)]
            let updated = SecItemUpdate(selector as CFDictionary, update as CFDictionary)
            guard updated == errSecSuccess else { throw LocalLinkIdentityError.keychain(updated) }
        } else if status != errSecSuccess {
            throw LocalLinkIdentityError.keychain(status)
        }
    }

    private static func generateIdentity(password: String, beforeInstall: () throws -> Void) throws {
        let fm = FileManager.default
        let temp = folder.appendingPathComponent(".create-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: temp, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? fm.removeItem(at: temp) }
        let key = temp.appendingPathComponent("key.pem")
        let cert = temp.appendingPathComponent("cert.pem")
        let pass = temp.appendingPathComponent("pass.txt")
        let archive = temp.appendingPathComponent("identity.p12")
        try Data(password.utf8).write(to: pass, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pass.path)
        try runOpenSSL([
            "req", "-newkey", "rsa:3072",
            "-x509", "-sha256", "-days", "3650", "-nodes",
            "-subj", "/CN=Material Lab Local Link",
            "-keyout", key.path, "-out", cert.path
        ])
        try runOpenSSL([
            "pkcs12", "-export", "-inkey", key.path, "-in", cert.path,
            "-out", archive.path, "-passout", "file:\(pass.path)"
        ])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: archive.path)
        try beforeInstall()
        try fm.moveItem(at: archive, to: p12URL)
    }

    private static func runOpenSSL(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            throw LocalLinkIdentityError.certificateGeneration(
                String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "openssl exited with \(process.terminationStatus)"
            )
        }
    }
}
