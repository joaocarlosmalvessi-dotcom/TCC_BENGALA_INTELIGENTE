begin;

create table if not exists public.leituras_bengala (
  id uuid primary key,
  dispositivo_id uuid not null references public.dispositivos(id) on delete cascade,
  usuario_id uuid references auth.users(id) on delete set null,
  coletada_em timestamptz not null,
  recebida_em timestamptz not null default now(),
  dados jsonb not null,
  emergencia_chave text
);
create index if not exists leituras_bengala_dispositivo_data_idx
  on public.leituras_bengala(dispositivo_id, coletada_em desc);

alter table public.leituras_bengala enable row level security;
drop policy if exists membros_leem_leituras on public.leituras_bengala;
create policy membros_leem_leituras on public.leituras_bengala
  for select to authenticated using (exists (
    select 1 from public.dispositivos d
    join public.membros_grupo m on m.grupo_id = d.grupo_id
    where d.id = leituras_bengala.dispositivo_id and m.user_id = (select auth.uid())
  ));
revoke all on public.leituras_bengala from anon, authenticated;
grant select on public.leituras_bengala to authenticated;

create or replace function public.sincronizar_leitura_bengala(
  p_evento_id uuid,
  p_usuario_id uuid,
  p_dispositivo_id uuid,
  p_coletada_em timestamptz,
  p_dados jsonb,
  p_emergencia_chave text default null
) returns void language plpgsql security definer set search_path = '' as $$
declare
  v_dispositivo public.dispositivos%rowtype;
  v_inserida uuid;
  v_lat double precision;
  v_lng double precision;
begin
  if auth.uid() is null or p_usuario_id is distinct from auth.uid() then
    raise exception 'A leitura pertence a outra sessão' using errcode = '42501';
  end if;
  if p_evento_id is null or p_coletada_em is null
     or p_dados is null or jsonb_typeof(p_dados) <> 'object' then
    raise exception 'Leitura inválida';
  end if;

  select d.* into v_dispositivo from public.dispositivos d
  where d.id = p_dispositivo_id and exists (
    select 1 from public.membros_grupo m
    where m.grupo_id = d.grupo_id and m.user_id = auth.uid()
  ) for update of d;
  if not found then
    raise exception 'Dispositivo fora do seu grupo' using errcode = '42501';
  end if;

  insert into public.leituras_bengala
    (id, dispositivo_id, usuario_id, coletada_em, dados, emergencia_chave)
  values (p_evento_id, p_dispositivo_id, p_usuario_id, p_coletada_em, p_dados, p_emergencia_chave)
  on conflict(id) do nothing returning id into v_inserida;
  if v_inserida is null then
    if exists (select 1 from public.leituras_bengala l where l.id = p_evento_id
      and (l.usuario_id is distinct from p_usuario_id or l.dispositivo_id <> p_dispositivo_id)) then
      raise exception 'Identificador de leitura já utilizado' using errcode = '42501';
    end if;
    return;
  end if;

  v_lat := (p_dados->>'latitude_atual')::double precision;
  v_lng := (p_dados->>'longitude_atual')::double precision;
  if v_lat between -90 and 90 and v_lng between -180 and 180
     and v_lat <> 0 and v_lng <> 0 then
    insert into public.historico_posicoes(dispositivo_id, latitude, longitude, registado_em)
    values (p_dispositivo_id, v_lat, v_lng, p_coletada_em);
  else
    v_lat := null;
    v_lng := null;
  end if;

  if p_emergencia_chave is not null then
    perform public.registrar_emergencia(p_dispositivo_id, p_emergencia_chave);
    -- Mantém a hora da coleta offline, e não a hora de retorno da rede.
    update public.notificacoes_emergencia set emitida_em = p_coletada_em
    where dispositivo_id = p_dispositivo_id and usuario_id = p_usuario_id
      and evento_chave = p_emergencia_chave;
  end if;

  -- Um pacote antigo entra no histórico, mas não sobrescreve a posição atual.
  if v_dispositivo.ultima_sincronizacao is null
     or p_coletada_em >= v_dispositivo.ultima_sincronizacao then
    update public.dispositivos set
      bateria = case when p_dados ? 'bateria' then greatest(0, least(100, (p_dados->>'bateria')::integer)) else bateria end,
      latitude_atual = coalesce(v_lat, latitude_atual),
      longitude_atual = coalesce(v_lng, longitude_atual),
      dist1 = case when p_dados ? 'dist1' then (p_dados->>'dist1')::integer else dist1 end,
      dist2 = case when p_dados ? 'dist2' then (p_dados->>'dist2')::integer else dist2 end,
      dist3 = case when p_dados ? 'dist3' then (p_dados->>'dist3')::integer else dist3 end,
      ax = case when p_dados ? 'ax' then (p_dados->>'ax')::numeric else ax end,
      ay = case when p_dados ? 'ay' then (p_dados->>'ay')::numeric else ay end,
      az = case when p_dados ? 'az' then (p_dados->>'az')::numeric else az end,
      is_online = coalesce((p_dados->>'is_online')::boolean, true)
        and p_coletada_em >= now() - interval '30 seconds',
      ultima_sincronizacao = p_coletada_em
    where id = p_dispositivo_id;
  end if;
end;
$$;

revoke all on function public.sincronizar_leitura_bengala(uuid, uuid, uuid, timestamptz, jsonb, text) from public, anon;
grant execute on function public.sincronizar_leitura_bengala(uuid, uuid, uuid, timestamptz, jsonb, text) to authenticated;
notify pgrst, 'reload schema';
commit;
