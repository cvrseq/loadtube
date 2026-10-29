import Foundation
import CommonCrypto

/// Расшифровка Tidal:
/// 1. security token (base64) расшифровывается AES-128-CBC мастер-ключом;
/// 2. из него получаются 16-байтовый ключ и 8-байтовый nonce;
/// 3. сам FLAC/M4A расшифровывается AES-128-CTR (nonce + 64-битный счётчик).
enum TidalCrypto {
    static func securityToken(_ token: String) throws -> (key: Data, nonce: Data) {
        guard let masterKey = Data(base64Encoded: TidalConfig.masterKeyBase64) else {
            throw TidalError.decryptionFailed
        }
        var normalized = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        guard let decoded = Data(base64Encoded: normalized, options: .ignoreUnknownCharacters),
              decoded.count > 16 else {
            throw TidalError.decryptionFailed
        }

        let iv = decoded.prefix(16)
        let encrypted = decoded.dropFirst(16)
        let decrypted = try aesCBCDecrypt(key: masterKey, iv: Data(iv), data: Data(encrypted))

        guard decrypted.count >= 24 else { throw TidalError.decryptionFailed }
        return (
            key: decrypted.prefix(16),
            nonce: decrypted.subdata(in: 16..<24)
        )
    }

    static func decryptFile(
        input: URL,
        output: URL,
        key: Data,
        nonce: Data,
        progress: ((Double) -> Void)? = nil
    ) throws {
        guard key.count == kCCKeySizeAES128, nonce.count == 8 else {
            throw TidalError.decryptionFailed
        }

        let fm = FileManager.default
        try? fm.removeItem(at: output)
        guard fm.createFile(atPath: output.path, contents: nil) else {
            throw TidalError.decryptionFailed
        }

        let inputHandle = try FileHandle(forReadingFrom: input)
        let outputHandle = try FileHandle(forWritingTo: output)
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
        }

        let total = (try? fm.attributesOfItem(atPath: input.path)[.size] as? Int64) ?? 0
        var processed: Int64 = 0
        var cryptor: CCCryptorRef?
        var counter = Data(nonce)
        counter.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])

        let createStatus = counter.withUnsafeBytes { ivBuffer in
            key.withUnsafeBytes { keyBuffer in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBuffer.baseAddress,
                    keyBuffer.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw TidalError.decryptionFailed
        }
        defer { CCCryptorRelease(cryptor) }

        let chunkSize = 1_048_576
        while true {
            let chunk = try inputHandle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }

            var output = Data(count: chunk.count + kCCBlockSizeAES128)
            var moved = 0
            let status = output.withUnsafeMutableBytes { outputBuffer in
                chunk.withUnsafeBytes { inputBuffer in
                    CCCryptorUpdate(
                        cryptor,
                        inputBuffer.baseAddress,
                        chunk.count,
                        outputBuffer.baseAddress,
                        outputBuffer.count,
                        &moved
                    )
                }
            }
            guard status == kCCSuccess else { throw TidalError.decryptionFailed }
            if moved > 0 {
                try outputHandle.write(contentsOf: output.prefix(moved))
            }

            processed += Int64(chunk.count)
            if total > 0 {
                progress?(min(Double(processed) / Double(total), 1))
            }
        }

        var final = Data(count: kCCBlockSizeAES128)
        var finalMoved = 0
        let finalStatus = final.withUnsafeMutableBytes { buffer in
            CCCryptorFinal(
                cryptor,
                buffer.baseAddress,
                buffer.count,
                &finalMoved
            )
        }
        guard finalStatus == kCCSuccess else { throw TidalError.decryptionFailed }
        if finalMoved > 0 {
            try outputHandle.write(contentsOf: final.prefix(finalMoved))
        }

        progress?(1)
    }

    private static func aesCBCDecrypt(key: Data, iv: Data, data: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outputBuffer in
            data.withUnsafeBytes { dataBuffer in
                iv.withUnsafeBytes { ivBuffer in
                    key.withUnsafeBytes { keyBuffer in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyBuffer.baseAddress,
                            key.count,
                            ivBuffer.baseAddress,
                            dataBuffer.baseAddress,
                            data.count,
                            outputBuffer.baseAddress,
                            outputBuffer.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw TidalError.decryptionFailed }
        return output.prefix(moved)
    }
}
