// node supabase/tests/offline.mjs <pasta-do-pacote-pglite>
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

const { PGlite } = await import(pathToFileURL(resolve(process.argv[2], 'dist/index.js')).href);
const db = new PGlite();
const usuario = '11111111-1111-4111-8111-111111111111';
const outro = '22222222-2222-4222-8222-222222222222';
const bengala = '77777777-7777-4777-8777-777777777777';
const evento = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const maisNovo = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const falha = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const coleta = '2026-11-01T12:34:56Z';
try {
  await db.exec(`
    create role anon;
    create role authenticated;
    create schema auth;
    create table auth.users(id uuid primary key, email text, raw_user_meta_data jsonb);
    create function auth.uid() returns uuid language sql stable as
      $$ select nullif(current_setting('request.jwt.claim.sub',true), '')::uuid $$;
    create table public.dispositivos (
      id uuid primary key, grupo_id uuid, emergencias integer default 0,
      bateria integer, latitude_atual double precision, longitude_atual double precision,
      dist1 integer, dist2 integer, dist3 integer, ax numeric, ay numeric, az numeric,
      is_online boolean, ultima_sincronizacao timestamptz
    );
    create table public.membros_grupo(grupo_id uuid, user_id uuid);
    create table public.historico_posicoes (
      id uuid primary key default gen_random_uuid(),
      dispositivo_id uuid references public.dispositivos(id),
      latitude double precision, longitude double precision, registado_em timestamptz
    );
    insert into auth.users values ('${usuario}', 'joao@exemplo.com', '{"nome":"João"}'),
      ('${outro}', 'outro@exemplo.com', '{}');
    insert into public.dispositivos(id, grupo_id) values ('${bengala}', '${usuario}');
    insert into public.membros_grupo values ('${usuario}', '${usuario}');
    grant usage on schema auth, public to authenticated, anon;
    grant select on public.dispositivos, public.membros_grupo, public.historico_posicoes to authenticated;
  `);
  for (const file of ['202611010001_notificacoes_emergencia.sql', '202611010002_sincronizacao_offline.sql']) {
    await db.exec(await readFile(new URL('../migrations/' + file, import.meta.url), 'utf8'));
  }
  await db.exec(await readFile(new URL('../migrations/202611010002_sincronizacao_offline.sql', import.meta.url), 'utf8'));
  await db.exec('set role authenticated');
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [usuario]);
  const dados = { bateria: 80, latitude_atual: -29, longitude_atual: -51, dist1: 10, ax: 1.2, is_online: true };
  const enviar = (id, horario = coleta, pacote = dados, dono = usuario, chave = null) =>
    db.query('select public.sincronizar_leitura_bengala($1,$2,$3,$4,$5,$6)', [id, dono, bengala, horario, pacote, chave]);
  const conta = async (table) => Number((await db.query('select count(*) as n from public.' + table)).rows[0].n);
  const atual = async () => (await db.query('select bateria, dist1, ax, emergencias, emergencias_pendentes, ultima_sincronizacao, is_online from public.dispositivos')).rows[0];

  await enviar(evento, coleta, dados, usuario, evento);
  await enviar(evento, coleta, dados, usuario, evento);
  assert.equal(await conta('leituras_bengala'), 1);
  assert.equal(await conta('historico_posicoes'), 1);
  assert.equal(await conta('notificacoes_emergencia'), 1);
  assert.equal((await atual()).emergencias, 1);
  assert.equal((await db.query('select emitida_em from public.notificacoes_emergencia')).rows[0].emitida_em.toISOString(), '2026-11-01T12:34:56.000Z');
  console.log('PASS: repetição após resposta perdida não duplica sensor, posição ou emergência');
  assert.equal((await atual()).is_online, false);
  console.log('PASS: coleta offline preserva horário e não simula uma conexão atual');

  await enviar(maisNovo, '2026-11-01T14:00:00Z', { ...dados, bateria: 90 });
  await enviar('dddddddd-dddd-4ddd-8ddd-dddddddddddd', '2026-11-01T10:00:00Z', { ...dados, bateria: 20 });
  assert.equal((await atual()).bateria, 90);
  assert.equal(await conta('historico_posicoes'), 3);
  console.log('PASS: leitura antiga entra no histórico sem sobrescrever o estado mais recente');

  await assert.rejects(enviar(falha, '2026-11-01T15:00:00Z', { ...dados, bateria: 'inválida' }, usuario, falha));
  assert.equal(await conta('leituras_bengala'), 3);
  assert.equal(await conta('historico_posicoes'), 3);
  assert.equal((await atual()).emergencias, 1);
  await enviar(falha, '2026-11-01T15:00:00Z', dados, usuario, falha);
  assert.equal(await conta('leituras_bengala'), 4);
  assert.equal((await atual()).emergencias, 2);
  console.log('PASS: falha parcial reverte toda a transação e permite retentar o mesmo evento');

  await assert.rejects(enviar('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', coleta, dados, outro), /outra sessão/);
  await db.query("select set_config('request.jwt.claim.sub',$1,false)", [outro]);
  await assert.rejects(enviar('eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee', coleta, dados, outro), /fora do seu grupo/);
  assert.equal(await conta('leituras_bengala'), 0);
  await assert.rejects(db.query(`insert into public.leituras_bengala(id, dispositivo_id, coletada_em, dados) values('${evento}', '${bengala}',now(),'{}')`), /permission denied/);
  await db.exec('reset role; set role anon');
  await assert.rejects(enviar(evento), /permission denied/);
  console.log('PASS: leituras ficam restritas ao usuário original e aos membros do grupo');
} finally {
  await db.close();
}
