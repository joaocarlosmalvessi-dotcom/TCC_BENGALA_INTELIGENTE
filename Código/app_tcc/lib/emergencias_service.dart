import 'package:supabase_flutter/supabase_flutter.dart';

class NotificacaoEmergencia {
  const NotificacaoEmergencia({
    required this.id,
    required this.quantidade,
    this.emitidaEm,
    this.usuarioNome,
    this.usuarioId,
    this.legado = false,
  });

  factory NotificacaoEmergencia.fromMap(Map<String, dynamic> map) {
    return NotificacaoEmergencia(
      id: (map['id'] as num).toInt(),
      quantidade: (map['quantidade'] as num?)?.toInt() ?? 1,
      emitidaEm: DateTime.tryParse(map['emitida_em']?.toString() ?? ''),
      usuarioNome: map['usuario_nome'] as String?,
      usuarioId: map['usuario_id'] as String?,
      legado: map['legado'] == true,
    );
  }

  final int id;
  final int quantidade;
  final DateTime? emitidaEm;
  final String? usuarioNome;
  final String? usuarioId;
  final bool legado;

  String get responsavel {
    final nome = usuarioNome?.trim();
    if (nome != null && nome.isNotEmpty) return nome;
    if (usuarioId != null) return 'Usuário $usuarioId';
    return 'Usuário não registrado';
  }

  String get horarioLocal {
    final data = emitidaEm?.toLocal();
    if (data == null) return 'Horário não registrado';
    String dois(int n) => n.toString().padLeft(2, '0');
    return '${dois(data.day)}/${dois(data.month)}/${data.year} às '
        '${dois(data.hour)}:${dois(data.minute)}:${dois(data.second)}';
  }
}

abstract class RepositorioEmergencias {
  Future<List<NotificacaoEmergencia>> listar(String dispositivoId);
  Future<void> limpar(String dispositivoId, List<int> ids);
}

class EmergenciasService implements RepositorioEmergencias {
  EmergenciasService([SupabaseClient? client])
    : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  @override
  Future<List<NotificacaoEmergencia>> listar(String dispositivoId) async {
    final rows = await _client
        .from('notificacoes_emergencia')
        .select('id, quantidade, emitida_em, usuario_nome, usuario_id, legado')
        .eq('dispositivo_id', dispositivoId)
        .isFilter('limpa_em', null)
        .order('id', ascending: false)
        .limit(100);
    return rows.map(NotificacaoEmergencia.fromMap).toList();
  }

  @override
  Future<void> limpar(String dispositivoId, List<int> ids) async {
    if (ids.isEmpty) return;
    await _client.rpc(
      'limpar_emergencias',
      params: {'p_dispositivo_id': dispositivoId, 'p_ids': ids},
    );
  }
}

/// Mantém a mesma chave em retentativas; o banco a usa para evitar duplicatas.
class RegistroSinalEmergencia {
  final _eventosAtivos = <String, String>{};
  final _pendentes = <String, List<String>>{};
  final _filas = <String, Future<void>>{};
  int _sequencia = 0;

  Future<void> processar({
    required String dispositivoId,
    required int? sinal,
    required Future<void> Function(String chave) registrar,
  }) {
    final anterior = _filas[dispositivoId] ?? Future<void>.value();
    final atual = anterior.then((_) async {
      if (sinal == 0) _eventosAtivos.remove(dispositivoId);
      if (sinal == 1 && !_eventosAtivos.containsKey(dispositivoId)) {
        final chave =
            '$dispositivoId-'
            '${DateTime.now().toUtc().microsecondsSinceEpoch}-${_sequencia++}';
        _eventosAtivos[dispositivoId] = chave;
        (_pendentes[dispositivoId] ??= []).add(chave);
      }
      final pendentes = _pendentes[dispositivoId];
      while (pendentes != null && pendentes.isNotEmpty) {
        await registrar(pendentes.first);
        pendentes.removeAt(0);
      }
    });
    // Uma falha é devolvida ao chamador, mas não bloqueia as retentativas.
    _filas[dispositivoId] = atual.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return atual;
  }
}

Future<void> registrarEmergencia(
  String dispositivoId,
  String chave, {
  SupabaseClient? client,
}) async {
  await (client ?? Supabase.instance.client).rpc(
    'registrar_emergencia',
    params: {'p_dispositivo_id': dispositivoId, 'p_evento_chave': chave},
  );
}
