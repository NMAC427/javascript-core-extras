import Foundation
import JavaScriptCore

// MARK: - JSBlobStorage

/// A protocol that allows the creation of ``JSBlob`` by using an arbitrary source of bytes such
/// as a file.
public protocol JSBlobStorage: Sendable {
  /// The size (in bytes) of the stored content.
  var byteCount: Int64 { get }

  /// Returns the stored bytes.
  func bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> Data

  /// The size (in bytes) of the stored UTF8 content.
  var utf8SizeInBytes: Int64 { get }

  /// Returns the stored UTF8 bytes.
  func utf8Bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> String.UTF8View
}

// MARK: - Backward Compatibility Defaults

extension JSBlobStorage {
  public var utf8SizeInBytes: Int64 { self.byteCount }

  public func utf8Bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> String.UTF8View {
    let data = try await self.bytes(startIndex: startIndex, endIndex: endIndex, context: context)
    return String(decoding: data, as: UTF8.self).utf8
  }
}

// MARK: - String Conformances

extension String: JSBlobStorage {
  public var byteCount: Int64 { Int64(self.utf8.count) }

  public func bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> Data {
    let start = self.utf8.index(self.utf8.startIndex, offsetBy: Int(startIndex))
    let end = self.utf8.index(self.utf8.startIndex, offsetBy: Int(endIndex))
    return Data(self.utf8[start..<end])
  }

  public func utf8Bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> String.UTF8View {
    let start = self.utf8.index(self.utf8.startIndex, offsetBy: Int(startIndex))
    let end = self.utf8.index(self.utf8.startIndex, offsetBy: Int(endIndex))
    return String(Substring(self.utf8[start..<end])).utf8
  }
}

extension Substring: JSBlobStorage {
  public var byteCount: Int64 { Int64(self.utf8.count) }

  public func bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> Data {
    let start = self.utf8.index(self.utf8.startIndex, offsetBy: Int(startIndex))
    let end = self.utf8.index(self.utf8.startIndex, offsetBy: Int(endIndex))
    return Data(self.utf8[start..<end])
  }

  public func utf8Bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> String.UTF8View {
    let start = self.utf8.index(self.utf8.startIndex, offsetBy: Int(startIndex))
    let end = self.utf8.index(self.utf8.startIndex, offsetBy: Int(endIndex))
    return String(Substring(self.utf8[start..<end])).utf8
  }
}

extension String.UTF8View: JSBlobStorage {
  public var byteCount: Int64 { Int64(self.count) }

  public func bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> Data {
    let start = self.index(self.startIndex, offsetBy: Int(startIndex))
    let end = self.index(self.startIndex, offsetBy: Int(endIndex))
    return Data(self[start..<end])
  }

  public func utf8Bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> Self {
    let start = self.index(self.startIndex, offsetBy: Int(startIndex))
    let end = self.index(self.startIndex, offsetBy: Int(endIndex))
    return String(Substring(self[start..<end])).utf8 as! Self
  }
}

extension Substring.UTF8View: JSBlobStorage {
  public var byteCount: Int64 { Int64(self.count) }

  public func bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> Data {
    let start = self.index(self.startIndex, offsetBy: Int(startIndex))
    let end = self.index(self.startIndex, offsetBy: Int(endIndex))
    return Data(self[start..<end])
  }

  public func utf8Bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> String.UTF8View {
    let startIndex = self.index(self.startIndex, offsetBy: Int(startIndex))
    let endIndex = self.index(self.startIndex, offsetBy: Int(endIndex))
    return String(Substring(self[startIndex..<endIndex])).utf8
  }
}

// MARK: - Data Conformance

extension Data: JSBlobStorage {
  public var byteCount: Int64 { Int64(self.count) }

  public func bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> Data {
    let start = Int(startIndex)
    let end = Int(endIndex)
    guard start <= end, start >= 0, end <= self.count else { return Data() }
    return self[start..<end]
  }

  public func utf8Bytes(
    startIndex: Int64,
    endIndex: Int64,
    context: JSContext
  ) async throws(JSValueError) -> String.UTF8View {
    let slice = try await self.bytes(startIndex: startIndex, endIndex: endIndex, context: context)
    return String(decoding: slice, as: UTF8.self).utf8
  }
}
