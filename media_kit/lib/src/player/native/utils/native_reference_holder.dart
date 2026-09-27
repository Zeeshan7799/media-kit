/// This file is a part of media_kit (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:safe_local_storage/safe_local_storage.dart';
import 'package:synchronized/synchronized.dart';

import 'package:media_kit/ffi/src/allocation.dart';
import 'package:media_kit/src/player/native/utils/temp_file.dart';

/// Callback invoked to notify about the released references.
typedef NativeReferenceHolderCallback = void Function(List<Pointer<Void>>);

/// {@template native_reference_holder}
///
/// NativeReferenceHolder
/// ---------------------
/// Holds references to [Pointer<generated.mpv_handle>]s created during the application runtime.
/// These references are used to dispose the [Pointer<generated.mpv_handle>]s left behind by a previous Dart isolate in the same
/// process, i.e. upon hot-restart in debug mode, or in release mode when the Flutter engine is recreated while the process stays
/// alive (e.g. a foreground service keeps it running after the activity is destroyed). Their wakeup callbacks point into the dead
/// isolate, so libmpv would crash (SIGSEGV) the next time it notifies them.
///
/// {@endtemplate}
class NativeReferenceHolder {
  /// Maximum number of references that can be held.
  static const int kReferenceBufferSize = 512;

  /// Singleton instance.
  static final NativeReferenceHolder instance = NativeReferenceHolder._();

  /// Whether the [instance] is initialized.
  static bool initialized = false;

  /// {@macro native_reference_holder}
  NativeReferenceHolder._();

  /// Initializes the instance.
  static void ensureInitialized(NativeReferenceHolderCallback callback) {
    if (initialized) return;
    initialized = true;
    instance._ensureInitialized(callback);
  }

  void _ensureInitialized(NativeReferenceHolderCallback callback) async {
    await _deleteStaleFiles();
    if (!await _file.exists_()) {
      // Allocate reference buffer.
      _referenceBuffer = calloc<IntPtr>(kReferenceBufferSize);
      final address = _referenceBuffer.address;
      await _file.write_(address.toString());
      print('$kTag Allocated $address');
    } else {
      // Locate reference buffer.
      final address = int.parse((await _file.readAsString_())!);
      _referenceBuffer = Pointer<IntPtr>.fromAddress(address);
      print('$kTag Located $address');
    }

    final references = <Pointer<Void>>[];

    for (int i = 0; i < kReferenceBufferSize; i++) {
      final referencePtr = _referenceBuffer + i;
      final referenceAddress = referencePtr.value;
      referencePtr.value = 0;
      if (referenceAddress != 0) {
        references.add(Pointer.fromAddress(referenceAddress));
      }
    }

    callback(references);

    _completer.complete();
  }

  /// Saves the reference.
  Future<void> add(Pointer reference) async {
    if (!initialized) return;
    if (reference == nullptr) return;
    await _completer.future;
    return _lock.synchronized(() async {
      for (int i = 0; i < kReferenceBufferSize; i++) {
        final referenceValue = _referenceBuffer + i;
        final referencePtr = Pointer.fromAddress(referenceValue.value);
        // NOTE: Do not compare .value with .address. Bad things may happen on 32-bit systems.
        if (referencePtr.address == 0) {
          referenceValue.value = reference.address;
          break;
        }
      }
    });
  }

  /// Removes the reference.
  Future<void> remove(Pointer reference) async {
    if (!initialized) return;
    if (reference == nullptr) return;
    await _completer.future;
    return _lock.synchronized(() async {
      for (int i = 0; i < kReferenceBufferSize; i++) {
        final referenceValue = _referenceBuffer + i;
        final referencePtr = Pointer.fromAddress(referenceValue.value);
        // NOTE: Do not compare .value with .address. Bad things may happen on 32-bit systems.
        if (referencePtr.address == reference.address) {
          referenceValue.value = 0;
          break;
        }
      }
    });
  }

  /// [Lock] used to synchronize access to the reference buffer.
  final Lock _lock = Lock();

  /// [Completer] used to wait for the reference buffer to be allocated.
  final Completer<void> _completer = Completer<void>();

  /// Removes files left by earlier processes. On Android the directory is
  /// persistent and process ids are reused, so a stale file could otherwise
  /// point this process at another process's (unmapped) memory.
  Future<void> _deleteStaleFiles() async {
    try {
      final directory = Directory(TempFile.directory);
      await for (final entity in directory.list()) {
        final name = path.basename(entity.path);
        if (entity is File &&
            name.startsWith(_kFilePrefix) &&
            entity.path != _file.path) {
          await entity.delete();
        }
      }
    } catch (_) {}
  }

  /// Identifies this process: its pid plus, where available, its start time,
  /// which stays unique even when the pid is reused.
  static String get _processTag {
    try {
      if (Platform.isAndroid || Platform.isLinux) {
        final stat = File('/proc/self/stat').readAsStringSync();
        // Fields after the parenthesised command name start at field 3;
        // field 22 is the process start time.
        final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
        return '$pid.${fields[19]}';
      }
    } catch (_) {}
    return '$pid';
  }

  static const String _kFilePrefix = 'com.alexmercerind.media_kit.NativeReferenceHolder.';

  /// [File] used to store [int] address to the reference buffer.
  /// This is necessary to have a persistent reference to the buffer across
  /// Dart isolates of the same process (hot-restart, engine re-creation).
  final File _file = File(
    path.join(
      TempFile.directory,
      '$_kFilePrefix$_processTag',
    ),
  );

  /// [Pointer] to the reference buffer.
  late final Pointer<IntPtr> _referenceBuffer;

  static const String kTag = 'media_kit: NativeReferenceHolder:';
}
