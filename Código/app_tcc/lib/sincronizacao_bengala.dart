import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide SortOrder;
import 'package:uuid/uuid.dart';

class LeituraPendente {
  LeituraPendente(this.id, this.valores);
  final String id;
  final Map<String, Object?> valores;
  String get usuarioId => valores['usuario_id'] as String;
  String get dispositivoId => valores['dispositivo_id'] as String;
}

/// A gravação da leitura e do estado do alarme acontece na mesma transação local.
/// O registro só sai da fila após confirmação do servidor.
class FilaBengala {
  FilaBengala({
    required this.banco,
    required this.usuarioAtual,
    required this.enviar,
    this.envioAutomatico = true,
  });

  final Database banco;
  final String? Function() usuarioAtual;
  final Future<void> Function(LeituraPendente leitura) enviar;
  final bool envioAutomatico;
  final pendentes = ValueNotifier<int>(0);
  final _leituras = stringMapStoreFactory.store('leituras');
  final _sinais = stringMapStoreFactory.store('sinais');
  final _vinculos = stringMapStoreFactory.store('vinculos');
  final _meta = intMapStoreFactory.store('meta');
  bool _enviando = false;
  DateTime? _tentarDepois;

  Future<void> salvar({
    required String usuarioId,
    required String dispositivoId,
    required Map<String, Object?> dados,
    int? sinalEmergencia,
    DateTime? coletadaEm,
  }) async {
    final id = const Uuid().v4();
    final horario = (coletadaEm ?? DateTime.now()).toUtc().toIso8601String();
    await banco.transaction((txn) async {
      final sinalRef = _sinais.record('$usuarioId/$dispositivoId');
      final anterior = await sinalRef.get(txn);
      String? chaveEmergencia;
      if (sinalEmergencia == 0) {
        await sinalRef.put(txn, {'ativo': false});
      } else if (sinalEmergencia == 1 && anterior?['ativo'] != true) {
        chaveEmergencia = id;
        await sinalRef.put(txn, {'ativo': true});
      }
      final ordemRef = _meta.record(1);
      final ordem = ((await ordemRef.get(txn))?['ordem'] as int? ?? 0) + 1;
      await ordemRef.put(txn, {'ordem': ordem});
      await _leituras.record(id).put(txn, {
        'usuario_id': usuarioId,
        'dispositivo_id': dispositivoId,
        'coletada_em': horario,
        'dados': dados,
        'emergencia_chave': chaveEmergencia,
        'ordem': ordem,
      });
    });
    await atualizarContagem();
    if (envioAutomatico) unawaited(sincronizar());
  }

  Future<void> atualizarContagem() async {
    final usuario = usuarioAtual();
    final quantidade = usuario == null
        ? 0
        : await _leituras.count(
            banco,
            filter: Filter.equals('usuario_id', usuario),
          );
    if (usuarioAtual() == usuario) pendentes.value = quantidade;
  }

  Future<void> sincronizar({bool forcar = false}) async {
    if (_enviando) return;
    if (!forcar &&
        _tentarDepois != null &&
        DateTime.now().isBefore(_tentarDepois!)) {
      return;
    }
    _enviando = true;
    try {
      await atualizarContagem();
      while (true) {
        final usuario = usuarioAtual();
        if (usuario == null) break;
        final registro = await _leituras.findFirst(
          banco,
          finder: Finder(
            filter: Filter.equals('usuario_id', usuario),
            sortOrders: [SortOrder('ordem')],
          ),
        );
        if (registro == null || usuarioAtual() != usuario) break;
        await enviar(LeituraPendente(registro.key, registro.value));
        _tentarDepois = null;
        await _leituras.record(registro.key).delete(banco);
        await atualizarContagem();
      }
    } catch (e) {
      // Rede indisponível, sessão expirada ou rejeição: nenhum dado é descartado.
      _tentarDepois = DateTime.now().add(const Duration(seconds: 20));
      debugPrint('Sincronização pendente: $e');
    } finally {
      _enviando = false;
    }
  }

  Future<void> guardarVinculo(String usuario, String mac, String id) async {
    await _vinculos.record('$usuario/$mac').put(banco, {'id': id});
  }

  Future<String?> buscarVinculo(String usuario, String mac) async {
    return (await _vinculos.record('$usuario/$mac').get(banco))?['id']
        as String?;
  }
}

/// Converte os dois formatos atualmente enviados pelo ESP32 sem aceitar NaN.
Map<String, double> lerDadosBengala(String texto) {
  final dados = <String, double>{};
  final limpo = texto.replaceAll(RegExp(r'[{}\\"]'), '');
  for (final par in limpo.split(',')) {
    final partes = par.split(':');
    if (partes.length != 2) continue;
    final valor = double.tryParse(partes[1].trim());
    if (valor != null && valor.isFinite) dados[partes[0].trim()] = valor;
  }
  return dados;
}

Map<String, Object?> normalizarDadosBengala(Map<String, double> dados) {
  final lat = dados['lat'];
  final lng = dados['lng'];
  final gpsValido =
      lat != null &&
      lng != null &&
      lat != 0 &&
      lng != 0 &&
      lat >= -90 &&
      lat <= 90 &&
      lng >= -180 &&
      lng <= 180;
  return {
    if (dados['bat'] != null) 'bateria': dados['bat']!.clamp(0, 100).toInt(),
    if (gpsValido) ...{'latitude_atual': lat, 'longitude_atual': lng},
    for (final campo in ['dist1', 'dist2', 'dist3'])
      if (dados[campo] != null) campo: dados[campo]!.toInt(),
    for (final campo in ['ax', 'ay', 'az'])
      if (dados[campo] != null) campo: dados[campo],
    'is_online': true,
  };
}

class DadosBengalaService with WidgetsBindingObserver {
  DadosBengalaService._(this.fila, this._client);
  static DadosBengalaService? instancia;
  final FilaBengala fila;
  final SupabaseClient _client;
  Timer? _timer;
  StreamSubscription<AuthState>? _auth;

  static Future<void> inicializar() async {
    if (instancia != null) return;
    final pasta = await getApplicationSupportDirectory();
    await pasta.create(recursive: true);
    final banco = await databaseFactoryIo.openDatabase(
      '${pasta.path}${Platform.pathSeparator}bengala_offline.db',
    );
    final client = Supabase.instance.client;
    final fila = FilaBengala(
      banco: banco,
      usuarioAtual: () => client.auth.currentUser?.id,
      enviar: (leitura) async {
        // O servidor também confere o usuário original do pacote.
        await client
            .rpc(
              'sincronizar_leitura_bengala',
              params: {
                'p_evento_id': leitura.id,
                'p_usuario_id': leitura.usuarioId,
                'p_dispositivo_id': leitura.dispositivoId,
                'p_coletada_em': leitura.valores['coletada_em'],
                'p_dados': leitura.valores['dados'],
                'p_emergencia_chave': leitura.valores['emergencia_chave'],
              },
            )
            .timeout(const Duration(seconds: 12));
      },
    );
    final servico = DadosBengalaService._(fila, client);
    instancia = servico;
    WidgetsBinding.instance.addObserver(servico);
    servico._timer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(fila.sincronizar());
    });
    servico._auth = client.auth.onAuthStateChange.listen((_) {
      unawaited(fila.atualizarContagem());
      unawaited(fila.sincronizar(forcar: true));
    });
    unawaited(fila.sincronizar());
  }

  Future<void> receber(String dispositivoId, List<int> bytes) async {
    final usuario = _client.auth.currentUser;
    if (usuario == null || bytes.isEmpty) return;
    final horario = DateTime.now();
    final dados = lerDadosBengala(utf8.decode(bytes));
    if (dados.isEmpty) return;
    await fila.salvar(
      usuarioId: usuario.id,
      dispositivoId: dispositivoId,
      dados: normalizarDadosBengala(dados),
      sinalEmergencia: dados['emerg']?.toInt(),
      coletadaEm: horario,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(fila.sincronizar(forcar: true));
    }
  }

  Future<void> encerrar() async {
    _timer?.cancel();
    await _auth?.cancel();
    WidgetsBinding.instance.removeObserver(this);
  }
}

class AvisoSincronizacao extends StatelessWidget {
  const AvisoSincronizacao({super.key, required this.fila});
  final FilaBengala fila;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: fila.pendentes,
      builder: (context, quantidade, _) {
        if (quantidade == 0) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: CupertinoColors.systemYellow.resolveFrom(context),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Icon(
                CupertinoIcons.cloud_upload,
                color: CupertinoColors.black,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$quantidade leitura(s) salva(s) no celular. '
                  'Enviando assim que possível.',
                  style: const TextStyle(
                    color: CupertinoColors.black,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
