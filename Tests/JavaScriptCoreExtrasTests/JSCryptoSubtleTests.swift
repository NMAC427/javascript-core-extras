import CryptoKit
import JavaScriptCore
import JavaScriptCoreExtras
import Testing

@Suite("JSCrypto subtle tests")
struct JSCryptoSubtleTests {
  private let context: JSContext

  init() throws {
    let ctx = JSContext()!
    try ctx.install([.crypto])
    // Minimal TextDecoder polyfill for tests that need it
    ctx.evaluateScript("""
      if (typeof TextDecoder === 'undefined') {
        globalThis.TextDecoder = class {
          decode(buf) {
            const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
            let binary = "";
            for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
            try { return decodeURIComponent(escape(binary)); } catch { return binary; }
          }
        };
      }
      if (typeof TextEncoder === 'undefined') {
        globalThis.TextEncoder = class {
          encode(str) { return Uint8Array.from(unescape(encodeURIComponent(str)), c => c.charCodeAt(0)); }
        };
      }
    """)
    self.context = ctx
  }

  @Test("crypto.subtle exists")
  func subtleExists() {
    let hasSubtle = context.evaluateScript("typeof crypto.subtle === 'object'")?.toBool()
    #expect(hasSubtle == true)
    let hasDigest = context.evaluateScript("typeof crypto.subtle.digest === 'function'")?.toBool()
    #expect(hasDigest == true)
    let hasDecrypt = context.evaluateScript("typeof crypto.subtle.decrypt === 'function'")?.toBool()
    #expect(hasDecrypt == true)
    let hasImport = context.evaluateScript("typeof crypto.subtle.importKey === 'function'")?.toBool()
    #expect(hasImport == true)
  }

  @Test("SHA-256 digest of empty string")
  func digestEmpty() async throws {
    let value = context.evaluateScript("""
      crypto.subtle.digest("SHA-256", new Uint8Array([])).then(b => Array.from(new Uint8Array(b)).map(x=>x.toString(16).padStart(2,'0')).join(''))
      """)?.toPromise()
    let resolved = try await value?.resolvedValue
    let hex = resolved?.toString()
    #expect(hex == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
  }

  @Test("SHA-256 digest of hello")
  func digestHello() async throws {
    let value = context.evaluateScript("""
      crypto.subtle.digest("SHA-256", new Uint8Array([104,101,108,108,111])).then(b => Array.from(new Uint8Array(b)).map(x=>x.toString(16).padStart(2,'0')).join(''))
      """)?.toPromise()
    let resolved = try await value?.resolvedValue
    let hex = resolved?.toString()
    #expect(hex == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
  }

  @Test("SHA-256 digest via object algorithm")
  func digestObjectAlgo() async throws {
    let value = context.evaluateScript("""
      crypto.subtle.digest({name:"SHA-256"}, new TextEncoder().encode("abc")).then(b => Array.from(new Uint8Array(b)).map(x=>x.toString(16).padStart(2,'0')).join(''))
      """)?.toPromise()
    let resolved = try await value?.resolvedValue
    let hex = resolved?.toString()
    #expect(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  }

  @Test("SHA-256 rejects unsupported algorithm")
  func digestUnsupported() async throws {
    let value = context.evaluateScript("""
      crypto.subtle.digest("SHA-512", new Uint8Array([1,2,3]))
      """)?.toPromise()
    do {
      _ = try await value?.resolvedValue
      Issue.record("Expected promise to reject for unsupported algorithm")
    } catch let error as JSPromiseRejectedError {
      let msg = error.reason.objectForKeyedSubscript("message")?.toString() ?? ""
      #expect(msg.contains("Only SHA-256"))
    }
  }

  @Test("AES-GCM decrypt round-trip via CryptoKit")
  func aesGcmDecrypt() async throws {
    // Generate a deterministic key/iv/plaintext via CryptoKit, then verify JS can decrypt.
    let keyBytes: [UInt8] = Array(0..<32).map { UInt8($0) }
    let iv: [UInt8] = Array(0..<12).map { UInt8($0 + 1) }
    let plaintext = "StreamEx test payload".data(using: .utf8)!
    let key = SymmetricKey(data: Data(keyBytes))
    let nonce = try AES.GCM.Nonce(data: Data(iv))
    let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
    let ciphertextAndTag = sealed.ciphertext + sealed.tag
    let ctArray = Array(ciphertextAndTag)

    let keyJS = keyBytes.map(String.init).joined(separator: ",")
    let ivJS = iv.map(String.init).joined(separator: ",")
    let ctJS = ctArray.map(String.init).joined(separator: ",")

    let script = """
      (async () => {
        const keyBytes = new Uint8Array([\(keyJS)]);
        const iv = new Uint8Array([\(ivJS)]);
        const ct = new Uint8Array([\(ctJS)]);
        const key = await crypto.subtle.importKey("raw", keyBytes, {name:"AES-GCM"}, false, ["decrypt"]);
        const plain = await crypto.subtle.decrypt({name:"AES-GCM", iv}, key, ct);
        return Array.from(new Uint8Array(plain));
      })()
      """
    let value = context.evaluateScript(script)?.toPromise()
    let resolved = try await value?.resolvedValue
    let result = resolved?.toArray() as? [NSNumber]
    let resultBytes = result?.compactMap { $0 as? UInt8 } ?? []
    #expect(Data(resultBytes) == plaintext)
  }

  @Test("AES-GCM decrypt with TextDecoder")
  func aesGcmDecryptText() async throws {
    let keyBytes: [UInt8] = Array(repeating: 0x42, count: 32)
    let iv: [UInt8] = Array(repeating: 0x24, count: 12)
    let plaintext = #"{"name":"TIK 1","url":"/mdata/test"}"#.data(using: .utf8)!
    let key = SymmetricKey(data: Data(keyBytes))
    let nonce = try AES.GCM.Nonce(data: Data(iv))
    let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
    let ct = Array(sealed.ciphertext + sealed.tag)

    let keyJS = keyBytes.map(String.init).joined(separator: ",")
    let ivJS = iv.map(String.init).joined(separator: ",")
    let ctJS = ct.map(String.init).joined(separator: ",")

    let script = """
      (async () => {
        const keyBytes = new Uint8Array([\(keyJS)]);
        const iv = new Uint8Array([\(ivJS)]);
        const ct = new Uint8Array([\(ctJS)]);
        const key = await crypto.subtle.importKey("raw", keyBytes, {name:"AES-GCM"}, false, ["decrypt"]);
        const plain = await crypto.subtle.decrypt({name:"AES-GCM", iv}, key, ct);
        return new TextDecoder().decode(plain);
      })()
      """
    let value = context.evaluateScript(script)?.toPromise()
    let resolved = try await value?.resolvedValue
    #expect(resolved?.toString() == #"{"name":"TIK 1","url":"/mdata/test"}"#)
  }

  @Test("AES-GCM decrypt rejects without iv")
  func decryptMissingIV() async throws {
    let value = context.evaluateScript("""
      (async () => {
        const key = await crypto.subtle.importKey("raw", new Uint8Array(32), {name:"AES-GCM"}, false, ["decrypt"]);
        return crypto.subtle.decrypt({name:"AES-GCM"}, key, new Uint8Array(16));
      })()
      """)?.toPromise()
    do {
      _ = try await value?.resolvedValue
      Issue.record("Expected decrypt to reject when iv missing")
    } catch let error as JSPromiseRejectedError {
      let msg = error.reason.objectForKeyedSubscript("message")?.toString() ?? ""
      #expect(msg.contains("Missing iv") || msg.contains("Only AES-GCM"))
    }
  }

  @Test("AES-GCM decrypt fails on tampered ciphertext")
  func decryptTampered() async throws {
    let keyBytes: [UInt8] = Array(repeating: 0x01, count: 32)
    let iv: [UInt8] = Array(repeating: 0x02, count: 12)
    let plaintext = "tamper test".data(using: .utf8)!
    let key = SymmetricKey(data: Data(keyBytes))
    let nonce = try AES.GCM.Nonce(data: Data(iv))
    let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce)
    var ct = Array(sealed.ciphertext + sealed.tag)
    ct[0] ^= 0xFF // tamper

    let keyJS = keyBytes.map(String.init).joined(separator: ",")
    let ivJS = iv.map(String.init).joined(separator: ",")
    let ctJS = ct.map(String.init).joined(separator: ",")

    let script = """
      (async () => {
        const key = await crypto.subtle.importKey("raw", new Uint8Array([\(keyJS)]), {name:"AES-GCM"}, false, ["decrypt"]);
        return crypto.subtle.decrypt({name:"AES-GCM", iv: new Uint8Array([\(ivJS)])}, key, new Uint8Array([\(ctJS)]));
      })()
      """
    let value = context.evaluateScript(script)?.toPromise()
    do {
      _ = try await value?.resolvedValue
      Issue.record("Expected decrypt to reject on tampered data")
    } catch is JSPromiseRejectedError {
      // Expected
    }
  }
}
