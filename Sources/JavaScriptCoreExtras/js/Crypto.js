function Crypto(key) {
  _jsCoreExtrasInternalConstructorCheck(key);
}

function _jsCoreExtrasSubtleToBytes(input) {
  if (input instanceof ArrayBuffer) return Array.from(new Uint8Array(input));
  if (ArrayBuffer.isView(input)) return Array.from(new Uint8Array(input.buffer, input.byteOffset, input.byteLength));
  if (Array.isArray(input)) return input.slice();
  throw new TypeError("Expected ArrayBuffer or ArrayBufferView");
}

Object.defineProperties(Crypto.prototype, {
  randomUUID: _jsCoreExtrasFunctionProperty(_jsCoreExtrasRandomUUID),
  getRandomValues: _jsCoreExtrasFunctionProperty(function (view) {
    _jsCoreExtrasEnsureMinArgCount("getRandomValues", "Crypto", [view], 1);
    if (!ArrayBuffer.isView(view)) {
      throw _jsCoreExtrasFailedToExecute(
        "Crypto",
        "getRandomValues",
        "parameter 1 is not of type 'ArrayBufferView'.",
      );
    }
    const dataView = new DataView(view.buffer);
    const bytes = _jsCoreExtrasRandomBytes(view.byteLength);
    for (let i = 0; i < view.byteLength; i++) {
      dataView.setUint8(i, bytes[i]);
    }
    return view;
  }),
  subtle: _jsCoreExtrasReadonlyProperty(function () {
    return {
      digest: function (algorithm, data) {
        const algoName = typeof algorithm === "string" ? algorithm : algorithm && algorithm.name;
        if (!algoName || algoName.toLowerCase() !== "sha-256") {
          return Promise.reject(new TypeError("Only SHA-256 is supported"));
        }
        try {
          const bytes = _jsCoreExtrasSubtleToBytes(data);
          const hash = _jsCoreExtrasSubtleDigest(bytes);
          if (!hash) throw new Error("Digest failed");
          return Promise.resolve(new Uint8Array(hash).buffer);
        } catch (e) {
          return Promise.reject(e);
        }
      },
      importKey: function (format, keyData, algorithm, extractable, keyUsages) {
        if (format !== "raw") return Promise.reject(new TypeError("Only raw format is supported"));
        const algoName = algorithm && algorithm.name;
        if (!algoName || algoName.toLowerCase() !== "aes-gcm") {
          return Promise.reject(new TypeError("Only AES-GCM is supported"));
        }
        try {
          const bytes = _jsCoreExtrasSubtleToBytes(keyData);
          return Promise.resolve({ _bytes: bytes, _algo: "AES-GCM" });
        } catch (e) {
          return Promise.reject(e);
        }
      },
      decrypt: function (algorithm, key, data) {
        const algoName = algorithm && algorithm.name;
        if (!algoName || algoName.toLowerCase() !== "aes-gcm") {
          return Promise.reject(new TypeError("Only AES-GCM is supported"));
        }
        const iv = algorithm.iv;
        if (!iv) return Promise.reject(new TypeError("Missing iv"));
        try {
          const ivBytes = _jsCoreExtrasSubtleToBytes(iv);
          const keyBytes = key && key._bytes ? key._bytes : _jsCoreExtrasSubtleToBytes(key);
          const dataBytes = _jsCoreExtrasSubtleToBytes(data);
          const plain = _jsCoreExtrasSubtleDecrypt(keyBytes, ivBytes, dataBytes);
          if (plain === null || plain === undefined) throw new Error("Decrypt failed");
          return Promise.resolve(new Uint8Array(plain).buffer);
        } catch (e) {
          return Promise.reject(e);
        }
      },
    };
  }),
});

const crypto = new Crypto(Symbol._jsCoreExtrasPrivate);
