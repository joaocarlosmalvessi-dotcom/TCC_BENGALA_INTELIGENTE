import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'sincronizacao_bengala.dart';

class BLEParaSupabaseService {
  final String _serviceUuid = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
  final String _charUuid = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

  BluetoothDevice? _dispositivoConectado;
  final String bengalaId;

  BLEParaSupabaseService({required this.bengalaId});

  // Começa a procurar o ESP32 e liga-se
  Future<void> conectarNaBengala() async {
    // Garante que o Bluetooth está ligado antes de tentar
    if (await FlutterBluePlus.adapterState.first == BluetoothAdapterState.on) {
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

      FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult r in results) {
          if (r.device.platformName == "Bengala_ESP32" ||
              r.device.advName == "Bengala_ESP32") {
            FlutterBluePlus.stopScan();
            _dispositivoConectado = r.device;

            try {
              await r.device.connect();
              debugPrint("✅ Conectado à Bengala via BLE!");
              _configurarLeituraBLE();
            } catch (e) {
              debugPrint("Erro ao conectar: $e");
            }
          }
        }
      });
    }
  }

  // Prepara para ouvir as mensagens da bengala
  Future<void> _configurarLeituraBLE() async {
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
              String jsonData = utf8.decode(value);
              _processarEEnviarParaSupabase(jsonData);
            });
          }
        }
      }
    }
  }

  // Lê o JSON recebido e guarda no Supabase
  Future<void> _processarEEnviarParaSupabase(String texto) async {
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
