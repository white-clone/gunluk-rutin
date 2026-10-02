-- Günlük Rutin: ekibi arkadaşlarla kurma ve ekibe arkadaş ekleme
-- 5-saat-ve-ekip.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.

-- Yalnızca kabul edilmiş arkadaşlar eklenebilir
create or replace function public.arkadas_mi(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.friendships f where f.status = 'accepted'
      and ((f.requester = p_a and f.addressee = p_b) or (f.requester = p_b and f.addressee = p_a))
  );
$$;
revoke all on function public.arkadas_mi(uuid, uuid) from public, anon, authenticated;

-- Ekip kur: ad + başlangıçta eklenecek arkadaşlar (kuran kişi başkan ve ilk üye olur)
drop function if exists public.ekip_kur(text);
create or replace function public.ekip_kur(p_ad text, p_uyeler uuid[] default '{}')
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  kod text;
  harfler constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  tid uuid;
begin
  if me is null then raise exception 'giriş gerekli' using errcode = '42501'; end if;
  if char_length(trim(coalesce(p_ad, ''))) < 2 then raise exception 'ad_kisa'; end if;
  if (select count(*) from public.teams where leader = me) >= 10 then raise exception 'ekip_siniri'; end if;
  loop
    kod := '';
    for i in 1..6 loop kod := kod || substr(harfler, 1 + floor(random() * length(harfler))::int, 1); end loop;
    exit when not exists (select 1 from public.teams where code = kod);
  end loop;
  insert into public.teams (name, leader, code) values (left(trim(p_ad), 40), me, kod) returning id into tid;
  insert into public.team_members (team_id, user_id) values (tid, me);
  insert into public.team_members (team_id, user_id)
    select tid, u.id
    from (select distinct unnest(coalesce(p_uyeler, '{}'::uuid[])) as id) u
    where u.id <> me and public.arkadas_mi(me, u.id)
    limit 49
  on conflict do nothing;
  return tid;
end $$;

-- Başkan mevcut ekibe arkadaşlarını ekler; eklenen kişi sayısını döndürür
create or replace function public.ekibe_arkadas_ekle(p_team uuid, p_uyeler uuid[])
returns int language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  bos int;
  n int;
begin
  if not exists (select 1 from public.teams where id = p_team and leader = me) then
    raise exception 'baskan_degil' using errcode = '42501';
  end if;
  bos := 50 - (select count(*) from public.team_members where team_id = p_team);
  if bos <= 0 then return 0; end if;
  insert into public.team_members (team_id, user_id)
    select p_team, u.id
    from (select distinct unnest(coalesce(p_uyeler, '{}'::uuid[])) as id) u
    where u.id <> me and public.arkadas_mi(me, u.id)
      and not exists (select 1 from public.team_members m where m.team_id = p_team and m.user_id = u.id)
    limit bos
  on conflict do nothing;
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.ekip_kur(text, uuid[]), public.ekibe_arkadas_ekle(uuid, uuid[]) from public;
grant execute on function public.ekip_kur(text, uuid[]), public.ekibe_arkadas_ekle(uuid, uuid[]) to authenticated;
