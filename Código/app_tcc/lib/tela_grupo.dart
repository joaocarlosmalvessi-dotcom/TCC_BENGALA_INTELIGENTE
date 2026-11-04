import 'dart:async';
import 'dart:math';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class TelaGrupo extends StatefulWidget {
  const TelaGrupo({super.key});

  @override
  State<TelaGrupo> createState() => _TelaGrupoState();
}

class _TelaGrupoState extends State<TelaGrupo> {
  final _supabase = Supabase.instance.client;
  final _codigoController = TextEditingController();

  String? _grupoIdAtual;
  String? _codigoGrupoAtual;
  List<String> _participantes = [];
  List<Map<String, dynamic>> _dispositivos = [];
  bool _carregando = true;

  Timer? _timerAtualizacao;

  @override
  void initState() {
    super.initState();
    _buscarMeuGrupo();

    // Atualiza apenas a lista de dispositivos a cada 5s, sem tela de carregamento (silencioso)
    _timerAtualizacao = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_grupoIdAtual != null && mounted) {
        _atualizarDispositivosSilenciosamente();
      }
    });
  }

  @override
  void dispose() {
    _timerAtualizacao?.cancel();
    _codigoController.dispose();
    super.dispose();
  }

  Future<void> _buscarMeuGrupo() async {
    if (mounted) setState(() => _carregando = true);
    final user = _supabase.auth.currentUser;

    if (user != null) {
      try {
        // Aumentado para 15 segundos para dar tempo do Supabase "acordar"
        final membro = await _supabase
            .from('membros_grupo')
            .select('grupo_id')
            .eq('user_id', user.id)
            .maybeSingle()
            .timeout(const Duration(seconds: 15));

        if (membro != null && membro['grupo_id'] != null) {
          final grupoId = membro['grupo_id'];
          _grupoIdAtual = grupoId.toString();

          final resultados = await Future.wait<dynamic>([
            _supabase
                .from('grupos')
                .select('codigo')
                .eq('id', grupoId)
                .maybeSingle(),
            _supabase
                .from('membros_grupo')
                .select('user_id')
                .eq('grupo_id', grupoId),
            _supabase
                .from('dispositivos')
                .select('nome, ultima_sincronizacao')
                .eq('grupo_id', grupoId),
          ]).timeout(const Duration(seconds: 15)); // Aumentado para 15 segundos

          final grupo = resultados[0];
          if (grupo is Map) {
            _codigoGrupoAtual = grupo['codigo']?.toString();
          }

          final membrosData = resultados[1];
          if (membrosData is List) {
            _participantes = membrosData
                .map((m) => m['user_id'].toString())
                .toList();
          }

          final dispData = resultados[2];
          if (dispData is List) {
            _dispositivos = dispData
                .map((e) => Map<String, dynamic>.from(e as Map))
                .toList();
          }
        } else {
          _grupoIdAtual = null;
          _codigoGrupoAtual = null;
          _participantes = [];
          _dispositivos = [];
        }
      } on TimeoutException catch (_) {
        debugPrint(
          "Aviso: A conexão com o banco de dados está lenta (Timeout).",
        );
      } catch (e) {
        debugPrint("Erro ao buscar grupo: $e");
      }
    }

    if (mounted) setState(() => _carregando = false);
  }

  Future<void> _atualizarDispositivosSilenciosamente() async {
    if (_grupoIdAtual == null) return;
    try {
      // Aumentado para 10 segundos para lidar com oscilações de rede no fundo
      final dispositivosData = await _supabase
          .from('dispositivos')
          .select('nome, ultima_sincronizacao')
          .eq('grupo_id', _grupoIdAtual as Object)
          .timeout(const Duration(seconds: 10));

      if (mounted) {
        setState(() {
          _dispositivos = dispositivosData
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList();
        });
      }
    } on TimeoutException catch (_) {
      // Apenas ignora silenciosamente se a atualização de fundo demorar muito
    } catch (e) {
      debugPrint("Erro ao atualizar dispositivos no background: $e");
    }
  }

  Future<void> _gerarCodigo() async {
    if (mounted) setState(() => _carregando = true);
    final user = _supabase.auth.currentUser!;

    const letras = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random();
    final novoCodigo = String.fromCharCodes(
      Iterable.generate(
        6,
        (_) => letras.codeUnitAt(random.nextInt(letras.length)),
      ),
    );

    try {
      final grupo = await _supabase
          .from('grupos')
          .insert({'codigo': novoCodigo})
          .select()
          .single();
      await _supabase.from('membros_grupo').insert({
        'grupo_id': grupo['id'],
        'user_id': user.id,
      });
      await _buscarMeuGrupo();
    } catch (e) {
      _mostrarAlerta('Erro ao Gerar Código', 'Tente novamente em instantes.');
      if (mounted) setState(() => _carregando = false);
    }
  }

  Future<void> _entrarGrupo() async {
    final codigo = _codigoController.text.trim().toUpperCase();
    if (codigo.isEmpty) return;

    if (mounted) setState(() => _carregando = true);
    final user = _supabase.auth.currentUser!;
    try {
      final grupo = await _supabase
          .from('grupos')
          .select('id')
          .eq('codigo', codigo)
          .maybeSingle();
      if (grupo == null) {
        _mostrarAlerta('Erro', 'Grupo não encontrado com este código.');
      } else {
        await _supabase.from('membros_grupo').insert({
          'grupo_id': grupo['id'],
          'user_id': user.id,
        });
        await _buscarMeuGrupo();
      }
    } catch (e) {
      _mostrarAlerta('Erro', 'Código inválido ou você já está neste grupo.');
    }
    if (mounted) setState(() => _carregando = false);
  }

  Future<void> _sairDoGrupoConfirmado() async {
    if (mounted) setState(() => _carregando = true);
    final user = _supabase.auth.currentUser!;
    try {
      await _supabase.from('membros_grupo').delete().eq('user_id', user.id);
      await _buscarMeuGrupo();
    } catch (e) {
      _mostrarAlerta('Erro', 'Não foi possível sair do grupo.');
      if (mounted) setState(() => _carregando = false);
    }
  }

  void _confirmarSaida() {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Sair do Grupo'),
        content: const Text('Tem certeza que deseja sair?'),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            child: const Text('Cancelar'),
            onPressed: () => Navigator.pop(context),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.pop(context);
              _sairDoGrupoConfirmado();
            },
            child: const Text('Sim, sair'),
          ),
        ],
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Meu Grupo'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _buscarMeuGrupo,
          child: const Icon(CupertinoIcons.refresh),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: _carregando
              ? const Center(child: CupertinoActivityIndicator())
              : _grupoIdAtual == null
              ? _construirTelaSemGrupo()
              : _construirTelaComGrupo(),
        ),
      ),
    );
  }

  Widget _construirTelaSemGrupo() {
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          CupertinoTextField(
            controller: _codigoController,
            placeholder: 'Código do Grupo',
            padding: const EdgeInsets.all(16),
            textCapitalization: TextCapitalization.characters,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          CupertinoButton.filled(
            onPressed: _entrarGrupo,
            child: const Text('Entrar em um Grupo'),
          ),
          const SizedBox(height: 40),
          const Text('Ou crie o seu próprio grupo:'),
          const SizedBox(height: 16),
          CupertinoButton(
            onPressed: _gerarCodigo,
            child: const Text('Gerar Novo Código de Grupo'),
          ),
        ],
      ),
    );
  }

  Widget _construirTelaComGrupo() {
    return SizedBox(
      width: double.infinity,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 10),
          const Icon(
            CupertinoIcons.group_solid,
            size: 70,
            color: CupertinoColors.activeBlue,
          ),
          const SizedBox(height: 10),
          const Text('Você está no grupo:', style: TextStyle(fontSize: 16)),

          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _codigoGrupoAtual ?? '',
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.bold,
                ),
              ),
              CupertinoButton(
                padding: const EdgeInsets.only(left: 10),
                child: const Icon(CupertinoIcons.doc_on_clipboard, size: 28),
                onPressed: () {
                  if (_codigoGrupoAtual != null) {
                    Clipboard.setData(ClipboardData(text: _codigoGrupoAtual!));
                    _mostrarAlerta('Sucesso', 'Código copiado!');
                  }
                },
              ),
            ],
          ),

          const SizedBox(height: 30),

          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      const Text(
                        'Participantes',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        height: 1,
                        color: CupertinoColors.systemGrey5,
                        margin: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      Expanded(
                        child: ListView.builder(
                          itemCount: _participantes.length,
                          itemBuilder: (context, index) {
                            final userId = _participantes[index];
                            final isMe =
                                userId == _supabase.auth.currentUser?.id;

                            final nomeCurto = userId.length >= 4
                                ? userId.substring(0, 4)
                                : userId;
                            final nomeApresentacao = isMe
                                ? "Eu"
                                : "Membro ${nomeCurto.toUpperCase()}";

                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 8.0,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isMe
                                        ? CupertinoIcons.person_solid
                                        : CupertinoIcons.person,
                                    color: isMe
                                        ? CupertinoColors.activeBlue
                                        : CupertinoColors.systemGrey,
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    nomeApresentacao,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(width: 16),

                Expanded(
                  child: Column(
                    children: [
                      const Text(
                        'Dispositivos',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Container(
                        height: 1,
                        color: CupertinoColors.systemGrey5,
                        margin: const EdgeInsets.symmetric(vertical: 8),
                      ),

                      _dispositivos.isEmpty
                          ? const Expanded(
                              child: Center(
                                child: Text(
                                  'Nenhum dispositivo partilhado.',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    color: CupertinoColors.systemGrey,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            )
                          : Expanded(
                              child: ListView.builder(
                                itemCount: _dispositivos.length,
                                itemBuilder: (context, index) {
                                  final disp = _dispositivos[index];
                                  final String nome =
                                      disp['nome']?.toString() ?? 'Bengala';
                                  final ultimaSincRaw =
                                      disp['ultima_sincronizacao'];

                                  bool isOnline = false;
                                  String textoStatus = 'Nunca sincronizou';
                                  Color corStatus = CupertinoColors.systemGrey;

                                  if (ultimaSincRaw != null) {
                                    try {
                                      final dataSinc = DateTime.parse(
                                        ultimaSincRaw.toString(),
                                      ).toLocal();
                                      final agora = DateTime.now();

                                      final diferencaSegundos = agora
                                          .difference(dataSinc)
                                          .inSeconds
                                          .abs();

                                      if (diferencaSegundos <= 30) {
                                        isOnline = true;
                                      }

                                      final dia = dataSinc.day
                                          .toString()
                                          .padLeft(2, '0');
                                      final mes = dataSinc.month
                                          .toString()
                                          .padLeft(2, '0');
                                      final hora = dataSinc.hour
                                          .toString()
                                          .padLeft(2, '0');
                                      final minuto = dataSinc.minute
                                          .toString()
                                          .padLeft(2, '0');

                                      if (isOnline) {
                                        textoStatus = 'Online agora';
                                        corStatus = CupertinoColors.activeGreen;
                                      } else {
                                        textoStatus =
                                            'Visto: $dia/$mes às $hora:$minuto';
                                      }
                                    } catch (e) {
                                      debugPrint("Erro ao calcular tempo: $e");
                                    }
                                  }

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8.0,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isOnline
                                              ? CupertinoIcons.circle_filled
                                              : CupertinoIcons.circle,
                                          color: corStatus,
                                          size: 16,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                nome,
                                                style: const TextStyle(
                                                  fontSize: 14,
                                                  fontWeight: FontWeight.bold,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                              Text(
                                                textoStatus,
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  color: corStatus,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),
          CupertinoButton(
            onPressed: _confirmarSaida,
            child: const Text(
              'Sair do Grupo',
              style: TextStyle(color: CupertinoColors.destructiveRed),
            ),
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}
