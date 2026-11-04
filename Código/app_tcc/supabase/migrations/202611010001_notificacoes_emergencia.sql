-- Execute uma vez no SQL Editor do projeto Supabase antes de usar esta versão.
begin;

alter table public.dispositivos
  add column if not exists emergencias_pendentes integer not null default 0;

create table if not exists public.notificacoes_emergencia (
  id bigint generated always as identity primary key,
  dispositivo_id uuid not null references public.dispositivos(id) on delete cascade,
  usuario_id uuid references auth.users(id) on delete set null,
  usuario_nome text,
  evento_chave text not null,
  emitida_em timestamptz default now(),
  quantidade integer not null default 1 check (quantidade > 0),
  legado boolean not null default false,
  limpa_em timestamptz,
  limpa_por uuid references auth.users(id) on delete set null,
  unique (usuario_id, evento_chave)
);

create index if not exists notificacoes_emergencia_pendentes_idx
  on public.notificacoes_emergencia (dispositivo_id, id desc)
  where limpa_em is null;

-- Preserva contagens anteriores sem inventar autoria ou horário.
-- Registros já limpos também entram na soma, impedindo recriação ao reaplicar.
insert into public.notificacoes_emergencia
  (dispositivo_id, evento_chave, emitida_em, quantidade, legado)
select d.id, 'legado-' || d.id::text, null,
       greatest(coalesce(d.emergencias, 0) - coalesce(n.total, 0), 0)::integer, true
from public.dispositivos d
left join (
  select dispositivo_id, sum(quantidade) as total
  from public.notificacoes_emergencia group by dispositivo_id
) n on n.dispositivo_id = d.id
where coalesce(d.emergencias, 0) > coalesce(n.total, 0);

update public.dispositivos d set emergencias_pendentes = (
  select coalesce(sum(n.quantidade), 0)::integer
  from public.notificacoes_emergencia n
  where n.dispositivo_id = d.id and n.limpa_em is null
);

alter table public.notificacoes_emergencia enable row level security;
drop policy if exists membros_leem_emergencias on public.notificacoes_emergencia;
create policy membros_leem_emergencias on public.notificacoes_emergencia
  for select to authenticated using (
    exists (
      select 1 from public.dispositivos d
      join public.membros_grupo m on m.grupo_id = d.grupo_id
      where d.id = notificacoes_emergencia.dispositivo_id
        and m.user_id = (select auth.uid())
    )
  );

-- As escritas passam pelas funções: autoria vem da sessão, nunca do cliente.
revoke all on public.notificacoes_emergencia from anon, authenticated;
grant select on public.notificacoes_emergencia to authenticated;

create or replace function public.registrar_emergencia(
  p_dispositivo_id uuid,
  p_evento_chave text
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := auth.uid();
  v_dispositivo uuid;
  v_nome text;
  v_inserida bigint;
begin
  if v_usuario is null then
    raise exception 'Sessão necessária' using errcode = '42501';
  end if;
  if p_evento_chave is null or length(btrim(p_evento_chave)) = 0
     or length(p_evento_chave) > 200 then
    raise exception 'Chave de ocorrência inválida';
  end if;

  -- Mesmo bloqueio na criação e limpeza: contadores ficam consistentes.
  select d.id into v_dispositivo from public.dispositivos d
  where d.id = p_dispositivo_id and exists (
    select 1 from public.membros_grupo m
    where m.grupo_id = d.grupo_id and m.user_id = v_usuario
  ) for update of d;
  if not found then
    raise exception 'Dispositivo fora do seu grupo' using errcode = '42501';
  end if;

  select coalesce(nullif(btrim(u.raw_user_meta_data->>'nome'), ''),
                  nullif(u.email, ''), 'Usuário ' || v_usuario::text)
    into v_nome from auth.users u where u.id = v_usuario;

  insert into public.notificacoes_emergencia
    (dispositivo_id, usuario_id, usuario_nome, evento_chave)
  values (p_dispositivo_id, v_usuario, v_nome, p_evento_chave)
  on conflict (usuario_id, evento_chave) do nothing returning id into v_inserida;

  if v_inserida is not null then
    update public.dispositivos
    set emergencias = coalesce(emergencias, 0) + 1,
        emergencias_pendentes = emergencias_pendentes + 1
    where id = p_dispositivo_id;
  end if;
end;
$$;

create or replace function public.limpar_emergencias(
  p_dispositivo_id uuid,
  p_ids bigint[]
) returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_usuario uuid := auth.uid();
  v_dispositivo uuid;
begin
  if v_usuario is null then
    raise exception 'Sessão necessária' using errcode = '42501';
  end if;
  select d.id into v_dispositivo from public.dispositivos d
  where d.id = p_dispositivo_id and exists (
    select 1 from public.membros_grupo m
    where m.grupo_id = d.grupo_id and m.user_id = v_usuario
  ) for update of d;
  if not found then
    raise exception 'Dispositivo fora do seu grupo' using errcode = '42501';
  end if;

  update public.notificacoes_emergencia
    set limpa_em = now(), limpa_por = v_usuario
    where dispositivo_id = p_dispositivo_id and id = any(p_ids)
      and limpa_em is null;

  update public.dispositivos set emergencias_pendentes = (
    select coalesce(sum(n.quantidade), 0)::integer
    from public.notificacoes_emergencia n
    where n.dispositivo_id = p_dispositivo_id and n.limpa_em is null
  ) where id = p_dispositivo_id;
end;
$$;

revoke all on function public.registrar_emergencia(uuid, text) from public, anon;
revoke all on function public.limpar_emergencias(uuid, bigint[]) from public, anon;
grant execute on function public.registrar_emergencia(uuid, text) to authenticated;
grant execute on function public.limpar_emergencias(uuid, bigint[]) to authenticated;

notify pgrst, 'reload schema';
commit;
