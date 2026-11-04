import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'sincronizacao_bengala.dart';

class ServicoBluetoothBengala {
  final String _serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String _charUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  BluetoothDevice? _dispositivoConectado;
  final String bengalaId;

  ServicoBluetoothBengala({required this.bengalaId});

  Future<void> conectar() async {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

    FlutterBluePlus.scanResults.listen((results) async {
      for (ScanResult r in results) {
        if (r.device.platformName == "Bengala_ESP32" ||
            r.device.advName == "Bengala_ESP32") {
          FlutterBluePlus.stopScan();
          _dispositivoConectado = r.device;

          await r.device.connect();
          _configurarLeitura();
        }
      }
    });
  }

  Future<void> _configurarLeitura() async {
    if (_dispositivoConectado == null) return;

    List<BluetoothService> services = await _dispositivoConectado!
        .discoverServices();
    for (BluetoothService service in services) {
      if (service.uuid.toString() == _serviceUuid) {
        for (BluetoothCharacteristic characteristic
            in service.characteristics) {
          if (characteristic.uuid.toString() == _charUuid) {
            await characteristic.setNotifyValue(true);

            characteristic.onValueReceived.listen((value) {
              // 1. Recebe o texto cru do ESP32 (ex: {\bat:100,\emerg:0,\lat:-29.45})
              String textoCru = String.fromCharCodes(value);
              _processarTextoPersonalizado(textoCru);
            });
          }
        }
      }
    }
  }

  // Tradutor manual para não precisares de alterar o Arduino
  Future<void> _processarTextoPersonalizado(String texto) async {
    try {
      await DadosBengalaService.instancia!.receber(
        bengalaId,
        utf8.encode(texto),
      );
    } catch (e) {
      debugPrint('Falha ao guardar leitura local: $e');
    }
  }
}
