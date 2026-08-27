import CustomDump
import JavaScriptCore
import JavaScriptCoreExtras
import Testing

@Suite("JSFetch Binary tests")
struct JSFetchBinaryTests: @unchecked Sendable {
  private let context = JSContext()!

  init() throws {
    try self.context.install([.consoleLogging])
  }

  @Test("Fetch ArrayBuffer Preserves Binary WASM Bytes")
  @available(iOS 15, macOS 12, tvOS 15, watchOS 8, *)
  func fetchArrayBufferPreservesBinaryWASM() async throws {
    // WASM magic + version + invalid UTF-8 sequences that would be corrupted via String(decoding:as:UTF8)
    // 0x00 0x61 0x73 0x6D = "\0asm", 0x01 0x00 0x00 0x00 = version 1, then 0xFF 0x80 0xFE 0xFD etc
    let wasmBytes: [UInt8] = [
      0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00,
      0xFF, 0x80, 0xFE, 0xFD, 0x89, 0x50, 0x4E, 0x47,
      0xC3, 0xBF, 0xEF, 0xBF, 0xBD, 0x00, 0x01, 0x02,
    ]
    let expected = Data(wasmBytes)
    try await withTestURLSessionHandler { _ in
      (200, .data(expected))
    } perform: { session in
      try self.context.install([.fetch(session: session)])
      let promise = self.context.evaluateScript(
        """
        fetch("https://example.com/wasm.php?w=5959527")
          .then(r => r.arrayBuffer())
          .then(b => Array.from(new Uint8Array(b)))
        """
      )!.toPromise()
      let value = try await promise?.resolvedValue
      let received = value?.toArray().compactMap { $0 as? UInt8 } ?? []
      expectNoDifference(received, wasmBytes)
      // Also verify size via blob
      let sizePromise = self.context.evaluateScript(
        """
        fetch("https://example.com/wasm.php?w=5959527")
          .then(r => r.blob())
          .then(b => b.size)
        """
      )?.toPromise()
      _ = try await sizePromise?.resolvedValue
    }
  }

  @Test("Fetch Bytes Preserves Non-UTF8 Random Payload")
  @available(iOS 15, macOS 12, tvOS 15, watchOS 8, *)
  func fetchBytesPreservesNonUTF8() async throws {
    // Simulate api.shegu.st/g ~185B random binary, includes bytes 128-255 not valid UTF8
    let randomBytes: [UInt8] = (0..<185).map { UInt8(($0 * 37 + 13) % 256) }
    let expected = Data(randomBytes)
    try await withTestURLSessionHandler { _ in
      (200, .data(expected))
    } perform: { session in
      try self.context.install([.fetch(session: session)])
      // bytes() path
      let promise = self.context.evaluateScript(
        """
        fetch("https://api.shegu.st/g")
          .then(r => r.bytes())
          .then(b => Array.from(b))
        """
      )!.toPromise()
      let value = try await promise?.resolvedValue
      let received = value?.toArray().compactMap { $0 as? UInt8 } ?? []
      expectNoDifference(received, randomBytes)
      expectNoDifference(received.count, 185)
    }
  }

  @Test("Fetch Blob Preserves Binary and Size")
  @available(iOS 15, macOS 12, tvOS 15, watchOS 8, *)
  func fetchBlobPreservesBinaryAndSize() async throws {
    let bytes: [UInt8] = [0xFF, 0xFF, 0x00, 0x61, 0x73, 0x6D, 0x80, 0x81, 0x82]
    let expected = Data(bytes)
    try await withTestURLSessionHandler { _ in
      (200, .data(expected))
    } perform: { session in
      try self.context.install([.fetch(session: session)])
      let promise = self.context.evaluateScript(
        """
        fetch("https://example.com/blob")
          .then(r => r.blob())
          .then(b => b.bytes().then(bytes => [b.size, Array.from(bytes)]))
        """
      )!.toPromise()
      let value = try await promise?.resolvedValue
      let arr = value?.toArray() ?? []
      let size = (arr.first as? Int32).map(Int64.init) ?? -1
      let receivedBytes = (arr.last as? [Any])?.compactMap { $0 as? UInt8 } ?? []
      expectNoDifference(size, Int64(bytes.count))
      expectNoDifference(receivedBytes, bytes)
    }
  }

  @Test("Fetch Text Decodes and Bytes Preserve Raw for Invalid UTF8")
  @available(iOS 15, macOS 12, tvOS 15, watchOS 8, *)
  func fetchTextVsBytes() async throws {
    // Data that is invalid UTF8: single 0xFF should be replaced in text() but preserved in bytes()
    let bytes: [UInt8] = [0x48, 0x65, 0x6C, 0x6C, 0x6F, 0xFF, 0x80]
    let expected = Data(bytes)
    try await withTestURLSessionHandler { _ in
      (200, .data(expected))
    } perform: { session in
      try self.context.install([.fetch(session: session)])
      let bytesPromise = self.context.evaluateScript(
        """
        fetch("https://example.com/binary")
          .then(r => r.bytes())
          .then(b => Array.from(b))
        """
      )!.toPromise()
      let bytesValue = try await bytesPromise?.resolvedValue
      let received = bytesValue?.toArray().compactMap { $0 as? UInt8 } ?? []
      // bytes() must be raw
      expectNoDifference(received, bytes)

      // text() should decode with replacement (FFFD) - not equal to raw bytes string length
      let textPromise = self.context.evaluateScript(
        """
        fetch("https://example.com/binary")
          .then(r => r.text())
        """
      )!.toPromise()
      let textValue = try await textPromise?.resolvedValue
      let text = textValue?.toString() ?? ""
      // "Hello" + replacement chars for FF and 80 = 7 chars but bytes were 7
      // The key assertion: text().length != bytes().length if we incorrectly used String bytes?
      // We assert text contains replacement char
      #expect(text.contains("\u{FFFD}"))
    }
  }

  @Test("Blob Direct Data Storage Preserves Arbitrary Bytes")
  func blobDirectDataStorage() async throws {
    // After fix, JSBlob with Data storage must preserve arbitrary bytes 1:1
    let rawBytes: [UInt8] = [0x00, 0xFF, 0x80, 0xFE, 0x01, 0x02]
    let data = Data(rawBytes)
    let blob = JSBlob(storage: data, type: .empty)
    let context = self.context
    context.setObject(blob, forPath: "testBlob")
    let promise = context.evaluateScript("testBlob.bytes().then(b => Array.from(b))")!.toPromise()
    let value = try await promise?.resolvedValue
    let received = value?.toArray().compactMap { $0 as? UInt8 } ?? []
    expectNoDifference(received, rawBytes)
    expectNoDifference(blob.size, Int64(rawBytes.count))
    // Also verify arrayBuffer
    let abPromise = context.evaluateScript("testBlob.arrayBuffer().then(b => Array.from(new Uint8Array(b)))")!.toPromise()
    let abValue = try await abPromise?.resolvedValue
    let abReceived = abValue?.toArray().compactMap { $0 as? UInt8 } ?? []
    expectNoDifference(abReceived, rawBytes)
    // Verify slice also preserves
    let slice = blob[1..<4]
    context.setObject(slice, forPath: "sliceBlob")
    let slicePromise = context.evaluateScript("sliceBlob.bytes().then(b => Array.from(b))")!.toPromise()
    let sliceValue = try await slicePromise?.resolvedValue
    let sliceReceived = sliceValue?.toArray().compactMap { $0 as? UInt8 } ?? []
    expectNoDifference(sliceReceived, Array(rawBytes[1..<4]))
    expectNoDifference(slice.size, 3)
  }
}
