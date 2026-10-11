-- Günlük Rutin: canlıya alınırken bağlantı üzerinden uygulanamayan iki fonksiyon
-- Supabase → SQL Editor'e yapıştırıp Run'a bas. Tekrar çalıştırmak güvenlidir; mevcut veriyi silmez.
-- (İçindeki silme yalnızca kişi bir tepkiyi ya da bitirdiği ortak işi geri aldığında çalışır.)

-- Ortak işi bitir ya da geri al; akışa olay yazar
create or replace function public.ortak_is_bitir(p_id uuid, p_bitti boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.team_tasks;
begin
  update public.team_tasks t
  set done = p_bitti, done_by = case when p_bitti then auth.uid() end, done_at = case when p_bitti then now() end
  where t.id = p_id and public.ekip_uyesi_mi(t.team_id)
  returning * into e;
  if e.id is null then return; end if;
  delete from public.events where kind = 'ortak' and ref = p_id;
  if p_bitti then
    insert into public.events (user_id, kind, team_id, ref, task_name) values (auth.uid(), 'ortak', e.team_id, e.id, e.name);
  end if;
end $$;

-- Tepki ver, değiştir ya da kaldır (p_emoji boş = kaldır)
create or replace function public.tepki_ver(p_event uuid, p_emoji text, p_not text default null)
returns void language plpgsql security definer set search_path = '' as $$
declare e public.events;
begin
  select * into e from public.events where id = p_event;
  if e.id is null or not public.olay_gorur_mu(e) then raise exception 'olay_yok' using errcode = '42501'; end if;
  if e.user_id = auth.uid() then raise exception 'kendi_olayin'; end if;
  if p_emoji is null then
    delete from public.reactions where event_id = p_event and user_id = auth.uid();
    return;
  end if;
  insert into public.reactions (event_id, user_id, emoji, note)
  values (p_event, auth.uid(), p_emoji, nullif(left(trim(coalesce(p_not, '')), 80), ''))
  on conflict (event_id, user_id) do update set emoji = excluded.emoji, note = excluded.note;
end $$;

revoke all on function public.ortak_is_bitir(uuid, boolean), public.tepki_ver(uuid, text, text) from public;
grant execute on function public.ortak_is_bitir(uuid, boolean), public.tepki_ver(uuid, text, text) to authenticated;

-- Kontrol: iki satır da "true" dönmeli
select to_regprocedure('public.ortak_is_bitir(uuid,boolean)') is not null as ortak_is_bitir,
       to_regprocedure('public.tepki_ver(uuid,text,text)') is not null as tepki_ver;
