import 'dart:async';
import 'dart:io';

import 'package:app_tcc/sincronizacao_bengala.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';

void main() {
  late Directory pasta;
  late Database banco;
  late String caminho;
  String? usuario;
  late FilaBengala fila;
  late List<LeituraPendente> enviados;
  late bool redeDisponivel;

  Future<void> enviar(LeituraPendente leitura) async {
    if (!redeDisponivel) throw const SocketException('Sem internet');
    enviados.add(leitura);
  }

  void criarFila() {
    fila = FilaBengala(
      banco: banco,
      usuarioAtual: () => usuario,
      enviar: enviar,
      envioAutomatico: false,
    );
  }

  Future<void> leitura({
    int? sinal,
    int bateria = 80,
    String dono = 'usuario-a',
    DateTime? horario,
  }) => fila.salvar(
    usuarioId: dono,
    dispositivoId: 'bengala-a',
    dados: {'bateria': bateria},
    sinalEmergencia: sinal,
    coletadaEm: horario,
  );

  Future<void> reabrir() async {
    await banco.close();
    banco = await databaseFactoryIo.openDatabase(caminho);
    criarFila();
  }

  setUp(() async {
    pasta = await Directory.systemTemp.createTemp('tcc_offline_teste_');
    caminho = '${pasta.path}${Platform.pathSeparator}fila.db';
    banco = await databaseFactoryIo.openDatabase(caminho);
    usuario = 'usuario-a';
    enviados = [];
    redeDisponivel = false;
    criarFila();
  });

  tearDown(() async {
    await banco.close();
    await pasta.delete(recursive: true);
  });

  test(
    'Offline mantém todas as leituras em disco e envia na ordem ao voltar',
    () async {
      await leitura(bateria: 80);
      await leitura(bateria: 79);
      await fila.sincronizar();
      expect(fila.pendentes.value, 2);
      expect(enviados, isEmpty);
      await reabrir();
      await fila.atualizarContagem();
      expect(fila.pendentes.value, 2);
      redeDisponivel = true;
      await fila.sincronizar(forcar: true);
      expect(enviados.map((e) => (e.valores['dados'] as Map)['bateria']), [
        80,
        79,
      ]);
      expect(fila.pendentes.value, 0);
    },
  );

  test(
    'Resposta perdida mantém o mesmo ID para uma retentativa segura',
    () async {
      final recebidas = <String>{};
      var perderResposta = true;
      fila = FilaBengala(
        banco: banco,
        usuarioAtual: () => usuario,
        envioAutomatico: false,
        enviar: (item) async {
          recebidas.add(item.id);
          if (perderResposta) {
            throw TimeoutException('Servidor gravou, resposta perdida');
          }
        },
      );
      await leitura(sinal: 1);
      await fila.sincronizar();
      expect(fila.pendentes.value, 1);
      perderResposta = false;
      await fila.sincronizar(forcar: true);
      expect(recebidas.length, 1);
      expect(fila.pendentes.value, 0);
    },
  );

  test('Emergência e estado do sinal persistem após reiniciar o app', () async {
    final horario = DateTime.utc(2026, 11, 1, 12, 34, 56);
    await leitura(sinal: 1, horario: horario);
    await reabrir();
    await leitura(sinal: 1);
    await leitura();
    await leitura(sinal: 0);
    await leitura(sinal: 1);
    redeDisponivel = true;
    await fila.sincronizar(forcar: true);
    expect(enviados.length, 5);
    expect(
      enviados.where((e) => e.valores['emergencia_chave'] != null).length,
      2,
    );
    expect(enviados.first.valores['coletada_em'], horario.toIso8601String());
  });

  test('Trocar de conta não envia dados pendentes de outra pessoa', () async {
    await leitura();
    await leitura(dono: 'usuario-b');
    usuario = 'usuario-b';
    redeDisponivel = true;
    await fila.sincronizar();
    expect(enviados.map((e) => e.usuarioId), ['usuario-b']);
    usuario = 'usuario-a';
    await fila.atualizarContagem();
    expect(fila.pendentes.value, 1);
    await fila.sincronizar();
    expect(enviados.last.usuarioId, 'usuario-a');
  });

  test('Sem sessão os dados continuam em disco', () async {
    await leitura();
    usuario = null;
    redeDisponivel = true;
    await fila.sincronizar();
    expect(enviados, isEmpty);
    usuario = 'usuario-a';
    await fila.atualizarContagem();
    expect(fila.pendentes.value, 1);
  });

  test('Uma falha após o primeiro envio remove apenas o confirmado', () async {
    var chamadas = 0;
    fila = FilaBengala(
      banco: banco,
      usuarioAtual: () => usuario,
      envioAutomatico: false,
      enviar: (item) async {
        chamadas++;
        if (chamadas > 1) throw Exception('Banco fora do ar');
      },
    );
    await leitura();
    await leitura();
    await leitura();
    await fila.sincronizar();
    expect(fila.pendentes.value, 2);
    await reabrir();
    await fila.atualizarContagem();
    expect(fila.pendentes.value, 2);
  });

  test('Chamadas simultâneas de sincronização não repetem envio', () async {
    final bloqueio = Completer<void>();
    fila = FilaBengala(
      banco: banco,
      usuarioAtual: () => usuario,
      envioAutomatico: false,
      enviar: (item) async {
        enviados.add(item);
        await bloqueio.future;
      },
    );
    await leitura();
    final primeiro = fila.sincronizar();
    final segundo = fila.sincronizar();
    bloqueio.complete();
    await Future.wait([primeiro, segundo]);
    expect(enviados.length, 1);
  });

  test(
    'Cadastro local da bengala fica separado por conta e sobrevive reinício',
    () async {
      await fila.guardarVinculo('usuario-a', 'mac', 'uuid-da-bengala');
      await reabrir();
      expect(await fila.buscarVinculo('usuario-a', 'mac'), 'uuid-da-bengala');
      expect(await fila.buscarVinculo('usuario-b', 'mac'), isNull);
    },
  );

  test(
    'Falha local não muda o sinal nem aceita uma leitura parcialmente salva',
    () async {
      await banco.close();
      await expectLater(leitura(sinal: 1), throwsA(anything));
      banco = await databaseFactoryIo.openDatabase(caminho);
      criarFila();
      await leitura(sinal: 1);
      redeDisponivel = true;
      await fila.sincronizar();
      expect(enviados.length, 1);
      expect(enviados.single.valores['emergencia_chave'], isNotNull);
    },
  );

  test(
    'Retentativas respeitam intervalo e podem ser antecipadas ao reabrir',
    () async {
      var tentativas = 0;
      fila = FilaBengala(
        banco: banco,
        usuarioAtual: () => usuario,
        envioAutomatico: false,
        enviar: (_) async {
          tentativas++;
          throw Exception('Indisponível');
        },
      );
      await leitura();
      await fila.sincronizar();
      await fila.sincronizar();
      expect(tentativas, 1);
      await fila.sincronizar(forcar: true);
      expect(tentativas, 2);
    },
  );

  test(
    'Leitura normaliza os formatos do ESP32 e recusa coordenadas inválidas',
    () {
      final dados = lerDadosBengala(
        r'{\bat:120,\emerg:1,\lat:-29,\lng:-51,\ax:NaN}',
      );
      final normalizado = normalizarDadosBengala(dados);
      expect(normalizado['bateria'], 100);
      expect(normalizado['latitude_atual'], -29);
      expect(normalizado.containsKey('ax'), isFalse);
      expect(
        normalizarDadosBengala({'lat': 200, 'lng': -51})
            .containsKey('latitude_atual'),
        isFalse,
      );
      expect(lerDadosBengala('{"bat":90,"emerg":0}')['bat'], 90);
    },
  );
}
