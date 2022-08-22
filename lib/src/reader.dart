/*
 * Based on libserialport (https://sigrok.org/wiki/Libserialport).
 *
 * Copyright (C) 2010-2012 Bert Vermeulen <bert@biot.com>
 * Copyright (C) 2010-2015 Uwe Hermann <uwe@hermann-uwe.de>
 * Copyright (C) 2013-2015 Martin Ling <martin-libserialport@earth.li>
 * Copyright (C) 2013 Matthias Heidbrink <m-sigrok@heidbrink.biz>
 * Copyright (C) 2014 Aurelien Jacobs <aurel@gnuage.org>
 * Copyright (C) 2020 J-P Nurmi <jpnurmi@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;
import 'package:libserialport/src/bindings.dart';
import 'package:libserialport/src/dylib.dart';
import 'package:libserialport/src/error.dart';
import 'package:libserialport/src/port.dart';
import 'package:libserialport/src/util.dart';

const int _kReadEvents = sp_event.SP_EVENT_RX_READY | sp_event.SP_EVENT_ERROR;

/// Asynchronous serial port reader.
///
/// Provides a [stream] that can be listened to asynchronously to receive data
/// whenever available.
///
/// The [stream] will attempt to open a given [port] for reading. If the stream
/// fails to open the port, it will emit [SerialPortError]. If the port is
/// successfully opened, the stream will begin emitting [Uint8List] data events.
///
/// **Note:** The reader must be closed using [close()] when done with reading.
abstract class SerialPortReader {
  /// Creates a reader for the port. Optional [timeout] parameter can be
  /// provided to specify a time im milliseconds between attempts to read after
  /// a failure to open the [port] for reading. If not given, [timeout] defaults
  /// to 500ms.
  factory SerialPortReader(SerialPort port, {int? timeout}) =>
      _SerialPortReaderImpl(port, timeout: timeout);

  /// Gets the port the reader operates on.
  SerialPort get port;

  /// Gets a stream of data.
  Stream<Uint8List> get stream;

  /// Closes the stream.
  void close();
}

class _SerialPortReaderArgs {
  final int address;
  final int timeout;
  final SendPort sendPort;
  _SerialPortReaderArgs({
    required this.address,
    required this.timeout,
    required this.sendPort,
  });
}

class _SerialPortReaderImpl implements SerialPortReader {
  final SerialPort _port;
  final int _timeout;
  Isolate? _isolate;
  ReceivePort? _receiver;
  StreamController<Uint8List>? __controller;

  _SerialPortReaderImpl(SerialPort port, {int? timeout})
      : _port = port,
        _timeout = timeout ?? 500;

  @override
  SerialPort get port => _port;

  @override
  Stream<Uint8List> get stream => _controller.stream;

  @override
  void close() {
    __controller?.close();
    __controller = null;
  }

  StreamController<Uint8List> get _controller {
    return __controller ??= StreamController<Uint8List>(
      onListen: _startRead,
      onCancel: _cancelRead,
      onPause: _cancelRead,
      onResume: _startRead,
    );
  }

  void _startRead() {
    _receiver = ReceivePort();
    _receiver!.listen((data) {
      if (data is SerialPortError) {
        _controller.addError(data);
      } else if (data is Uint8List) {
        _controller.add(data);
      }
    });
    final args = _SerialPortReaderArgs(
      address: _port.address,
      timeout: _timeout,
      sendPort: _receiver!.sendPort,
    );
    Isolate.spawn(
      _readerIsolate,
      args,
      debugName: toString(),
    ).then((value) => _isolate = value);
  }

  void _cancelRead() {
    _receiver?.close();
    _receiver = null;
    _isolate?.kill();
    _isolate = null;
  }

  static void _waitRead(_SerialPortReaderArgs args) {
    SerialPort port = SerialPort.fromAddress(args.address);
    while (port.isOpen) {
      // Read a single byte. This is a blocking call which will timeout after args.timeout ms.
      var first = port.read(1, timeout: args.timeout);
      if (first.isNotEmpty) {
        // Send the single byte
        args.sendPort.send(first);
        // Read the rest of the data available.
        var toRead = port.bytesAvailable;
        if (toRead > 0) {
          var remaining = port.read(toRead);
          if (remaining.isNotEmpty) {
            args.sendPort.send(remaining);
          }
        }
      }
    }
  }

  static void _readerIsolate(_SerialPortReaderArgs args) {
    SerialPort port = SerialPort.fromAddress(args.address);
    while (port.isOpen) {
      // Read a single byte
      var first = port.read(1, timeout: args.timeout);
      if (first.isNotEmpty) {
        var toRead = port.bytesAvailable;
        if (toRead > 0) {
          // Read the rest.
          var remaining = port.read(toRead);
          if (remaining.length == toRead) {
            var data = Uint8List(toRead + 1);
            data[0] = first[0];
            data.setRange(1, toRead + 1, remaining);
            args.sendPort.send(data);
          } else {
            args.sendPort.send(SerialPortError('Could not read all data.'));
          }
        } else {
          // Send the single byte
          args.sendPort.send(first);
        }
      }
    }
  }

  static ffi.Pointer<ffi.Pointer<sp_event_set>> _createEvents(
    ffi.Pointer<sp_port> port,
    int mask,
  ) {
    final events = ffi.calloc<ffi.Pointer<sp_event_set>>();
    dylib.sp_new_event_set(events);
    dylib.sp_add_port_events(events.value, port, mask);
    return events;
  }

  static int _waitEvents(
    ffi.Pointer<sp_port> port,
    ffi.Pointer<ffi.Pointer<sp_event_set>> events,
    int timeout,
  ) {
    dylib.sp_wait(events.value, timeout);
    return dylib.sp_input_waiting(port);
  }

  static void _releaseEvents(ffi.Pointer<ffi.Pointer<sp_event_set>> events) {
    dylib.sp_free_event_set(events.value);
  }
}
