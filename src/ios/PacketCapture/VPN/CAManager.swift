import Foundation
import Security
import UIKit
import CNIOBoringSSL
import TunnelServices

enum CACertificateTrustState {
    case missing
    case generated
    case trusted
}

final class CAManager {
    static let shared = CAManager()

    private let appGroupIdentifier = "group.com.openminis.app"
    private let fileManager = FileManager.default

    private let certDirectoryName = "Cert"
    private let caCertPEMFileName = "cacert.pem"
    private let caCertDERFileName = "cacert.der"
    private let caKeyPEMFileName = "cakey.pem"
    private let rsaKeyPEMFileName = "rsakey.pem"

    private init() {}

    func initializeCertificateIfNeeded() {
        NSLog("[CAManager] initializeCertificateIfNeeded called")
        guard let certDirectoryURL = certificateDirectoryURL() else {
            NSLog("[CAManager] ERROR: certificateDirectoryURL() returned nil, appGroup=%@", appGroupIdentifier)
            let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            NSLog("[CAManager] containerURL=%@", groupURL?.absoluteString ?? "(nil)")
            return
        }

        NSLog("[CAManager] certDir=%@", certDirectoryURL.path)

        do {
            try fileManager.createDirectory(at: certDirectoryURL, withIntermediateDirectories: true, attributes: nil)

            let hasCerts = hasRequiredCertificates(in: certDirectoryURL)
            NSLog("[CAManager] hasRequiredCertificates=%d", hasCerts ? 1 : 0)
            if hasCerts {
                return
            }

            NSLog("[CAManager] generating new certificates...")
            try generateAndPersistCertificates(in: certDirectoryURL)
            NSLog("[CAManager] CA materials generated successfully")

            let verifyHas = hasRequiredCertificates(in: certDirectoryURL)
            NSLog("[CAManager] post-generation hasRequiredCertificates=%d", verifyHas ? 1 : 0)
        } catch {
            NSLog("[CAManager] ERROR: failed to initialize CA materials: %@", error.localizedDescription)
        }
    }

    func getCACertificateDERData() -> Data? {
        guard let certDirectoryURL = certificateDirectoryURL() else {
            NSLog("[CAManager] getCACertificateDERData: certDir is nil")
            return nil
        }
        let derURL = certDirectoryURL.appendingPathComponent(caCertDERFileName, isDirectory: false)
        NSLog("[CAManager] getCACertificateDERData: path=%@, exists=%d", derURL.path, fileManager.fileExists(atPath: derURL.path) ? 1 : 0)
        return try? Data(contentsOf: derURL)
    }

    func isCACertificateInstalledAndTrusted() -> Bool {
        guard
            let derData = getCACertificateDERData(),
            let secCertificate = SecCertificateCreateWithData(nil, derData as CFData)
        else {
            return false
        }

        var trust: SecTrust?
        let createStatus = SecTrustCreateWithCertificates(secCertificate, SecPolicyCreateBasicX509(), &trust)
        guard createStatus == errSecSuccess, let trust else {
            return false
        }

        if #available(iOS 13.0, *) {
            return SecTrustEvaluateWithError(trust, nil)
        }

        var result: SecTrustResultType = .invalid
        let evaluateStatus = SecTrustEvaluate(trust, &result)
        guard evaluateStatus == errSecSuccess else {
            return false
        }
        return result == .proceed || result == .unspecified
    }

    func certificateTrustState() -> CACertificateTrustState {
        guard
            let certDirectoryURL = certificateDirectoryURL(),
            hasRequiredCertificates(in: certDirectoryURL)
        else {
            return .missing
        }

        return isCACertificateInstalledAndTrusted() ? .trusted : .generated
    }

    private func certificateDirectoryURL() -> URL? {
        guard let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) else {
            return nil
        }

        return groupURL.appendingPathComponent(certDirectoryName, isDirectory: true)
    }

    private func hasRequiredCertificates(in certDirectoryURL: URL) -> Bool {
        let files = [caCertPEMFileName, caCertDERFileName, caKeyPEMFileName, rsaKeyPEMFileName]
        for fileName in files {
            let path = certDirectoryURL.appendingPathComponent(fileName, isDirectory: false).path
            let exists = fileManager.fileExists(atPath: path)
            NSLog("[CAManager] check file=%@ exists=%d", fileName, exists ? 1 : 0)
        }
        return files.allSatisfy { fileName in
            fileManager.fileExists(atPath: certDirectoryURL.appendingPathComponent(fileName, isDirectory: false).path)
        }
    }

    private func generateAndPersistCertificates(in certDirectoryURL: URL) throws {
        let caPrivateKey = CertUtils.generateRSAPrivateKey()
        defer { CNIOBoringSSL_EVP_PKEY_free(caPrivateKey) }

        let rsaPrivateKey = CertUtils.generateRSAPrivateKey()
        defer { CNIOBoringSSL_EVP_PKEY_free(rsaPrivateKey) }

        let caCertificate = try generateSelfSignedCACertificate(using: caPrivateKey)
        defer { CNIOBoringSSL_X509_free(caCertificate) }

        let caCertPEM = try CertUtils.pemBytes(fromX509: caCertificate)
        let caCertDER = try CertUtils.derBytes(fromX509: caCertificate)
        let caKeyPEM = try CertUtils.pemBytes(fromPrivateKey: caPrivateKey)
        let rsaKeyPEM = try CertUtils.pemBytes(fromPrivateKey: rsaPrivateKey)

        try Data(caCertPEM).write(to: certDirectoryURL.appendingPathComponent(caCertPEMFileName, isDirectory: false), options: .atomic)
        try Data(caCertDER).write(to: certDirectoryURL.appendingPathComponent(caCertDERFileName, isDirectory: false), options: .atomic)
        try Data(caKeyPEM).write(to: certDirectoryURL.appendingPathComponent(caKeyPEMFileName, isDirectory: false), options: .atomic)
        try Data(rsaKeyPEM).write(to: certDirectoryURL.appendingPathComponent(rsaKeyPEMFileName, isDirectory: false), options: .atomic)
    }

    private func generateSelfSignedCACertificate(using caPrivateKey: OpaquePointer) throws -> OpaquePointer {
        guard let name = CNIOBoringSSL_X509_NAME_new() else {
            throw NSError(domain: "CAManager", code: -1)
        }
        defer { CNIOBoringSSL_X509_NAME_free(name) }

        addNameEntry(name: name, key: "C", value: "SE")
        addNameEntry(name: name, key: "O", value: "PacketHound")
        addNameEntry(name: name, key: "CN", value: "PacketHound CA")

        guard let cert = CNIOBoringSSL_X509_new() else {
            throw NSError(domain: "CAManager", code: -2)
        }

        CNIOBoringSSL_X509_set_version(cert, 2)
        let serial = Int.random(in: 1...Int(Int32.max))
        CNIOBoringSSL_ASN1_INTEGER_set(CNIOBoringSSL_X509_get_serialNumber(cert), serial)

        guard
            let notBefore = CNIOBoringSSL_ASN1_TIME_new(),
            let notAfter = CNIOBoringSSL_ASN1_TIME_new()
        else {
            CNIOBoringSSL_X509_free(cert)
            throw NSError(domain: "CAManager", code: -3)
        }

        var now = time(nil)
        CNIOBoringSSL_ASN1_TIME_set(notBefore, now)
        now += 86400 * 365 * 10
        CNIOBoringSSL_ASN1_TIME_set(notAfter, now)
        CNIOBoringSSL_X509_set_notBefore(cert, notBefore)
        CNIOBoringSSL_X509_set_notAfter(cert, notAfter)
        CNIOBoringSSL_ASN1_TIME_free(notBefore)
        CNIOBoringSSL_ASN1_TIME_free(notAfter)

        CNIOBoringSSL_X509_set_subject_name(cert, name)
        CNIOBoringSSL_X509_set_issuer_name(cert, name)
        CNIOBoringSSL_X509_set_pubkey(cert, caPrivateKey)

        CertUtils.addExtension(x509: cert, nid: NID_basic_constraints, value: "critical,CA:TRUE")
        CertUtils.addExtension(x509: cert, nid: NID_key_usage, value: "critical,keyCertSign,cRLSign")
        CertUtils.addExtension(x509: cert, nid: NID_subject_key_identifier, value: "hash")

        let signRC = CNIOBoringSSL_X509_sign(cert, caPrivateKey, CNIOBoringSSL_EVP_sha256())
        guard signRC > 0 else {
            CNIOBoringSSL_X509_free(cert)
            throw NSError(domain: "CAManager", code: -4)
        }

        return cert
    }

    // MARK: - 安装证书到系统（通过 Safari 下载 .cer 证书）
    
    private var _localServer: GCDHTTPServer?
    
    /// 启动本地 HTTP 服务器并跳转 Safari 下载 DER 证书
    func installCertificateViaSafari() {
        guard getCACertificateDERData() != nil else {
            NSLog("[CAManager] installCertificateViaSafari: no DER data")
            return
        }
        
        stopLocalServer()
        
        let server = GCDHTTPServer(port: 0) { [weak self] in
            return self?.getCACertificateDERData()
        }
        
        guard let port = server.start() else {
            NSLog("[CAManager] failed to start local HTTP server")
            return
        }
        
        _localServer = server
        NSLog("[CAManager] local server started on port %d", port)
        
        // 跳转 Safari 下载 .cer 证书
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let url = URL(string: "http://127.0.0.1:\(port)/ca.cer") {
                UIApplication.shared.open(url)
            }
        }
        
        // 60 秒后自动关闭服务器
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            self?.stopLocalServer()
        }
    }
    
    func stopLocalServer() {
        _localServer?.stop()
        _localServer = nil
    }

    private func addNameEntry(name: OpaquePointer, key: String, value: String) {
        key.withCString { keyPtr in
            value.utf8CString.withUnsafeBufferPointer { valueBuffer in
                guard let valuePtr = valueBuffer.baseAddress else {
                    return
                }
                let unsignedValue = UnsafeRawPointer(valuePtr).assumingMemoryBound(to: UInt8.self)
                CNIOBoringSSL_X509_NAME_add_entry_by_txt(
                    name,
                    keyPtr,
                    MBSTRING_ASC,
                    unsignedValue,
                    -1,
                    -1,
                    0
                )
            }
        }
    }
}
