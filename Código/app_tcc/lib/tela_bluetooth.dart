import 'dart:async';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'sincronizacao_bengala.dart';

class TelaBluetooth extends StatefulWidget {
  const TelaBluetooth({super.key});

  @override
  State<TelaBluetooth> createState() => _TelaBluetoothState();
}

class _TelaBluetoothState extends State<TelaBluetooth>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  bool _isScanning = false;
  List<ScanResult> _resultadosBusca = [];

  StreamSubscription<List<ScanResult>>? _scanResultsSubscription;
  StreamSubscription<bool>? _isScanningSubscription;
  final Map<String, StreamSubscription<BluetoothConnectionState>> _conexoes =
      {};
  final Map<String, StreamSubscription<void>> _sensores = {};
  bool _avisoFalhaLocal = false;

  // ==========================================
  // NOVOS CONTROLOS DE ESTADO E RECONEXÃO
  // ==========================================
  final Set<String> _conectando = {}; // Evita cliques duplos
  final Set<String> _desconectandoManualmente =
      {}; // Para saber se foi o utilizador a desligar
  final Map<String, Timer> _timersReconexao =
      {}; // Controla os temporizadores de reconexão
  final Map<String, int> _tentativasReconexao = {}; // Conta as 10 tentativas
  // ==========================================

  @override
  void initState() {
    super.initState();
    _isScanningSubscription = FlutterBluePlus.isScanning.listen((estado) {
      if (mounted) {
        setState(() {
          _isScanning = estado;
        });
      }
    });
  }

  @override
  void dispose() {
    _scanResultsSubscription?.cancel();
    _isScanningSubscription?.cancel();
    for (final subscription in _conexoes.values) {
      subscription.cancel();
    }
    for (final subscription in _sensores.values) {
      subscription.cancel();
    }
    FlutterBluePlus.stopScan();

    // Limpa todos os temporizadores para não gastar memória/bateria se a tela for fechada
    for (var timer in _timersReconexao.values) {
      timer.cancel();
    }
    _timersReconexao.clear();

    super.dispose();
  }

  void _mostrarAlerta(String titulo, String mensagem) {
    if (!mounted) return;
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: Text(titulo),
        content: Text(mensagem),
        actions: [
          CupertinoDialogAction(
            child: const Text('OK'),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Future<void> _verificarEIniciarBusca() async {
    if (Platform.isWindows) return;
    if (_isScanning) return;

    if (await FlutterBluePlus.isSupported == false) {
      debugPrint("Bluetooth não suportado neste dispositivo.");
      return;
    }

    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        debugPrint("Erro ao tentar ligar o Bluetooth: $e");
      }
    }

    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        await Future.delayed(const Duration(milliseconds: 500));
      }

      if (!mounted) return;
      setState(() {
        _resultadosBusca.removeWhere((r) => !r.device.isConnected);
      });

      await _scanResultsSubscription?.cancel();
      if (!mounted) return;

      _scanResultsSubscription = FlutterBluePlus.scanResults.listen(
        (resultados) {
          if (mounted) {
            setState(() {
              final porId = {
                for (final r in _resultadosBusca.where(
                  (r) => r.device.isConnected,
                ))
                  r.device.remoteId.str: r,
                for (final r in resultados) r.device.remoteId.str: r,
              };
              _resultadosBusca = porId.values.toList();
            });
          }
        },
        onError: (e) {
          debugPrint('Erro nativo durante o scan: $e');
        },
      );

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 10),
        androidUsesFineLocation: true,
      );
    } catch (e) {
      debugPrint('Falha crítica ao executar o scan: $e');
    }
  }

  Future<bool> _registarDispositivoNoBanco(BluetoothDevice dispositivo) async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    final fila = DadosBengalaService.instancia!.fila;
    if (user == null) return false;
    final mac = dispositivo.remoteId.str;
    // Um vínculo confirmado anteriormente permite conectar sem acessar a rede.
    if (await fila.buscarVinculo(user.id, mac) != null) return true;
    try {
      final membro = await supabase
          .from('membros_grupo')
          .select('grupo_id')
          .eq('user_id', user.id)
          .maybeSingle()
          .timeout(const Duration(seconds: 10));
      if (membro == null) {
        _mostrarAlerta(
          'Sem grupo',
          'Crie ou entre em um grupo antes de vincular a bengala.',
        );
        return false;
      }
      final existente = await supabase
          .from('dispositivos')
          .select('id')
          .eq('grupo_id', membro['grupo_id'])
          .eq('mac_address', mac)
          .maybeSingle()
          .timeout(const Duration(seconds: 10));
      final String id;
      if (existente != null) {
        id = existente['id'].toString();
      } else {
        final criado = await supabase
            .from('dispositivos')
            .insert({
              'grupo_id': membro['grupo_id'],
              'nome': dispositivo.platformName.isNotEmpty
                  ? dispositivo.platformName
                  : 'Bengala ESP32',
              'mac_address': mac,
              'bateria': 100,
              'emergencias': 0,
              'is_online': false,
            })
            .select('id')
            .single()
            .timeout(const Duration(seconds: 10));
        id = criado['id'].toString();
      }
      await fila.guardarVinculo(user.id, mac, id);
      return true;
    } catch (_) {
      _mostrarAlerta(
        'Primeiro vínculo precisa de internet',
        'Não foi possível acessar o banco. Conecte-se uma vez para vincular '
            'esta bengala; depois as leituras poderão ser guardadas offline.',
      );
      return false;
    }
  }

  // Lógica de Reconexão Automática
  void _iniciarReconexaoAutomatica(BluetoothDevice dispositivo) {
    final mac = dispositivo.remoteId.str;

    // Cancela o timer anterior se existir
    _timersReconexao[mac]?.cancel();
    _tentativasReconexao.putIfAbsent(mac, () => 0);

    _timersReconexao[mac] = Timer.periodic(const Duration(minutes: 1), (
      timer,
    ) async {
      if (!mounted || _desconectandoManualmente.contains(mac)) {
        timer.cancel();
        return;
      }

      int tentativasAtuais = _tentativasReconexao[mac] ?? 0;

      // Se já conectou ou chegou ao limite de 10 tentativas, desliga o timer
      if (dispositivo.isConnected || tentativasAtuais >= 10) {
        timer.cancel();
        return;
      }

      if (_conectando.contains(mac)) return;
      _tentativasReconexao[mac] = tentativasAtuais + 1;
      debugPrint(
        "🔄 Tentativa automática ${tentativasAtuais + 1}/10 para ligar à bengala $mac...",
      );

      _conectando.add(mac);
      try {
        await dispositivo.connect(timeout: const Duration(seconds: 5));
        if (dispositivo.isConnected && mounted) {
          debugPrint("✅ Reconexão automática bem sucedida!");
          timer.cancel();

          if (Platform.isAndroid) {
            try {
              await dispositivo.requestMtu(512);
            } catch (_) {}
          }

          // Como reconectou, precisamos de reativar a escuta dos sensores
          await _iniciarEscutaDeSensores(dispositivo);

          // Força a atualização visual para a bengala saltar para o topo
          if (mounted) setState(() {});
        }
      } catch (e) {
        debugPrint("❌ Falha na reconexão: $e");
        if (mounted && !_desconectandoManualmente.contains(mac)) {
          try {
            await dispositivo.disconnect();
          } catch (_) {}
          _iniciarReconexaoAutomatica(dispositivo);
        }
      } finally {
        _conectando.remove(mac);
        if (mounted) setState(() {});
      }
    });
  }

  Future<void> _iniciarEscutaDeSensores(BluetoothDevice dispositivo) async {
    final supabase = Supabase.instance.client;
    final user = supabase.auth.currentUser;
    if (user == null) return;

    final macAddress = dispositivo.remoteId.str;

    // Se ligou com sucesso, cancelamos qualquer reconexão pendente
    _timersReconexao[macAddress]?.cancel();

    final servico = DadosBengalaService.instancia!;
    final idGeradoPeloBanco = await servico.fila.buscarVinculo(
      user.id,
      macAddress,
    );
    if (idGeradoPeloBanco == null) {
      throw StateError('Vincule a bengala antes de receber as leituras.');
    }
    try {
      // MONITOR DE QUEDA DE CONEXÃO
      if (!mounted) return;
      await _conexoes.remove(macAddress)?.cancel();
      await _sensores.remove(macAddress)?.cancel();
      if (!mounted) return;
      _conexoes[macAddress] = dispositivo.connectionState.listen((
        estado,
      ) async {
        if (!mounted) return;
        if (estado == BluetoothConnectionState.disconnected) {
          await _sensores.remove(macAddress)?.cancel();
          if (!mounted) return;
          if (!_desconectandoManualmente.contains(macAddress)) {
            _iniciarReconexaoAutomatica(dispositivo);
          }
          try {
            await servico.fila.salvar(
              usuarioId: user.id,
              dispositivoId: idGeradoPeloBanco,
              dados: {'is_online': false},
            );
          } catch (e) {
            debugPrint("Erro ao tentar colocar offline no banco: $e");
          }

          // Atualiza a tela para reordenar a lista
          if (mounted) setState(() {});
        }
      });

      List<BluetoothService> servicos = await dispositivo.discoverServices();

      const uuidServico = "4fafc201-1fb5-459e-8fcc-c5c9c331914b";
      const uuidCaracteristica = "beb5483e-36e1-4688-b7f5-ea07361b26a8";

      BluetoothCharacteristic? caracteristicaAlvo;

      for (BluetoothService s in servicos) {
        if (s.uuid.toString() == uuidServico) {
          for (BluetoothCharacteristic c in s.characteristics) {
            if (c.uuid.toString() == uuidCaracteristica) {
              caracteristicaAlvo = c;
            }
          }
        }
      }

      if (caracteristicaAlvo == null) {
        throw StateError(
          'Serviço de sensores BLE não encontrado. Verifique o código do ESP32.',
        );
      }

      if (!mounted) return;

      _sensores[macAddress] = caracteristicaAlvo.onValueReceived
          .asyncMap<void>((bytes) async {
            if (!mounted || supabase.auth.currentUser?.id != user.id) return;
            try {
              // Aguarda apenas a gravação no celular; a rede é independente.
              await servico.receber(idGeradoPeloBanco, bytes);
              _avisoFalhaLocal = false;
            } catch (e) {
              debugPrint('Não foi possível guardar a leitura: $e');
              if (!_avisoFalhaLocal) {
                _avisoFalhaLocal = true;
                _mostrarAlerta(
                  'Falha ao guardar dados no celular',
                  'Verifique o espaço livre. Esta leitura não pôde ser salva.',
                );
              }
            }
          })
          .listen(
            (_) {},
            onError: (Object e) {
              debugPrint('Erro no fluxo de sensores: $e');
            },
          );
      await caracteristicaAlvo.setNotifyValue(true);
      if (!mounted || supabase.auth.currentUser?.id != user.id) return;
      await servico.fila.salvar(
        usuarioId: user.id,
        dispositivoId: idGeradoPeloBanco,
        dados: {'is_online': true},
      );
      _tentativasReconexao[macAddress] = 0;
    } catch (_) {
      await _sensores.remove(macAddress)?.cancel();
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (Platform.isWindows) {
      return CupertinoPageScaffold(
        backgroundColor: CupertinoColors.systemGroupedBackground,
        navigationBar: const CupertinoNavigationBar(
          middle: Text('Configurar ESP32'),
        ),
        child: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(20.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    CupertinoIcons.desktopcomputer,
                    size: 90,
                    color: CupertinoColors.systemGrey,
                  ),
                  const SizedBox(height: 20),
                  const Text(
                    'Bluetooth Indisponível',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'A comunicação com a bengala (ESP32) requer as antenas móveis nativas de um telemóvel real.\n\nPor favor, usa o Pair Devices over Wi-Fi ou instala o APK no teu dispositivo Android.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: CupertinoColors.systemGrey,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    // ORDENAÇÃO INTELIGENTE: Puxa os dispositivos conectados para o topo
    final listaOrdenada = List<ScanResult>.from(_resultadosBusca);
    listaOrdenada.sort((a, b) {
      final aConectado = a.device.isConnected ? 1 : 0;
      final bConectado = b.device.isConnected ? 1 : 0;
      return bConectado.compareTo(aConectado);
    });

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Radar Bluetooth'),
      ),
      child: SafeArea(
        child: Stack(
          children: [
            listaOrdenada.isEmpty
                ? _construirTelaVazia()
                : ListView.builder(
                    padding: const EdgeInsets.only(top: 16, bottom: 200),
                    itemCount: listaOrdenada.length,
                    itemBuilder: (context, index) {
                      final dispositivo = listaOrdenada[index].device;
                      final macAddress = dispositivo.remoteId.str;
                      final nomeOriginal = dispositivo.platformName;
                      final advName =
                          listaOrdenada[index].advertisementData.advName;

                      String nomeExibicao = 'Dispositivo Sem Nome';
                      if (nomeOriginal.isNotEmpty) {
                        nomeExibicao = nomeOriginal;
                      } else if (advName.isNotEmpty) {
                        nomeExibicao = advName;
                      }

                      return Container(
                        margin: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: CupertinoColors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            const Icon(
                              CupertinoIcons.bluetooth,
                              color: CupertinoColors.activeBlue,
                              size: 30,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    nomeExibicao,
                                    style: const TextStyle(
                                      color: CupertinoColors.black,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 16,
                                    ),
                                  ),
                                  Text(
                                    macAddress,
                                    style: const TextStyle(
                                      color: CupertinoColors.systemGrey,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            StreamBuilder<BluetoothConnectionState>(
                              stream: dispositivo.connectionState,
                              initialData:
                                  BluetoothConnectionState.disconnected,
                              builder: (context, snapshot) {
                                // ESTADO: CONECTADO (Botão Vermelho)
                                if (snapshot.data ==
                                    BluetoothConnectionState.connected) {
                                  return CupertinoButton(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 6,
                                    ),
                                    color: CupertinoColors.destructiveRed
                                        .withValues(alpha: 0.1),
                                    onPressed: () async {
                                      // Avisa o sistema que o botão foi clicado manualmente para não reconectar
                                      _desconectandoManualmente.add(macAddress);

                                      try {
                                        await dispositivo.disconnect();
                                      } catch (e) {
                                        _mostrarAlerta(
                                          'Erro ao desconectar',
                                          e.toString(),
                                        );
                                      }
                                      _timersReconexao
                                          .remove(macAddress)
                                          ?.cancel();

                                      if (mounted) setState(() {});
                                    },
                                    child: const Text(
                                      'Desconectar',
                                      style: TextStyle(
                                        color: CupertinoColors.destructiveRed,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  );
                                }

                                // ESTADO: A CONECTAR (Activity Indicator + Bloqueio de cliques duplos)
                                if (_conectando.contains(macAddress)) {
                                  return Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: CupertinoColors.systemGrey5,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: const Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        CupertinoActivityIndicator(radius: 8),
                                        SizedBox(width: 8),
                                        Text(
                                          'A ligar...',
                                          style: TextStyle(
                                            color: CupertinoColors.systemGrey,
                                            fontSize: 14,
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }

                                // ESTADO: DESCONECTADO (Botão Azul)
                                return CupertinoButton(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 6,
                                  ),
                                  color: CupertinoColors.activeBlue.withValues(
                                    alpha: 0.1,
                                  ),
                                  onPressed: () async {
                                    // Bloqueia e mostra "A ligar..."
                                    _desconectandoManualmente.remove(
                                      macAddress,
                                    );
                                    _timersReconexao
                                        .remove(macAddress)
                                        ?.cancel();
                                    setState(() => _conectando.add(macAddress));

                                    try {
                                      if (FlutterBluePlus.isScanningNow) {
                                        await FlutterBluePlus.stopScan();
                                      }

                                      await dispositivo.connect();

                                      if (Platform.isAndroid) {
                                        try {
                                          await dispositivo.requestMtu(512);
                                        } catch (_) {}
                                      }

                                      if (!context.mounted) {
                                        await dispositivo.disconnect();
                                        return;
                                      }
                                      _tentativasReconexao[macAddress] = 0;
                                      bool salvoComSucesso =
                                          await _registarDispositivoNoBanco(
                                            dispositivo,
                                          );

                                      if (!salvoComSucesso) {
                                        await dispositivo.disconnect();
                                        return;
                                      }

                                      if (context.mounted) {
                                        await _iniciarEscutaDeSensores(
                                          dispositivo,
                                        );
                                        if (!context.mounted) return;

                                        // Atualiza estado para que a lista seja reordenada puxando para o topo
                                        if (mounted) setState(() {});

                                        showCupertinoDialog(
                                          context: context,
                                          builder: (context) =>
                                              CupertinoAlertDialog(
                                                title: const Text(
                                                  'Bengala conectada',
                                                ),
                                                content: Text(
                                                  'A bengala ($nomeExibicao) está conectada. As leituras serão salvas no celular e sincronizadas assim que possível.',
                                                ),
                                                actions: [
                                                  CupertinoDialogAction(
                                                    child: const Text('OK'),
                                                    onPressed: () =>
                                                        Navigator.pop(context),
                                                  ),
                                                ],
                                              ),
                                        );
                                      }
                                    } catch (e) {
                                      _desconectandoManualmente.add(macAddress);
                                      _timersReconexao
                                          .remove(macAddress)
                                          ?.cancel();
                                      try {
                                        await dispositivo.disconnect();
                                      } catch (_) {}
                                      if (context.mounted) {
                                        _mostrarAlerta(
                                          'Erro de Conexão Física',
                                          'Não foi possível ligar ao Bluetooth da bengala: $e',
                                        );
                                      }
                                    } finally {
                                      // Remove o bloqueio visual de carregamento, independentemente de erro ou sucesso
                                      if (mounted) {
                                        setState(
                                          () => _conectando.remove(macAddress),
                                        );
                                      }
                                    }
                                  },
                                  child: const Text(
                                    'Conectar',
                                    style: TextStyle(
                                      color: CupertinoColors.activeBlue,
                                      fontSize: 14,
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),

            Positioned(
              bottom: 120,
              right: 20,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: _isScanning ? null : _verificarEIniciarBusca,
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: _isScanning
                        ? CupertinoColors.systemGrey
                        : CupertinoColors.activeBlue,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: CupertinoColors.black.withValues(alpha: 0.2),
                        blurRadius: 10,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: _isScanning
                      ? const CupertinoActivityIndicator(
                          color: CupertinoColors.white,
                        )
                      : const Icon(
                          CupertinoIcons.search,
                          color: CupertinoColors.white,
                          size: 30,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _construirTelaVazia() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isScanning
                  ? CupertinoIcons.antenna_radiowaves_left_right
                  : CupertinoIcons.bluetooth,
              size: 80,
              color: _isScanning
                  ? CupertinoColors.activeBlue
                  : CupertinoColors.systemGrey,
            ),
            const SizedBox(height: 20),
            Text(
              _isScanning
                  ? 'A procurar dispositivos...'
                  : 'Pronto para emparelhar',
              style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            Text(
              _isScanning
                  ? 'A procurar sinais BLE.'
                  : 'Clica na lupa para iniciar o radar Bluetooth.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: CupertinoColors.systemGrey),
            ),
          ],
        ),
      ),
    );
  }
}
