import 'dart:async';

import 'package:app_tcc/emergencias_service.dart';
import 'package:app_tcc/tela_emergencias.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_test/flutter_test.dart';

const _dispositivo = '77777777-7777-4777-8777-777777777777';
const _outroDispositivo = '88888888-8888-4888-8888-888888888888';

const _aviso = NotificacaoEmergencia(
  id: 1,
  quantidade: 1,
  usuarioNome: 'João',
  usuarioId: 'usuario-1',
);

class _RepositorioTeste implements RepositorioEmergencias {
  List<NotificacaoEmergencia> itens = [_aviso];
  List<int> idsLimpos = [];
  bool falharLeitura = false;
  bool falharLimpeza = false;
  String? dispositivoLimpo;

  @override
  Future<List<NotificacaoEmergencia>> listar(String dispositivoId) async {
    if (falharLeitura) throw Exception('Sem conexão');
    return List.of(itens);
  }

  @override
  Future<void> limpar(String dispositivoId, List<int> ids) async {
    if (falharLimpeza) throw Exception('Sem conexão');
    dispositivoLimpo = dispositivoId;
    idsLimpos = List.of(ids);
    itens.removeWhere((item) => ids.contains(item.id));
  }
}

Future<void> _abrir(WidgetTester tester, _RepositorioTeste repo) async {
  await tester.pumpWidget(
    CupertinoApp(
      home: TelaEmergencias(
        dispositivoId: _dispositivo,
        nomeDispositivo: 'Bengala João',
        repositorio: repo,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  test('Converte data com fuso para a hora local e preserva nome', () {
    final aviso = NotificacaoEmergencia.fromMap({
      'id': 2,
      'emitida_em': '2026-11-01T15:04:05Z',
      'usuario_nome': ' João ',
    });
    final local = DateTime.utc(2026, 11, 1, 15, 4, 5).toLocal();
    expect(aviso.emitidaEm, DateTime.utc(2026, 11, 1, 15, 4, 5));
    expect(
      aviso.horarioLocal,
      contains('${local.hour.toString().padLeft(2, '0')}:04:05'),
    );
    expect(aviso.responsavel, 'João');
  });

  test('Legado não inventa horário nem autor', () {
    final aviso = NotificacaoEmergencia.fromMap({
      'id': 3,
      'legado': true,
      'quantidade': 5,
    });
    expect(aviso.quantidade, 5);
    expect(aviso.horarioLocal, 'Horário não registrado');
    expect(aviso.responsavel, 'Usuário não registrado');
  });

  test('Sinal repetido e campo ausente não duplicam a ocorrência', () async {
    final registro = RegistroSinalEmergencia();
    final chaves = <String>[];
    for (final sinal in [1, 1, null, 1, 0, 1]) {
      await registro.processar(
        dispositivoId: _dispositivo,
        sinal: sinal,
        registrar: (chave) async => chaves.add(chave),
      );
    }
    expect(chaves.length, 2);
    expect(chaves.toSet().length, 2);
  });

  test('Retentativa mantém chave mesmo após sinal voltar a zero', () async {
    final registro = RegistroSinalEmergencia();
    String? falhou;
    await expectLater(
      registro.processar(
        dispositivoId: _dispositivo,
        sinal: 1,
        registrar: (chave) async {
          falhou = chave;
          throw Exception('Resposta perdida');
        },
      ),
      throwsException,
    );
    final chaves = <String>[];
    await registro.processar(
      dispositivoId: _dispositivo,
      sinal: 0,
      registrar: (chave) async => chaves.add(chave),
    );
    expect(chaves, [falhou]);
    await registro.processar(
      dispositivoId: _dispositivo,
      sinal: 1,
      registrar: (chave) async => chaves.add(chave),
    );
    expect(chaves.length, 2);
    expect(chaves.last, isNot(falhou));
  });

  test('Pacotes concorrentes do mesmo dispositivo são serializados', () async {
    final registro = RegistroSinalEmergencia();
    final bloqueio = Completer<void>();
    final chaves = <String>[];
    Future<void> registrar(String chave) async {
      chaves.add(chave);
      await bloqueio.future;
    }

    final primeiro = registro.processar(
      dispositivoId: _dispositivo,
      sinal: 1,
      registrar: registrar,
    );
    final segundo = registro.processar(
      dispositivoId: _dispositivo,
      sinal: 1,
      registrar: registrar,
    );
    bloqueio.complete();
    await Future.wait([primeiro, segundo]);
    expect(chaves.length, 1);
  });

  test('Duas bengalas têm ocorrências independentes', () async {
    final registro = RegistroSinalEmergencia();
    final chaves = <String>[];
    for (final id in [
      _dispositivo,
      _outroDispositivo,
      _dispositivo,
      _outroDispositivo,
    ]) {
      await registro.processar(
        dispositivoId: id,
        sinal: 1,
        registrar: (chave) async => chaves.add(chave),
      );
    }
    expect(chaves.toSet().length, 2);
  });

  testWidgets('Lista mostra responsável, data e hora do registro', (
    tester,
  ) async {
    final repo = _RepositorioTeste()
      ..itens = [
        NotificacaoEmergencia(
          id: 1,
          quantidade: 1,
          usuarioNome: 'João',
          emitidaEm: DateTime(2026, 11, 1, 12, 4, 5),
        ),
      ];
    await _abrir(tester, repo);
    expect(find.text('Responsável: João'), findsOneWidget);
    expect(find.text('01/11/2026 às 12:04:05'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Cancelar limpeza mantém o aviso', (tester) async {
    final repo = _RepositorioTeste();
    await _abrir(tester, repo);
    await tester.tap(find.text('Limpar aviso'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(repo.idsLimpos, isEmpty);
    expect(find.text('Responsável: João'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Limpeza individual deixa os demais avisos', (tester) async {
    final repo = _RepositorioTeste()
      ..itens.add(
        const NotificacaoEmergencia(id: 2, quantidade: 1, usuarioNome: 'Maria'),
      );
    await _abrir(tester, repo);
    await tester.tap(find.text('Limpar aviso').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Limpar'));
    await tester.pumpAndSettle();
    expect(repo.dispositivoLimpo, _dispositivo);
    expect(repo.idsLimpos, [1]);
    expect(find.text('Responsável: João'), findsNothing);
    expect(find.text('Responsável: Maria'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Limpar lista preserva aviso recebido durante confirmação', (
    tester,
  ) async {
    final repo = _RepositorioTeste();
    await _abrir(tester, repo);
    await tester.tap(find.text('Limpar lista'));
    await tester.pumpAndSettle();
    repo.itens.add(
      const NotificacaoEmergencia(id: 2, quantidade: 1, usuarioNome: 'Maria'),
    );
    await tester.tap(find.text('Limpar'));
    await tester.pumpAndSettle();
    expect(repo.idsLimpos, [1]);
    expect(find.text('Responsável: Maria'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Falha de limpeza mantém aviso e permite tentar de novo', (
    tester,
  ) async {
    final repo = _RepositorioTeste()..falharLimpeza = true;
    await _abrir(tester, repo);
    await tester.tap(find.text('Limpar aviso'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Limpar'));
    await tester.pumpAndSettle();
    expect(find.text('Não foi possível limpar'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Responsável: João'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Erro de leitura permite recarregar e exibe lista vazia', (
    tester,
  ) async {
    final repo = _RepositorioTeste()..falharLeitura = true;
    await _abrir(tester, repo);
    expect(find.text('Tentar novamente'), findsOneWidget);
    repo.falharLeitura = false;
    repo.itens.clear();
    await tester.tap(find.text('Tentar novamente'));
    await tester.pumpAndSettle();
    expect(find.text('Nenhuma emergência pendente.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
