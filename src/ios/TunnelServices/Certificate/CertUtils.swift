import Foundation
import NIO
import CNIOBoringSSL
import NIOSSL

public class CertUtils: NSObject {
    public static func generateRSAPrivateKey() -> OpaquePointer {
        guard let exponent = CNIOBoringSSL_BN_new() else {
            fatalError("Unable to allocate RSA exponent")
        }
        defer { CNIOBoringSSL_BN_free(exponent) }

        CNIOBoringSSL_BN_set_u64(exponent, 0x10001)

        guard let rsa = CNIOBoringSSL_RSA_new() else {
            fatalError("Unable to allocate RSA key")
        }

        let generateRC = CNIOBoringSSL_RSA_generate_key_ex(rsa, CInt(2048), exponent, nil)
        precondition(generateRC == 1)

        guard let pkey = CNIOBoringSSL_EVP_PKEY_new() else {
            CNIOBoringSSL_RSA_free(rsa)
            fatalError("Unable to allocate EVP_PKEY")
        }

        let assignRC = CNIOBoringSSL_EVP_PKEY_assign_RSA(pkey, rsa)
        precondition(assignRC == 1)
        return pkey
    }

    public static func generateCert(
        host: String,
        rsaKey: NIOSSLPrivateKey,
        caKey: NIOSSLPrivateKey,
        caCert: NIOSSLCertificate
    ) -> NIOSSLCertificate {
        do {
            let caKeyRef = try makeEVPPrivateKey(fromDER: caKey.derBytes)
            defer { CNIOBoringSSL_EVP_PKEY_free(caKeyRef) }

            let keyRef = try makeEVPPrivateKey(fromDER: rsaKey.derBytes)
            defer { CNIOBoringSSL_EVP_PKEY_free(keyRef) }

            let caCertRef = try makeX509(fromDER: caCert.toDERBytes())
            defer { CNIOBoringSSL_X509_free(caCertRef) }

            guard let name = CNIOBoringSSL_X509_NAME_new() else {
                throw NSError(domain: "CertUtils", code: -1)
            }
            defer { CNIOBoringSSL_X509_NAME_free(name) }

            addNameEntry(name: name, key: "C", value: "SE")
            addNameEntry(name: name, key: "ST", value: "")
            addNameEntry(name: name, key: "L", value: "")
            addNameEntry(name: name, key: "O", value: "PacketHound")
            addNameEntry(name: name, key: "OU", value: "")
            addNameEntry(name: name, key: "CN", value: host)

            guard let crt = CNIOBoringSSL_X509_new() else {
                throw NSError(domain: "CertUtils", code: -2)
            }
            defer { CNIOBoringSSL_X509_free(crt) }

            CNIOBoringSSL_X509_set_version(crt, 2)
            let serial = Int.random(in: 1...Int(Int32.max))
            CNIOBoringSSL_ASN1_INTEGER_set(CNIOBoringSSL_X509_get_serialNumber(crt), serial)

            guard let issuerName = CNIOBoringSSL_X509_get_subject_name(caCertRef) else {
                throw NSError(domain: "CertUtils", code: -3)
            }
            CNIOBoringSSL_X509_set_issuer_name(crt, issuerName)

            guard
                let notBefore = CNIOBoringSSL_ASN1_TIME_new(),
                let notAfter = CNIOBoringSSL_ASN1_TIME_new()
            else {
                throw NSError(domain: "CertUtils", code: -4)
            }
            defer {
                CNIOBoringSSL_ASN1_TIME_free(notBefore)
                CNIOBoringSSL_ASN1_TIME_free(notAfter)
            }

            var now = time(nil)
            CNIOBoringSSL_ASN1_TIME_set(notBefore, now)
            now += 86400 * 365
            CNIOBoringSSL_ASN1_TIME_set(notAfter, now)
            CNIOBoringSSL_X509_set_notBefore(crt, notBefore)
            CNIOBoringSSL_X509_set_notAfter(crt, notAfter)

            CNIOBoringSSL_X509_set_subject_name(crt, name)
            CNIOBoringSSL_X509_set_pubkey(crt, keyRef)

            addExtension(x509: crt, nid: NID_basic_constraints, value: "critical,CA:FALSE")
            addExtension(x509: crt, nid: NID_ext_key_usage, value: "serverAuth,OCSPSigning")
            addExtension(x509: crt, nid: NID_subject_key_identifier, value: "hash")

            let sanPrefix = host.isIPAddress() ? "IP:" : "DNS:"
            addExtension(x509: crt, nid: NID_subject_alt_name, value: sanPrefix + host)

            CNIOBoringSSL_X509_sign(crt, caKeyRef, CNIOBoringSSL_EVP_sha256())

            let certDER = try derBytes(fromX509: crt)
            return try NIOSSLCertificate(bytes: certDER, format: .der)
        } catch {
            AxLogger.log("Dynamic cert generation failed for \(host): \(error.localizedDescription)", level: .Error)
            return caCert
        }
    }

    public static func addExtension(x509: OpaquePointer, nid: CInt, value: String) {
        var extensionContext = X509V3_CTX()
        CNIOBoringSSL_X509V3_set_ctx(&extensionContext, x509, x509, nil, nil, 0)

        value.withCString { pointer in
            let mutablePointer = UnsafeMutablePointer(mutating: pointer)
            if let ext = CNIOBoringSSL_X509V3_EXT_nconf_nid(nil, &extensionContext, nid, mutablePointer) {
                CNIOBoringSSL_X509_add_ext(x509, ext, -1)
                CNIOBoringSSL_X509_EXTENSION_free(ext)
            }
        }
    }

    public static func pemBytes(fromPrivateKey key: OpaquePointer) throws -> [UInt8] {
        guard let bio = CNIOBoringSSL_BIO_new(CNIOBoringSSL_BIO_s_mem()) else {
            throw NSError(domain: "CertUtils", code: -10)
        }
        defer { CNIOBoringSSL_BIO_free(bio) }

        let rc = CNIOBoringSSL_PEM_write_bio_PrivateKey(bio, key, nil, nil, 0, nil, nil)
        guard rc == 1 else {
            throw NSError(domain: "CertUtils", code: -11)
        }

        return bioBytes(bio)
    }

    public static func pemBytes(fromX509 cert: OpaquePointer) throws -> [UInt8] {
        guard let bio = CNIOBoringSSL_BIO_new(CNIOBoringSSL_BIO_s_mem()) else {
            throw NSError(domain: "CertUtils", code: -12)
        }
        defer { CNIOBoringSSL_BIO_free(bio) }

        let rc = CNIOBoringSSL_PEM_write_bio_X509(bio, cert)
        guard rc == 1 else {
            throw NSError(domain: "CertUtils", code: -13)
        }

        return bioBytes(bio)
    }

    public static func derBytes(fromX509 cert: OpaquePointer) throws -> [UInt8] {
        guard let bio = CNIOBoringSSL_BIO_new(CNIOBoringSSL_BIO_s_mem()) else {
            throw NSError(domain: "CertUtils", code: -14)
        }
        defer { CNIOBoringSSL_BIO_free(bio) }

        let rc = CNIOBoringSSL_i2d_X509_bio(bio, cert)
        guard rc == 1 else {
            throw NSError(domain: "CertUtils", code: -15)
        }

        return bioBytes(bio)
    }

    public static func makeX509(fromDER bytes: [UInt8]) throws -> OpaquePointer {
        let cert = bytes.withUnsafeBytes { rawBuffer -> OpaquePointer? in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            var pointer: UnsafePointer<UInt8>? = baseAddress
            return CNIOBoringSSL_d2i_X509(nil, &pointer, rawBuffer.count)
        }

        guard let cert else {
            throw NSError(domain: "CertUtils", code: -16)
        }
        return cert
    }

    public static func makeEVPPrivateKey(fromDER bytes: [UInt8]) throws -> OpaquePointer {
        let key = bytes.withUnsafeBytes { rawBuffer -> OpaquePointer? in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            var pointer: UnsafePointer<UInt8>? = baseAddress
            return CNIOBoringSSL_d2i_AutoPrivateKey(nil, &pointer, rawBuffer.count)
        }

        guard let key else {
            throw NSError(domain: "CertUtils", code: -17)
        }
        return key
    }

    private static func addNameEntry(name: OpaquePointer, key: String, value: String) {
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

    private static func bioBytes(_ bio: UnsafeMutablePointer<BIO>) -> [UInt8] {
        var bytesPtr: UnsafeMutablePointer<CChar>? = nil
        let length = CNIOBoringSSL_BIO_get_mem_data(bio, &bytesPtr)
        guard let bytesPtr, length > 0 else {
            return []
        }

        let rawBuffer = UnsafeRawBufferPointer(start: bytesPtr, count: length)
        return Array(rawBuffer)
    }
}
