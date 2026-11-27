import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

typedef _StrInOutNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _StrInOutDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _VoidToStrNative = Pointer<Utf8> Function();
typedef _VoidToStrDart = Pointer<Utf8> Function();
typedef _FreeStrNative = Void Function(Pointer<Utf8>);
typedef _FreeStrDart = void Function(Pointer<Utf8>);

class LocalNodeInfo {
  final String nodeId;
  final String? relayUrl;
  final List<String> directAddrs;
  final Map<String, String> readyFiles;

  LocalNodeInfo({
    required this.nodeId,
    this.relayUrl,
    required this.directAddrs,
    this.readyFiles = const {},
  });

  factory LocalNodeInfo.fromJson(Map<String, dynamic> json) => LocalNodeInfo(
        nodeId: json['node_id'] as String,
        readyFiles: Map<String, String>.from(json['ready_files'] as Map? ?? {}),
        relayUrl: json['relay_url'] as String?,
        directAddrs: (json['direct_addrs'] as List<dynamic>? ?? [])
            .map((e) => e.toString())
            .toList(),
      );
}

class RegisteredP2pFile {
  final String itemId;
  final String path;
  final int size;
  final String blake3Hash;

  RegisteredP2pFile({
    required this.itemId,
    required this.path,
    required this.size,
    required this.blake3Hash,
  });

  factory RegisteredP2pFile.fromJson(Map<String, dynamic> json) =>
      RegisteredP2pFile(
        itemId: json['item_id'] as String,
        path: json['path'] as String,
        size: (json['size'] as num).toInt(),
        blake3Hash: json['blake3_hash'] as String,
      );
}

/// FFI bridge to the shared Rust `iroh` P2P engine (`libdropdrawer_p2p`).
/// Gracefully degrades if the native library hasn't been compiled for the current target yet.
class P2pFfiBridge {
  DynamicLibrary? _lib;
  _StrInOutDart? _start;
  _VoidToStrDart? _nodeInfo;
  _StrInOutDart? _registerFile;
  _StrInOutDart? _authorizeToken;
  _StrInOutDart? _prepareBrowserShare;
  _StrInOutDart? _unregisterFile;
  _StrInOutDart? _downloadFile;
  _StrInOutDart? _cancelTransfer;
  _VoidToStrDart? _pollEvents;
  _VoidToStrDart? _shutdown;
  _FreeStrDart? _freeString;

  bool get isAvailable => _lib != null;
  bool get supportsBrowserShare => _prepareBrowserShare != null;

  bool loadLibrary() {
    if (_lib != null) return true;
    final candidates = _candidatePaths();
    for (final candidate in candidates) {
      try {
        _lib = candidate == '__PROCESS__'
            ? DynamicLibrary.process()
            : DynamicLibrary.open(candidate);
        _bindSymbols(_lib!);
        return true;
      } catch (_) {
        _lib = null;
      }
    }
    return false;
  }

  List<String> _candidatePaths() {
    if (Platform.isIOS) {
      return ['__PROCESS__'];
    }
    if (Platform.isMacOS) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      return [
        // Bundled inside .app/Contents/Frameworks/
        p.normalize(p.join(exeDir, '..', 'Frameworks', 'libdropdrawer_p2p.dylib')),
        'libdropdrawer_p2p.dylib',
        // Workspace dev builds
        p.normalize(p.join(Directory.current.path, '..', 'target', 'release', 'libdropdrawer_p2p.dylib')),
        p.normalize(p.join(Directory.current.path, '..', 'target', 'debug', 'libdropdrawer_p2p.dylib')),
        p.normalize(p.join(Directory.current.path, 'target', 'release', 'libdropdrawer_p2p.dylib')),
        p.normalize(p.join(Directory.current.path, 'target', 'debug', 'libdropdrawer_p2p.dylib')),
      ];
    }
    if (Platform.isWindows) {
      return [
        p.join(p.dirname(Platform.resolvedExecutable), 'dropdrawer_p2p.dll'),
        'dropdrawer_p2p.dll',
        p.normalize(p.join(Directory.current.path, '..', 'target', 'release', 'dropdrawer_p2p.dll')),
        p.normalize(p.join(Directory.current.path, '..', 'target', 'debug', 'dropdrawer_p2p.dll')),
      ];
    }
    return [
      'libdropdrawer_p2p.so',
      p.normalize(p.join(Directory.current.path, '..', 'target', 'release', 'libdropdrawer_p2p.so')),
      p.normalize(p.join(Directory.current.path, '..', 'target', 'debug', 'libdropdrawer_p2p.so')),
    ];
  }

  void _bindSymbols(DynamicLibrary lib) {
    _start = lib.lookupFunction<_StrInOutNative, _StrInOutDart>('dropdrawer_p2p_start');
    _nodeInfo = lib.lookupFunction<_VoidToStrNative, _VoidToStrDart>('dropdrawer_p2p_node_info');
    _registerFile = lib.lookupFunction<_StrInOutNative, _StrInOutDart>('dropdrawer_p2p_register_file');
    _authorizeToken = lib.lookupFunction<_StrInOutNative, _StrInOutDart>('dropdrawer_p2p_authorize_token');
    try {
      _prepareBrowserShare = lib.lookupFunction<_StrInOutNative, _StrInOutDart>(
        'dropdrawer_p2p_prepare_browser_share',
      );
    } on ArgumentError {
      _prepareBrowserShare = null;
    }
    _unregisterFile = lib.lookupFunction<_StrInOutNative, _StrInOutDart>('dropdrawer_p2p_unregister_file');
    _downloadFile = lib.lookupFunction<_StrInOutNative, _StrInOutDart>('dropdrawer_p2p_download_file');
    _cancelTransfer = lib.lookupFunction<_StrInOutNative, _StrInOutDart>('dropdrawer_p2p_cancel_transfer');
    _pollEvents = lib.lookupFunction<_VoidToStrNative, _VoidToStrDart>('dropdrawer_p2p_poll_events');
    _shutdown = lib.lookupFunction<_VoidToStrNative, _VoidToStrDart>('dropdrawer_p2p_shutdown');
    _freeString = lib.lookupFunction<_FreeStrNative, _FreeStrDart>('dropdrawer_p2p_free_string');
  }

  Map<String, dynamic> _decodeAndFree(Pointer<Utf8> ptr) {
    final text = ptr.toDartString();
    _freeString!(ptr);
    final decoded = jsonDecode(text) as Map<String, dynamic>;
    if (decoded['ok'] != true) {
      throw StateError(decoded['error']?.toString() ?? 'Unknown P2P FFI error');
    }
    return decoded;
  }

  Map<String, dynamic> _callJson(_StrInOutDart fn, Map<String, dynamic> body) {
    final cStr = jsonEncode(body).toNativeUtf8();
    try {
      final outPtr = fn(cStr);
      return _decodeAndFree(outPtr);
    } finally {
      malloc.free(cStr);
    }
  }

  LocalNodeInfo start({
    required String dataDir,
    String? customRelayUrl,
    bool disableRelay = false,
  }) {
    final res = _callJson(_start!, {
      'data_dir': dataDir,
      'custom_relay_url': customRelayUrl,
      'disable_relay': disableRelay,
    });
    return LocalNodeInfo.fromJson(res['data'] as Map<String, dynamic>);
  }

  LocalNodeInfo nodeInfo() {
    final res = _decodeAndFree(_nodeInfo!());
    return LocalNodeInfo.fromJson(res['data'] as Map<String, dynamic>);
  }

  RegisteredP2pFile registerFile(String itemId, String path) {
    final res = _callJson(_registerFile!, {'item_id': itemId, 'path': path});
    return RegisteredP2pFile.fromJson(res['data'] as Map<String, dynamic>);
  }

  Future<String> prepareBrowserShare(Map<String, dynamic> request) =>
      Isolate.run(() => _prepareBrowserShareInWorker(request));

  void authorizeToken({
    required String itemId,
    required String token,
    required String expiresAtIso,
    String? requesterNodeId,
  }) {
    _callJson(_authorizeToken!, {
      'item_id': itemId,
      'token': token,
      'expires_at': expiresAtIso,
      'requester_node_id': ?requesterNodeId,
    });
  }

  void unregisterFile(String itemId) {
    final cStr = itemId.toNativeUtf8();
    try {
      _decodeAndFree(_unregisterFile!(cStr));
    } finally {
      malloc.free(cStr);
    }
  }

  String downloadFile({
    required String itemId,
    required String remoteNodeId,
    String? remoteRelayUrl,
    required List<String> remoteDirectAddrs,
    required String transferToken,
    required String destPath,
    bool skipLegacyResume = false,
    String? replicaHash,
  }) {
    final result = _callJson(_downloadFile!, {
      'item_id': itemId,
      'remote_node_id': remoteNodeId,
      'remote_relay_url': remoteRelayUrl,
      'remote_direct_addrs': remoteDirectAddrs,
      'transfer_token': transferToken,
      'dest_path': destPath,
      'skip_legacy_resume': skipLegacyResume,
      'replica_hash': ?replicaHash,
    });
    return result['data'] as String;
  }

  void cancelTransfer(String transferId) {
    final id = transferId.toNativeUtf8();
    try {
      _decodeAndFree(_cancelTransfer!(id));
    } finally {
      malloc.free(id);
    }
  }

  List<Map<String, dynamic>> pollEvents() {
    if (_pollEvents == null) return const [];
    final res = _decodeAndFree(_pollEvents!());
    final list = res['data'] as List<dynamic>? ?? const [];
    return list.cast<Map<String, dynamic>>();
  }

  void shutdown() {
    if (_shutdown != null) {
      try {
        _decodeAndFree(_shutdown!());
      } catch (_) {}
    }
  }
}

String _prepareBrowserShareInWorker(Map<String, dynamic> request) {
  final bridge = P2pFfiBridge();
  if (!bridge.loadLibrary() || !bridge.supportsBrowserShare) {
    throw StateError('Browser share is unavailable');
  }
  return bridge._callJson(bridge._prepareBrowserShare!, request)['data']
      as String;
}
