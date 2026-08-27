import CryptoKit
import JavaScriptCore
import Security

// MARK: - Installer

public struct JSCryptoInstaller: JSContextInstallable {
  public func install(in context: JSContext) throws {
    let randomUUID: @convention(block) () -> String = { "\(UUID())".lowercased() }
    let randomBytes: @convention(block) (Int) -> [UInt8] = { self.randomBytes(count: $0) }
    context.setObject(randomUUID, forPath: "_jsCoreExtrasRandomUUID")
    context.setObject(randomBytes, forPath: "_jsCoreExtrasRandomBytes")

    let subtleDigest: @convention(block) (JSValue) -> JSValue? = { dataValue in
      guard let ctx = JSContext.current() else { return nil }
      let bytes = Self.jsValueToBytes(dataValue, context: ctx)
      guard let data = bytes else {
        ctx.exception = JSValue(newErrorFromMessage: "Subtle digest: invalid data", in: ctx)
        return nil
      }
      let hash = SHA256.hash(data: Data(data))
      return JSValue(object: Array(hash), in: ctx)
    }
    context.setObject(subtleDigest, forPath: "_jsCoreExtrasSubtleDigest")

    let subtleDecrypt: @convention(block) (JSValue, JSValue, JSValue) -> JSValue? = { keyValue, ivValue, dataValue in
      guard let ctx = JSContext.current() else { return nil }
      guard let keyBytes = Self.jsValueToBytes(keyValue, context: ctx),
            let ivBytes = Self.jsValueToBytes(ivValue, context: ctx),
            let dataBytes = Self.jsValueToBytes(dataValue, context: ctx) else {
        ctx.exception = JSValue(newErrorFromMessage: "Subtle decrypt: invalid arguments", in: ctx)
        return nil
      }
      guard ivBytes.count == 12 else {
        ctx.exception = JSValue(newErrorFromMessage: "Subtle decrypt: IV must be 12 bytes", in: ctx)
        return nil
      }
      guard dataBytes.count >= 16 else {
        ctx.exception = JSValue(newErrorFromMessage: "Subtle decrypt: ciphertext too short", in: ctx)
        return nil
      }
      let tag = Data(dataBytes.suffix(16))
      let ciphertext = Data(dataBytes.prefix(dataBytes.count - 16))
      do {
        let nonce = try AES.GCM.Nonce(data: Data(ivBytes))
        let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        let key = SymmetricKey(data: Data(keyBytes))
        let plain = try AES.GCM.open(sealedBox, using: key)
        return JSValue(object: Array(plain), in: ctx)
      } catch {
        ctx.exception = JSValue(newErrorFromMessage: "Subtle decrypt failed: \(error.localizedDescription)", in: ctx)
        return nil
      }
    }
    context.setObject(subtleDecrypt, forPath: "_jsCoreExtrasSubtleDecrypt")

    try context.install([.jsCoreExtrasBundled(path: "Crypto.js")])
  }

  private func randomBytes(count: Int) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: count)
    let result = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    if result != errSecSuccess {
      let errorMessage =
        SecCopyErrorMessageString(result, nil) as? String ?? "Unknown Security Framework Error"
      JSContext.current()?.exception = JSValue(
        newErrorFromMessage: errorMessage,
        in: .current()
      )
    }
    return bytes
  }

  private static func jsValueToBytes(_ value: JSValue, context: JSContext) -> [UInt8]? {
    if value.isArray {
      guard let array = value.toArray() as? [NSNumber] else { return nil }
      return array.map { UInt8(truncatingIfNeeded: $0.intValue) }
    }
    if value.isObject {
      if let buffer = value.objectForKeyedSubscript("buffer"), !buffer.isUndefined, !buffer.isNull {
        // TypedArray: try to get length and indexed values
        if let lengthVal = value.objectForKeyedSubscript("length"), lengthVal.isNumber {
          let length = Int(lengthVal.toInt32())
          var bytes: [UInt8] = []
          bytes.reserveCapacity(length)
          for i in 0..<length {
            if let el = value.objectAtIndexedSubscript(i), el.isNumber {
              bytes.append(UInt8(truncatingIfNeeded: el.toInt32()))
            } else {
              return nil
            }
          }
          return bytes
        }
      }
      // Fallback: try to convert via toArray for array-like
      if let arr = value.toArray() as? [NSNumber] {
        return arr.map { UInt8(truncatingIfNeeded: $0.intValue) }
      }
    }
    return nil
  }
}

extension JSContextInstallable where Self == JSCryptoInstaller {
  /// An installable that installs web browser crypto operations.
  public static var crypto: Self { JSCryptoInstaller() }
}
