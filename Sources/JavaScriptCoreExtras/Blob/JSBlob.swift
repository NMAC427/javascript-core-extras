@preconcurrency import JavaScriptCore
import Foundation

// MARK: - JSBlob

@objc private protocol JSBlobExport: JSExport {
  var size: Int64 { get }
  var type: String { get }

  init?(blobParts iterable: JSValue, options: JSValue)

  func text() -> JSValue
  func bytes() -> JSValue
  func arrayBuffer() -> JSValue

  func slice(_ start: JSValue, _ end: JSValue, _ type: JSValue) -> JSBlob
}

/// A class representing a Javascript `Blob`.
///
/// > Note: The Objective C class name of this class is `Blob` instead of `JSBlob`. This is to
/// > ensure that JavaScriptCore recognizes the constructor name as `"Blob"` instead of `"JavaScriptCoreExtras.JSBlob"`.
///
/// You can create blobs through Javascript, but also by leveraging the ``JSBlobStorage``
/// protocol which allows you to create a blob with bytes from an arbitrary source such as a file.
@objc(Blob) open class JSBlob: NSObject {
  /// The `MIMEType` of this blob.
  public let mimeType: MIMEType

  private let indexedStorage: IndexedStorage

  /// Creates a blob using its Javascript initializer.
  ///
  /// See [MDN docs](https://developer.mozilla.org/en-US/docs/Web/API/Blob/Blob).
  public required convenience init?(blobParts iterable: JSValue, options: JSValue) {
    guard let context = JSContext.current() else { return nil }
    let type = options.isUndefined ? "" : options.objectForKeyedSubscript("type").toString() ?? ""
    guard iterable.isUndefined || (iterable.isIterable && !iterable.isString) else {
      context.exception = .constructError(
        className: "Blob",
        message: "The provided value cannot be converted to a sequence.",
        in: context
      )
      return nil
    }
    guard !iterable.isUndefined else {
      self.init(storage: "", type: MIMEType(rawValue: type))
      return
    }
    let map: @convention(block) (JSValue) -> String = { $0.toString() }
    let strings = context.objectForKeyedSubscript("Array")
      .invokeMethod("from", withArguments: [iterable])
      .invokeMethod("map", withArguments: [unsafeBitCast(map, to: JSValue.self)])
      .toArray()
      .compactMap { $0 as? String }
    self.init(storage: strings.joined(), type: MIMEType(rawValue: type))
  }

  /// Creates a blob from another blob.
  ///
  /// - Parameter blob: Another blob.
  public init(blob: JSBlob) {
    self.mimeType = blob.mimeType
    self.indexedStorage = blob.indexedStorage
  }

  /// Creates a blob from a backing ``JSBlobStorage`` and `MIMEType`.
  ///
  /// ```swift
  /// let blob = JSBlob(storage: "Hello world!", type: .text)
  /// ```
  ///
  /// - Parameters:
  ///   - storage: A ``JSBlobStorage``.
  ///   - type: A `MIMEType`.
  public init(storage: some JSBlobStorage, type: MIMEType) {
    self.mimeType = type
    self.indexedStorage = IndexedStorage(
      startIndex: 0,
      endIndex: storage.byteCount,
      storage: storage
    )
  }

  private init(state: IndexedStorage, type: MIMEType) {
    self.indexedStorage = state
    self.mimeType = type
  }
}

// MARK: - Subscript

extension JSBlob {
  public subscript(range: Range<Int64>, type mimeType: MIMEType? = nil) -> JSBlob {
    var state = self.indexedStorage
    state.startIndex = range.lowerBound
    state.endIndex = range.upperBound
    return JSBlob(state: state, type: mimeType ?? self.mimeType)
  }

  public subscript(range: PartialRangeFrom<Int64>, type mimeType: MIMEType? = nil) -> JSBlob {
    var state = self.indexedStorage
    state.startIndex = range.lowerBound
    state.endIndex = self.size
    return JSBlob(state: state, type: mimeType ?? self.mimeType)
  }
}

// MARK: - UTF8

extension JSBlob {
  /// Returns the UTF8 view from this blob.
  public func utf8(context: JSContext) async throws -> String.UTF8View {
    try await self.indexedStorage.utf8(context: context)
  }

  /// Returns the raw bytes from this blob.
  public func data(context: JSContext) async throws -> Data {
    try await self.indexedStorage.bytes(context: context)
  }
}

// MARK: - JSExport Conformance

extension JSBlob: JSBlobExport {
  /// The mime type as a raw string.
  public var type: String {
    self.mimeType.rawValue
  }

  /// The size (in bytes) of this blob.
  public var size: Int64 {
    self.indexedStorage.endIndex - self.indexedStorage.startIndex
  }

  /// Returns the text of this blob as a `JSValue`.
  public func text() -> JSValue {
    self.bytesPromise { data, _ in String(decoding: data, as: UTF8.self) }.value
  }

  /// Returns the bytes of this blob as a `JSValue`.
  public func bytes() -> JSValue {
    self.bytesPromise { bufferWithBytes(data: $0, in: $1).1 }.value
  }

  /// Returns a Javascript `ArrayBuffer` of this blob as a `JSValue`.
  public func arrayBuffer() -> JSValue {
    self.bytesPromise { bufferWithBytes(data: $0, in: $1).0 }.value
  }

  /// The implementation of Javascript's `Blob.slice`.
  public func slice(_ start: JSValue, _ end: JSValue, _ type: JSValue) -> JSBlob {
    let type = MIMEType(rawValue: type.isUndefined ? self.type : type.toString() ?? "")
    guard !start.isUndefined else { return self }
    let start = max(0, Int64(start.toInt32()))
    guard !end.isUndefined else { return self[start..., type: type] }
    let end = min(self.size, end.isUndefined ? self.size : Int64(end.toInt32()))
    return self[start..<end, type: type]
  }

  private func utf8Promise(
    _ map: @Sendable @escaping (String.UTF8View, JSContext) -> Any?
  ) -> JSPromise {
    JSPromise(in: .current()) { continuation in
      let executor = JSVirtualMachineExecutor.current()
      let indexedStorage = self.indexedStorage
      Task { await indexedStorage.utf8(continuation: continuation, executor: executor, map) }
    }
  }

  private func bytesPromise(
    _ map: @Sendable @escaping (Data, JSContext) -> Any?
  ) -> JSPromise {
    JSPromise(in: .current()) { continuation in
      let executor = JSVirtualMachineExecutor.current()
      let indexedStorage = self.indexedStorage
      Task { await indexedStorage.bytes(continuation: continuation, executor: executor, map) }
    }
  }
}

// MARK: - Helpers

extension JSBlob {
  private struct IndexedStorage: Sendable {
    var startIndex: Int64
    var endIndex: Int64
    let storage: any JSBlobStorage

    var size: Int64 { self.endIndex - self.startIndex }

    func bytes(context: JSContext) async throws(JSValueError) -> Data {
      try await self.storage.bytes(
        startIndex: self.startIndex,
        endIndex: self.endIndex,
        context: context
      )
    }

    func utf8(context: JSContext) async throws(JSValueError) -> String.UTF8View {
      String(decoding: try await self.bytes(context: context), as: UTF8.self).utf8
    }

    func utf8(
      continuation: JSPromise.Continuation,
      executor: JSVirtualMachineExecutor?,
      _ map: (String.UTF8View, JSContext) -> Any?
    ) async {
      do {
        let result = map(try await self.utf8(context: continuation.context), continuation.context)
        if let executor {
          nonisolated(unsafe) let capturedResult = result
          await executor.withVirtualMachine { _ in
            continuation.resume(resolving: capturedResult)
          }
        } else {
          continuation.resume(resolving: result)
        }
      } catch {
        if let executor {
          await executor.withVirtualMachine { _ in
            continuation.resume(rejecting: error.value)
          }
        } else {
          continuation.resume(rejecting: error.value)
        }
      }
    }

    func bytes(
      continuation: JSPromise.Continuation,
      executor: JSVirtualMachineExecutor?,
      _ map: (Data, JSContext) -> Any?
    ) async {
      do {
        let result = map(try await self.bytes(context: continuation.context), continuation.context)
        if let executor {
          nonisolated(unsafe) let capturedResult = result
          await executor.withVirtualMachine { _ in
            continuation.resume(resolving: capturedResult)
          }
        } else {
          continuation.resume(resolving: result)
        }
      } catch {
        if let executor {
          await executor.withVirtualMachine { _ in
            continuation.resume(rejecting: error.value)
          }
        } else {
          continuation.resume(rejecting: error.value)
        }
      }
    }
  }
}

extension JSValue {
  fileprivate func consumeIterable() -> [String] {
    guard self.isObject else { return [] }
    guard let symbolIterator = self.context.evaluateScript("Symbol.iterator") else { return [] }
    guard
      let iteratorFunction = self.objectForKeyedSubscript(symbolIterator).call(withArguments: []),
      let iterator = iteratorFunction.call(withArguments: [])
    else { return [] }
    var results: [String] = []
    while true {
      guard let result = iterator.invokeMethod("next", withArguments: []) else { break }
      guard let done = result.forProperty("done")?.toBool() else { break }
      if done { break }
      if let value = result.forProperty("value") {
        results.append(value.toString())
      }
    }
    return results
  }
}

private func bufferWithBytes(
  data: Data,
  in context: JSContext
) -> (JSValue, JSValue) {
  let bytes = context.objectForKeyedSubscript("Uint8Array")
    .construct(withArguments: [data.count])!
  for (index, byte) in data.enumerated() {
    bytes.setValue(byte, at: index)
  }
  return (bytes.objectForKeyedSubscript("buffer")!, bytes)
}

private func bufferWithBytes(
  utf8: String.UTF8View,
  in context: JSContext
) -> (JSValue, JSValue) {
  let bytes = context.objectForKeyedSubscript("Uint8Array")
    .construct(withArguments: [utf8.count])!
  for (index, byte) in utf8.enumerated() {
    bytes.setValue(byte, at: index)
  }
  return (bytes.objectForKeyedSubscript("buffer")!, bytes)
}

// MARK: - Blob Installer

public struct JSBlobInstaller: JSContextInstallable, Sendable {
  public func install(in context: JSContext) {
    context.setObject(JSBlob.self, forPath: "Blob")
  }
}

extension JSContextInstallable where Self == JSBlobInstaller {
  /// An installable that installs the Blob class.
  public static var blob: Self { JSBlobInstaller() }
}
