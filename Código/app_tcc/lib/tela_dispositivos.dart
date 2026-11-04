import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'tela_emergencias.dart';

class TelaDispositivos extends StatefulWidget {
  const TelaDispositivos({super.key});

  @override
  State<TelaDispositivos> createState() => _TelaDispositivosState();
}

class _TelaDispositivosState extends State<TelaDispositivos> {
  final _supabase = Supabase.instance.client;
  final MapController _mapController = MapController();

  Timer? _timerAtualizacao; // Temporizador para atualizar a cada 10 segundos

  int _dispositivoSelecionado = 0;
  List<Map<String, dynamic>> _bengalas = [];
  bool _carregandoInicial = true;
  bool _buscando = false;
  bool _mapaPronto = false;

  @override
  void initState() {
    super.initState();
    _buscarDadosEmTempoReal(); // Busca imediatamente ao abrir a tela

    // Configura a atualização automática a cada 10 segundos
    _timerAtualizacao = Timer.periodic(const Duration(seconds: 10), (timer) {
      _buscarDadosEmTempoReal();
    });
  }

  @override
  void dispose() {
    // É crucial cancelar o temporizador quando saímos da tela para não gastar bateria/memória
    _timerAtualizacao?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  Future<void> _buscarDadosEmTempoReal() async {
    if (_buscando || !mounted) return;
    if (_bengalas.isEmpty) {
      if (mounted) setState(() => _carregandoInicial = true);
    }

    final userId = _supabase.auth.currentUser?.id;
    if (userId == null) {
      setState(() => _carregandoInicial = false);
      return;
    }
    _buscando = true;
    try {
      final membro = await _supabase
          .from('membros_grupo')
          .select('grupo_id')
          .eq('user_id', userId)
          .maybeSingle();

      if (membro == null) {
        if (mounted) {
          setState(() {
            _bengalas = [];
            _mapaPronto = false;
            _carregandoInicial = false;
          });
        }
        return;
      }

      final grupoId = membro['grupo_id'];
      final dispositivosData = await _supabase
          .from('dispositivos')
          .select()
          .eq('grupo_id', grupoId);
      List<Map<String, dynamic>> bengalasFormatadas = [];

      for (var disp in dispositivosData) {
        final rotaData = await _supabase
            .from('historico_posicoes')
            .select('latitude, longitude')
            .eq('dispositivo_id', disp['id'])
            .order('registado_em', ascending: true);

        List<LatLng> rota = rotaData
            .map(
              (p) => LatLng(
                (p['latitude'] as num).toDouble(),
                (p['longitude'] as num).toDouble(),
              ),
            )
            .toList();

        String dataSinc = 'Sem dados';
        if (disp['ultima_sincronizacao'] != null) {
          final dataLocal = DateTime.parse(disp['ultima_sincronizacao'])
              .toLocal();
          dataSinc =
              '${dataLocal.day}/${dataLocal.month} ${dataLocal.hour}:${dataLocal.minute.toString().padLeft(2, '0')}';
        }

        bengalasFormatadas.add({
          'id': disp['id'],
          'nome': disp['nome'],
          'bateria': disp['bateria'] ?? 0,
          'kmDiario':
              (disp['km_diario'] as num?)?.toDouble().toStringAsFixed(1) ??
              '0.0',
          'kmSemanal':
              (disp['km_semanal'] as num?)?.toDouble().toStringAsFixed(1) ??
              '0.0',
          'emergencias':
              disp['emergencias_pendentes'] ?? disp['emergencias'] ?? 0,
          'ultimaSincronizacao': dataSinc,

          'localizacaoAtual':
              disp['latitude_atual'] != null && disp['longitude_atual'] != null
              ? LatLng(
                  (disp['latitude_atual'] as num).toDouble(),
                  (disp['longitude_atual'] as num).toDouble(),
                )
              : (rota.isNotEmpty
                    ? rota.last
                    : const LatLng(-29.4589, -51.9616)),
          'rota': rota,

          'dist1': disp['dist1'] ?? 0,
          'dist2': disp['dist2'] ?? 0,
          'dist3': disp['dist3'] ?? 0,
          'ax': (disp['ax'] as num?)?.toDouble() ?? 0.0,
          'ay': (disp['ay'] as num?)?.toDouble() ?? 0.0,
          'az': (disp['az'] as num?)?.toDouble() ?? 0.0,
        });
      }

      if (mounted) {
        setState(() {
          _bengalas = bengalasFormatadas;
          if (_bengalas.isEmpty) _mapaPronto = false;
          if (_dispositivoSelecionado >= _bengalas.length) {
            _dispositivoSelecionado = 0;
          }
          _carregandoInicial = false;
        });

        if (_mapaPronto &&
            _bengalas.isNotEmpty &&
            _bengalas.length > _dispositivoSelecionado) {
          _mapController.move(
            _bengalas[_dispositivoSelecionado]['localizacaoAtual'],
            _mapController.camera.zoom,
          );
        }
      }
    } catch (e) {
      debugPrint('Erro ao buscar bengalas: $e');
      if (mounted) setState(() => _carregandoInicial = false);
    } finally {
      _buscando = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Monitorização'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _buscarDadosEmTempoReal, // Mantém o botão manual para quem quiser forçar atualização imediata
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: _carregandoInicial
            ? const Center(child: CupertinoActivityIndicator())
            : _bengalas.isEmpty
            ? _construirTelaVazia()
            : _construirPainelMonitorizacao(),
      ),
    );
  }

  Widget _construirTelaVazia() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: const [
            Icon(
              CupertinoIcons.map_pin_slash,
              size: 80,
              color: CupertinoColors.systemGrey,
            ),
            SizedBox(height: 20),
            Text(
              'Nenhuma bengala conectada.',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: CupertinoColors.black,
              ),
            ),
            SizedBox(height: 10),
            Text(
              'Garante que criaste um grupo e que o ESP32 foi registado na base de dados.',
              textAlign: TextAlign.center,
              style: TextStyle(color: CupertinoColors.systemGrey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _construirPainelMonitorizacao() {
    if (_dispositivoSelecionado >= _bengalas.length) {
      _dispositivoSelecionado = 0;
    }

    final dispositivo = _bengalas[_dispositivoSelecionado];
    final temEmergencia = (dispositivo['emergencias'] as int) > 0;

    return Column(
      children: [
        if (_bengalas.length > 1)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            color: CupertinoColors.white,
            child: CupertinoSlidingSegmentedControl<int>(
              groupValue: _dispositivoSelecionado,
              children: {
                for (int i = 0; i < _bengalas.length; i++)
                  i: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      _bengalas[i]['nome'],
                      style: const TextStyle(color: CupertinoColors.black),
                    ),
                  ),
              },
              onValueChanged: (int? valor) {
                if (valor != null) {
                  setState(() => _dispositivoSelecionado = valor);
                  _mapController.move(
                    _bengalas[valor]['localizacaoAtual'],
                    15.0,
                  );
                }
              },
            ),
          ),

        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () async {
                  await Navigator.of(context).push(
                    CupertinoPageRoute<void>(
                      builder: (_) => TelaEmergencias(
                        dispositivoId: dispositivo['id'].toString(),
                        nomeDispositivo:
                            dispositivo['nome']?.toString() ?? 'Bengala',
                      ),
                    ),
                  );
                  if (mounted) await _buscarDadosEmTempoReal();
                },
                child: Container(
                  margin: const EdgeInsets.only(bottom: 16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color:
                        (temEmergencia
                                ? CupertinoColors.destructiveRed
                                : CupertinoColors.activeBlue)
                            .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        CupertinoIcons.exclamationmark_triangle_fill,
                        color: temEmergencia
                            ? CupertinoColors.destructiveRed
                            : CupertinoColors.activeBlue,
                        size: 30,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              temEmergencia
                                  ? 'NOTIFICAÇÕES DE EMERGÊNCIA'
                                  : 'Emergências',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            Text(
                              temEmergencia
                                  ? "${dispositivo['emergencias']} alerta(s) pendente(s). Toque para ver."
                                  : 'Nenhum alerta pendente. Toque para abrir.',
                            ),
                          ],
                        ),
                      ),
                      const Icon(CupertinoIcons.chevron_right, size: 20),
                    ],
                  ),
                ),
              ),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: CupertinoColors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Dados de Atividade',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: CupertinoColors.black,
                          ),
                        ),
                        Row(
                          children: [
                            Icon(
                              dispositivo['bateria'] > 20
                                  ? CupertinoIcons.battery_100
                                  : CupertinoIcons.battery_0,
                              color: dispositivo['bateria'] > 20
                                  ? CupertinoColors.activeGreen
                                  : CupertinoColors.destructiveRed,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${dispositivo['bateria']}%',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                color: CupertinoColors.black,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        _construirDadoEstatistico(
                          'Hoje',
                          '${dispositivo['kmDiario']} km',
                          CupertinoIcons.arrow_right_circle,
                        ),
                        _construirDadoEstatistico(
                          'Esta Semana',
                          '${dispositivo['kmSemanal']} km',
                          CupertinoIcons.calendar,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Última atualização: ${dispositivo['ultimaSincronizacao']}',
                      style: const TextStyle(
                        color: CupertinoColors.systemGrey,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: CupertinoColors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Sensores de Obstáculos (mm)',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: CupertinoColors.black,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        // ATUALIZAÇÃO DOS NOMES E ÍCONES (Superior, Central, Inferior)
                        _construirDadoEstatistico(
                          'Superior',
                          '${dispositivo['dist1']}',
                          CupertinoIcons.chevron_up,
                        ),
                        _construirDadoEstatistico(
                          'Central',
                          '${dispositivo['dist2']}',
                          CupertinoIcons.minus,
                        ),
                        _construirDadoEstatistico(
                          'Inferior',
                          '${dispositivo['dist3']}',
                          CupertinoIcons.chevron_down,
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),
                    Container(height: 1, color: CupertinoColors.systemGrey4),
                    const SizedBox(height: 12),

                    const Text(
                      'Telemetria (Acelerómetro)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'X: ${dispositivo['ax'].toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            color: CupertinoColors.black,
                          ),
                        ),
                        Text(
                          'Y: ${dispositivo['ay'].toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            color: CupertinoColors.black,
                          ),
                        ),
                        Text(
                          'Z: ${dispositivo['az'].toStringAsFixed(2)}',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            color: CupertinoColors.black,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              Container(
                decoration: BoxDecoration(
                  color: CupertinoColors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                clipBehavior: Clip.hardEdge,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        'Rota e Localização Atual',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: CupertinoColors.black,
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 300,
                      child: FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: dispositivo['localizacaoAtual'],
                          initialZoom: 15.0,
                          onMapReady: () => _mapaPronto = true,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.apptcc.app',
                          ),
                          PolylineLayer(
                            polylines: [
                              Polyline(
                                points: dispositivo['rota'],
                                strokeWidth: 4.0,
                                color: CupertinoColors.activeBlue,
                              ),
                            ],
                          ),
                          MarkerLayer(
                            markers: [
                              Marker(
                                point: dispositivo['localizacaoAtual'],
                                width: 40,
                                height: 40,
                                child: const Icon(
                                  CupertinoIcons.location_solid,
                                  color: CupertinoColors.destructiveRed,
                                  size: 40,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ],
    );
  }

  Widget _construirDadoEstatistico(
    String titulo,
    String valor,
    IconData icone,
  ) {
    return Column(
      children: [
        Icon(icone, color: CupertinoColors.activeBlue, size: 30),
        const SizedBox(height: 8),
        Text(
          valor,
          style: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: CupertinoColors.black,
          ),
        ),
        Text(titulo, style: const TextStyle(color: CupertinoColors.systemGrey)),
      ],
    );
  }
}
