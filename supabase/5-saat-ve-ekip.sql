-- Günlük Rutin: görev saatleri, ayarlanabilir hatırlatma saatleri, ekipler ve ekip görevleri
-- 4-bildirim.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.

-- ---------- Saatler ----------
alter table public.tasks add column if not exists time time;
alter table public.tasks add column if not exists end_time time;  -- saat aralığının bitişi (isteğe bağlı)
alter table public.profiles
  add column if not exists morning_time time not null default '09:00',
  add column if not exists evening_time time not null default '21:00',
  add column if not exists remind_tasks boolean not null default true;
grant update (full_name, best_streak, last_seen_at, streak, today_done, today_total, progress_day, share_progress,
              remind_morning, remind_evening, weekly_summary, allow_poke, morning_time, evening_time, remind_tasks)
  on public.profiles to authenticated;

-- ---------- Ekipler ----------
create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 40),
  leader uuid not null references auth.users(id) on delete cascade,
  code text not null unique,
  created_at timestamptz not null default now()
);
create table if not exists public.team_members (
  team_id uuid not null references public.teams(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (team_id, user_id)
);
alter table public.teams enable row level security;
alter table public.team_members enable row level security;
revoke all on public.teams, public.team_members from anon, authenticated;

create or replace function public.ekip_uyesi_mi(p_team uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.team_members where team_id = p_team and user_id = auth.uid());
$$;
revoke all on function public.ekip_uyesi_mi(uuid) from public;
grant execute on function public.ekip_uyesi_mi(uuid) to authenticated;

-- Üyeler ekibin adını görebilir (görev listesinde "Ekip: …" yazısı için)
drop policy if exists "ekip_oku" on public.teams;
create policy "ekip_oku" on public.teams for select to authenticated using (public.ekip_uyesi_mi(id));
grant select (id, name) on public.teams to authenticated;

-- ---------- Ekip görevleri: başkanın verdiği iş, üyenin kendi listesine düşer ----------
alter table public.tasks add column if not exists team_id uuid;
alter table public.tasks add column if not exists assigned_by uuid references auth.users(id) on delete set null;
alter table public.tasks add column if not exists notified_at timestamptz;
alter table public.tasks drop constraint if exists tasks_team_fk;
alter table public.tasks add constraint tasks_team_fk foreign key (team_id) references public.teams(id) on delete cascade;

-- Üye kendi görevlerini yönetir; ekip görevini silemez, ekip/atayan bilgisini değiştiremez.
drop policy if exists "gorev_kendi" on public.tasks;
drop policy if exists "gorev_oku" on public.tasks;
drop policy if exists "gorev_ekle" on public.tasks;
drop policy if exists "gorev_guncelle" on public.tasks;
drop policy if exists "gorev_sil" on public.tasks;
create policy "gorev_oku" on public.tasks for select to authenticated using (user_id = auth.uid());
create policy "gorev_ekle" on public.tasks for insert to authenticated
  with check (user_id = auth.uid() and assigned_by is null and team_id is null);
create policy "gorev_guncelle" on public.tasks for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "gorev_sil" on public.tasks for delete to authenticated
  using (user_id = auth.uid() and assigned_by is null);
revoke insert, update on public.tasks from authenticated;
grant insert (id, user_id, name, type, dur, days, pokeable, due, done, done_at, position, time, end_time) on public.tasks to authenticated;
grant update (id, user_id, name, type, dur, days, pokeable, due, done, done_at, position, time, end_time) on public.tasks to authenticated;

-- Ekip kur: kuran kişi başkan ve ilk üye olur
create or replace function public.ekip_kur(p_ad text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  kod text;
  harfler constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  tid uuid;
begin
  if me is null then raise exception 'giriş gerekli' using errcode = '42501'; end if;
  if (select count(*) from public.teams where leader = me) >= 10 then raise exception 'ekip_siniri'; end if;
  loop
    kod := '';
    for i in 1..6 loop kod := kod || substr(harfler, 1 + floor(random() * length(harfler))::int, 1); end loop;
    exit when not exists (select 1 from public.teams where code = kod);
  end loop;
  insert into public.teams (name, leader, code) values (left(trim(p_ad), 40), me, kod) returning id into tid;
  insert into public.team_members (team_id, user_id) values (tid, me);
  return tid;
end $$;

-- Kodla katıl. Dönen: katildi, zaten, bulunamadi, dolu
create or replace function public.ekibe_katil(p_kod text)
returns text language plpgsql security definer set search_path = '' as $$
declare tid uuid;
begin
  if auth.uid() is null then raise exception 'giriş gerekli' using errcode = '42501'; end if;
  select id into tid from public.teams where code = upper(trim(p_kod));
  if tid is null then return 'bulunamadi'; end if;
  if exists (select 1 from public.team_members where team_id = tid and user_id = auth.uid()) then return 'zaten'; end if;
  if (select count(*) from public.team_members where team_id = tid) >= 50 then return 'dolu'; end if;
  insert into public.team_members (team_id, user_id) values (tid, auth.uid());
  return 'katildi';
end $$;

-- Ekiplerim; kod yalnızca başkana döner
create or replace function public.ekiplerim()
returns table (id uuid, name text, code text, lider_mi boolean, lider_adi text, uye_sayisi int)
language sql stable security definer set search_path = '' as $$
  select t.id, t.name, case when t.leader = auth.uid() then t.code end, t.leader = auth.uid(), p.full_name,
         (select count(*)::int from public.team_members m2 where m2.team_id = t.id)
  from public.teams t
  join public.team_members m on m.team_id = t.id and m.user_id = auth.uid()
  join public.profiles p on p.id = t.leader
  order by t.created_at;
$$;

-- Ekibin bugünkü durumu: her üye ve ona verilmiş ekip görevleri (görevsiz üye tek satır)
create or replace function public.ekip_durumu(p_team uuid, p_gun date)
returns table (user_id uuid, full_name text, lider boolean, gorev_id uuid, gorev_adi text, tur text,
               gunler int, saat time, bitis time, son_tarih date, bitti boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.ekip_uyesi_mi(p_team) then raise exception 'ekip_uyesi_degil' using errcode = '42501'; end if;
  return query
    select m.user_id, p.full_name, t.leader = m.user_id, k.id, k.name, k.type, k.days, k.time, k.end_time, k.due,
           case when k.id is null then null
                when k.type = 'general' then k.done
                else coalesce(k.id::text = any(d.done), false) end
    from public.team_members m
    join public.teams t on t.id = m.team_id
    join public.profiles p on p.id = m.user_id
    left join public.tasks k on k.user_id = m.user_id and k.team_id = p_team
    left join public.day_logs d on d.user_id = m.user_id and d.day = p_gun
    where m.team_id = p_team
    order by t.leader = m.user_id desc, p.full_name, k.time nulls last, k.created_at;
end $$;

-- Başkan üyeye görev verir; görev üyenin listesine eklenir
drop function if exists public.gorev_ver(uuid, uuid, text, text, int, time, int, date);
create or replace function public.gorev_ver(p_team uuid, p_uye uuid, p_ad text, p_tur text, p_gunler int,
                                            p_saat time, p_bitis time, p_sure int, p_son date)
returns uuid language plpgsql security definer set search_path = '' as $$
declare gid uuid;
begin
  if not exists (select 1 from public.teams where id = p_team and leader = auth.uid()) then
    raise exception 'baskan_degil' using errcode = '42501';
  end if;
  if not exists (select 1 from public.team_members where team_id = p_team and user_id = p_uye) then
    raise exception 'uye_degil';
  end if;
  if char_length(trim(coalesce(p_ad, ''))) = 0 then raise exception 'ad_bos'; end if;
  insert into public.tasks (user_id, name, type, dur, days, time, end_time, due, team_id, assigned_by, position)
  values (p_uye, left(trim(p_ad), 80), case when p_tur = 'general' then 'general' else 'daily' end,
          case when p_tur = 'general' then 0 else greatest(0, least(600, coalesce(p_sure, 0))) end,
          case when p_gunler between 1 and 127 then p_gunler else 127 end,
          p_saat, case when p_saat is not null and p_bitis > p_saat then p_bitis end,
          case when p_tur = 'general' then p_son end,
          p_team, auth.uid(),
          coalesce((select max(position) + 1 from public.tasks where user_id = p_uye), 0))
  returning id into gid;
  return gid;
end $$;

-- Başkan ekip görevini kaldırır
create or replace function public.ekip_gorev_sil(p_gorev uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.tasks k
  where k.id = p_gorev and exists (select 1 from public.teams t where t.id = k.team_id and t.leader = auth.uid());
$$;

-- Başkan üyeyi çıkarır; üyenin bu ekipten gelen görevleri de silinir
create or replace function public.uye_cikar(p_team uuid, p_uye uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.teams where id = p_team and leader = auth.uid()) then
    raise exception 'baskan_degil' using errcode = '42501';
  end if;
  if p_uye = auth.uid() then raise exception 'baskan_cikamaz'; end if;
  delete from public.team_members where team_id = p_team and user_id = p_uye;
  delete from public.tasks where team_id = p_team and user_id = p_uye;
end $$;

-- Üye ekipten ayrılır (başkan ayrılamaz, ekibi siler)
create or replace function public.ekipten_ayril(p_team uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.teams where id = p_team and leader = auth.uid()) then
    raise exception 'baskan_ayrilamaz';
  end if;
  delete from public.team_members where team_id = p_team and user_id = auth.uid();
  delete from public.tasks where team_id = p_team and user_id = auth.uid();
end $$;

-- Başkan ekibi siler; üyelikler ve ekip görevleri de silinir
create or replace function public.ekip_sil(p_team uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.teams where id = p_team and leader = auth.uid();
$$;

revoke all on function public.ekip_kur(text), public.ekibe_katil(text), public.ekiplerim(), public.ekip_durumu(uuid, date),
  public.gorev_ver(uuid, uuid, text, text, int, time, time, int, date), public.ekip_gorev_sil(uuid), public.uye_cikar(uuid, uuid),
  public.ekipten_ayril(uuid), public.ekip_sil(uuid) from public;
grant execute on function public.ekip_kur(text), public.ekibe_katil(text), public.ekiplerim(), public.ekip_durumu(uuid, date),
  public.gorev_ver(uuid, uuid, text, text, int, time, time, int, date), public.ekip_gorev_sil(uuid), public.uye_cikar(uuid, uuid),
  public.ekipten_ayril(uuid), public.ekip_sil(uuid) to authenticated;

-- ---------- Hatırlatmalar: 5 dakikada bir, kişinin seçtiği saatlere göre ----------
drop function if exists public.hatirlatma_listesi(text);
create function public.hatirlatma_listesi(p_tur text)
returns table (user_id uuid, baslik text, govde text, etiket text)
language plpgsql stable security definer set search_path = '' as $$
declare
  yerel timestamp := now() at time zone 'Europe/Istanbul';
  gun date := yerel::date;
  bit int := 1 << (extract(isodow from yerel)::int - 1);
  t0 time := (date_trunc('hour', yerel) + floor(extract(minute from yerel) / 5) * interval '5 minutes')::time;
  t1 time := t0 + interval '5 minutes';
begin
  if p_tur <> 'zaman' then return; end if;
  return query
    -- sabah: kişinin sabah saati bu 5 dakikadaysa
    select p.id, 'Günaydın'::text,
           format('Bugün %s işin var. İlki: %s', count(t.id), (array_agg(t.name order by t.time nulls last, t.position))[1]),
           'sabah'::text
    from public.profiles p
    join public.tasks t on t.user_id = p.id and t.type = 'daily' and (t.days & bit) <> 0
    where p.remind_morning and p.morning_time >= t0 and (p.morning_time < t1 or t1 <= t0)
      and exists (select 1 from public.push_subscriptions s where s.user_id = p.id)
      and not exists (select 1 from public.day_logs d where d.user_id = p.id and d.day = gun and d.frozen)
    group by p.id
  union all
    -- akşam: yalnızca bitmemiş iş varsa
    select p.id, 'Gün bitmeden'::text,
           case when coalesce(cardinality(d.done), 0) = 0
             then format('Bugün henüz başlamadın. %s işin seni bekliyor.', pl.n)
             else format('%s iş kaldı.%s', pl.n - cardinality(d.done),
                         case when p.streak > 0 then format(' Serin %s gün, bozma.', p.streak) else '' end)
           end,
           'aksam'::text
    from public.profiles p
    join (select k.user_id, count(*)::int as n from public.tasks k
          where k.type = 'daily' and (k.days & bit) <> 0 group by k.user_id) pl on pl.user_id = p.id
    left join public.day_logs d on d.user_id = p.id and d.day = gun
    where p.remind_evening and p.evening_time >= t0 and (p.evening_time < t1 or t1 <= t0)
      and exists (select 1 from public.push_subscriptions s where s.user_id = p.id)
      and not coalesce(d.frozen, false)
      and coalesce(cardinality(d.done), 0) < pl.n
  union all
    -- görev saati: planlanan saat geldi ve iş bitmedi (günlük iş ya da bugüne tarihli tek seferlik iş)
    select t.user_id, t.name,
           case when t.end_time is not null
             then format('%s–%s arası planladığın iş başlıyor', to_char(t.time, 'HH24:MI'), to_char(t.end_time, 'HH24:MI'))
             else format('%s · planladığın saat geldi', to_char(t.time, 'HH24:MI')) end,
           'gorev-' || t.id
    from public.tasks t
    join public.profiles p on p.id = t.user_id
    where p.remind_tasks and t.time is not null
      and t.time >= t0 and (t.time < t1 or t1 <= t0)
      and exists (select 1 from public.push_subscriptions s where s.user_id = t.user_id)
      and ((t.type = 'daily' and (t.days & bit) <> 0
            and not exists (select 1 from public.day_logs d where d.user_id = t.user_id and d.day = gun
                            and (d.frozen or t.id::text = any(d.done))))
        or (t.type = 'general' and t.due = gun and not t.done))
  union all
    -- haftalık özet: Pazar 20:00
    select p.id, 'Haftalık özet'::text,
           format('Bu hafta %s/7 gün tamam. Serin %s gün, en uzun serin %s gün.',
                  (select count(*) from public.day_logs d
                    where d.user_id = p.id and d.day > gun - 7 and d.day <= gun
                      and d.total > 0 and cardinality(d.done) >= d.total),
                  p.streak, p.best_streak),
           'haftalik'::text
    from public.profiles p
    where extract(isodow from yerel) = 7 and time '20:00' >= t0 and time '20:00' < t1
      and p.weekly_summary
      and exists (select 1 from public.push_subscriptions s where s.user_id = p.id);
end $$;
revoke all on function public.hatirlatma_listesi(text) from public, anon, authenticated;
grant execute on function public.hatirlatma_listesi(text) to service_role;

select cron.unschedule(jobname) from cron.job where jobname in ('gr-sabah', 'gr-aksam', 'gr-haftalik', 'gr-zaman');
select cron.schedule('gr-zaman', '*/5 * * * *', $$
  select net.http_post(
    url := 'https://foxacfsypoceaiqlrcwv.supabase.co/functions/v1/hatirlat',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron', (select deger from private.ayarlar where ad = 'cron')),
    body := '{"tur":"zaman"}'::jsonb)
$$);
