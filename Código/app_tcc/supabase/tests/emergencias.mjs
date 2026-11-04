// Banco PostgreSQL isolado via PGlite; não acessa o projeto Supabase real.
// Uso: node supabase/tests/emergencias.mjs <pasta-do-pacote-pglite>
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';

const modulePath = resolve(process.argv[2], 'dist/index.js');
const { PGlite } = await import(pathToFileURL(modulePath).href);
const db = new PGlite();
const migration = await readFile(new URL('../migrations/202611010001_notificacoes_emergencia.sql', import.meta.url), 'utf8');
const joao = '11111111-1111-4111-8111-111111111111';
const maria = '22222222-2222-4222-8222-222222222222';
const bengala = '77777777-7777-4777-8777-777777777777';
const outraBengala = '88888888-8888-4888-8888-888888888888';
const outro = '33333333-3333-4333-8333-333333333333';
try {
  await db.exec(`
    create role anon;
    create role authenticated;
    create schema auth;
    create table auth.users (id uuid primary key, email text, raw_user_meta_data jsonb);
    create function auth.uid() returns uuid language sql stable as
      $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
    create table public.dispositivos (id uuid primary key, grupo_id uuid, emergencias integer);
    create table public.membros_grupo (grupo_id uuid, user_id uuid);
    insert into auth.users values
      ('${joao}', 'joao@exemplo.com', '{"nome":"João"}'),
      ('${maria}', 'maria@exemplo.com', '{}'),
      ('${outro}', 'outro@exemplo.com', '{}');
    insert into public.dispositivos values ('${bengala}', '${joao}', 2), ('${outraBengala}', '${outro}', 0);
    insert into public.membros_grupo values
      ('${joao}', '${joao}'), ('${joao}', '${maria}'), ('${outro}', '${outro}');
    grant usage on schema public, auth to authenticated, anon;
    grant select on public.dispositivos, public.membros_grupo to authenticated;
    grant execute on function auth.uid() to authenticated;
  `);
  await db.exec(migration);
  await db.exec(migration);
  assert.equal((await db.query('select count(*)::int as n from public.notificacoes_emergencia')).rows[0].n, 1);
  console.log('PASS: migração reaplicável e legado sem duplicação');

  const usuario = async (id) => {
    await db.exec('reset role; set role authenticated;');
    await db.query("select set_config('request.jwt.claim.sub', $1, false)", [id]);
  };
  const registrar = (chave) => db.query(`select public.registrar_emergencia('${bengala}', $1)`, [chave]);
  const contadores = async () => (await db.query(`select emergencias, emergencias_pendentes from public.dispositivos where id='${bengala}'`)).rows[0];

  await usuario(joao);
  await registrar('ocorrencia-a');
  await registrar('ocorrencia-a');
  assert.deepEqual(await contadores(), { emergencias: 3, emergencias_pendentes: 3 });
  const aviso = (await db.query("select * from public.notificacoes_emergencia where evento_chave='ocorrencia-a'")).rows[0];
  assert.equal(aviso.usuario_id, joao);
  assert.equal(aviso.usuario_nome, 'João');
  assert.ok(aviso.emitida_em);
  console.log('PASS: criação atômica, autoria, horário e retentativa idempotente');

  await registrar('ocorrencia-b');
  await usuario(maria);
  assert.equal((await db.query('select count(*)::int as n from public.notificacoes_emergencia')).rows[0].n, 3);
  await db.query(`select public.limpar_emergencias('${bengala}', $1::bigint[])`, [[aviso.id]]);
  assert.deepEqual(await contadores(), { emergencias: 4, emergencias_pendentes: 3 });
  await db.query(`select public.limpar_emergencias('${bengala}', $1::bigint[])`, [[aviso.id]]);
  assert.deepEqual(await contadores(), { emergencias: 4, emergencias_pendentes: 3 });
  assert.equal((await db.query('select limpa_por from public.notificacoes_emergencia where id=$1', [aviso.id])).rows[0].limpa_por, maria);
  console.log('PASS: membro limpa, total preservado e nova ocorrência permanece');

  await usuario(outro);
  assert.equal((await db.query('select count(*)::int as n from public.notificacoes_emergencia')).rows[0].n, 0);
  await assert.rejects(registrar('intruso'), /fora do seu grupo/);
  await assert.rejects(db.query(`select public.limpar_emergencias('${bengala}', $1::bigint[])`, [[aviso.id]]), /fora do seu grupo/);
  await assert.rejects(db.query(`insert into public.notificacoes_emergencia(dispositivo_id, evento_chave) values('${outraBengala}', 'falso')`), /permission denied/);
  console.log('PASS: isolamento de grupo e bloqueio de escrita direta');

  await db.exec('reset role; set role anon;');
  await assert.rejects(registrar('anonimo'), /permission denied/);
  console.log('PASS: sessão obrigatória');

  await usuario(joao);
  const ids = (await db.query('select id from public.notificacoes_emergencia where limpa_em is null')).rows.map(r => r.id);
  await db.query(`select public.limpar_emergencias('${bengala}', $1::bigint[])`, [ids]);
  assert.deepEqual(await contadores(), { emergencias: 4, emergencias_pendentes: 0 });
  await db.exec('reset role;');
  await db.exec(migration);
  assert.deepEqual(await contadores(), { emergencias: 4, emergencias_pendentes: 0 });
  console.log('PASS: limpeza do legado e migração não recriam avisos limpos');
} finally {
  await db.close();
}
