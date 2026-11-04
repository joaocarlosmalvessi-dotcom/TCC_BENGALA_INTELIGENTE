import 'dart:async';

import 'package:flutter/cupertino.dart';

import 'emergencias_service.dart';

class TelaEmergencias extends StatefulWidget {
  const TelaEmergencias({
    super.key,
    required this.dispositivoId,
    required this.nomeDispositivo,
    this.repositorio,
  });

  final String dispositivoId;
  final String nomeDispositivo;
  final RepositorioEmergencias? repositorio;

  @override
  State<TelaEmergencias> createState() => _TelaEmergenciasState();
}

class _TelaEmergenciasState extends State<TelaEmergencias> {
  late final RepositorioEmergencias _repositorio;
  List<NotificacaoEmergencia> _notificacoes = [];
  Timer? _timer;
  bool _carregando = true;
  bool _buscando = false;
  bool _limpando = false;
  bool _confirmando = false;
  bool get _ocupado => _limpando || _confirmando;
  String? _erro;

  @override
  void initState() {
    super.initState();
    _repositorio = widget.repositorio ?? EmergenciasService();
    _buscar();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) => _buscar());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _buscar() async {
    if (!mounted || _buscando || _ocupado) return;
    _buscando = true;
    try {
      final notificacoes = await _repositorio.listar(widget.dispositivoId);
      if (!mounted) return;
      setState(() {
        _notificacoes = notificacoes;
        _erro = null;
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => _erro =
              'Não foi possível carregar as emergências. '
              'Verifique a conexão e tente novamente.',
        );
      }
    } finally {
      _buscando = false;
      if (mounted) setState(() => _carregando = false);
    }
  }

  Future<void> _confirmarLimpeza(List<NotificacaoEmergencia> itens) async {
    if (_ocupado || _buscando || itens.isEmpty) return;
    // Captura os IDs antes do diálogo. Alertas novos não serão removidos.
    final ids = itens.map((item) => item.id).toList();
    setState(() => _confirmando = true);
    final confirmou = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Limpar notificações?'),
        content: Text(
          ids.length == 1
              ? 'Este aviso será removido da lista de todos os membros do grupo. '
                    'O total histórico será preservado.'
              : 'Os avisos exibidos serão removidos da lista de todos os membros '
                    'do grupo. Novos avisos e o total histórico serão preservados.',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancelar'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Limpar'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (confirmou != true) {
      setState(() => _confirmando = false);
      return;
    }
    setState(() {
      _confirmando = false;
      _limpando = true;
    });
    try {
      await _repositorio.limpar(widget.dispositivoId, ids);
      if (!mounted) return;
      setState(() {
        _notificacoes.removeWhere((item) => ids.contains(item.id));
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _limpando = false;
        _confirmando = true;
      });
      await showCupertinoDialog<void>(
        context: context,
        builder: (context) => CupertinoAlertDialog(
          title: const Text('Não foi possível limpar'),
          content: const Text('Os avisos foram mantidos. Tente novamente.'),
          actions: [
            CupertinoDialogAction(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _limpando = false;
          _confirmando = false;
        });
      }
    }
    await _buscar();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.systemGroupedBackground,
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Emergências'),
        trailing: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: _ocupado || _notificacoes.isEmpty || _erro != null
              ? null
              : () => _confirmarLimpeza(List.of(_notificacoes)),
          child: const Text('Limpar lista'),
        ),
      ),
      child: SafeArea(
        child: _carregando
            ? const Center(child: CupertinoActivityIndicator())
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    widget.nomeDispositivo,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'O responsável é a conta que enviou o sinal da '
                    'bengala ao sistema. O horário indica quando o sinal foi recebido pelo celular.',
                  ),
                  const SizedBox(height: 16),
                  if (_limpando) const CupertinoActivityIndicator(),
                  if (_erro != null) ...[
                    Text(_erro!),
                    CupertinoButton(
                      onPressed: _buscar,
                      child: const Text('Tentar novamente'),
                    ),
                  ] else if (_notificacoes.isEmpty) ...[
                    const SizedBox(height: 50),
                    const Icon(
                      CupertinoIcons.check_mark_circled,
                      size: 64,
                      color: CupertinoColors.activeGreen,
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Nenhuma emergência pendente.',
                      textAlign: TextAlign.center,
                    ),
                  ] else ...[
                    if (_notificacoes.length == 100)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 16),
                        child: Text(
                          'Exibindo os 100 avisos mais recentes. Ao limpar '
                          'esta lista, os anteriores serão carregados.',
                        ),
                      ),
                    for (final item in _notificacoes) _aviso(item),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _aviso(NotificacaoEmergencia item) {
    return Container(
      key: ValueKey(item.id),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.secondarySystemGroupedBackground.resolveFrom(
          context,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.legado
                ? '${item.quantidade} alerta(s) anterior(es)'
                : 'Alerta de emergência',
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: CupertinoColors.destructiveRed,
            ),
          ),
          const SizedBox(height: 8),
          Text(item.horarioLocal),
          const SizedBox(height: 6),
          Text('Responsável: ${item.responsavel}'),
          if (item.legado)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Estes alertas foram contados antes do histórico detalhado. '
                'O horário e o responsável não foram registrados.',
              ),
            ),
          CupertinoButton(
            padding: const EdgeInsets.only(top: 12),
            onPressed: _ocupado || _erro != null
                ? null
                : () => _confirmarLimpeza([item]),
            child: const Text(
              'Limpar aviso',
              style: TextStyle(color: CupertinoColors.destructiveRed),
            ),
          ),
        ],
      ),
    );
  }
}
