-- Günlük Rutin: telefon bildirimleri, dürtme, sabah/akşam hatırlatması, haftalık özet
-- 3-seri-ve-hesap.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- ---------- Gizli ayarlar (yalnızca sunucu fonksiyonları okur) ----------
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table if not exists private.ayarlar (ad text primary key, deger text not null);
-- Zamanlanmış görevin Edge Function'a kendini tanıtacağı rastgele anahtar
insert into private.ayarlar (ad, deger)
  values ('cron', replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''))
  on conflict (ad) do nothing;

create or replace function public.ayar_oku(p_ad text)
returns text language sql stable security definer set search_path = '' as $$
  select deger from private.ayarlar where ad = p_ad;
$$;
create or replace function public.ayar_yaz(p_ad text, p_deger text)
returns void language sql security definer set search_path = '' as $$
  insert into private.ayarlar (ad, deger) values (p_ad, p_deger) on conflict (ad) do nothing;
$$;
revoke all on function public.ayar_oku(text), public.ayar_yaz(text, text) from public, anon, authenticated;
grant execute on function public.ayar_oku(text), public.ayar_yaz(text, text) to service_role;

-- ---------- Ayarlar ----------
alter table public.tasks add column if not exists pokeable boolean not null default false;
alter table public.profiles
  add column if not exists remind_morning boolean not null default true,
  add column if not exists remind_evening boolean not null default true,
  add column if not exists weekly_summary boolean not null default true,
  add column if not exists allow_poke boolean not null default true;
grant update (full_name, best_streak, last_seen_at, streak, today_done, today_total, progress_day, share_progress,
              remind_morning, remind_evening, weekly_summary, allow_poke)
  on public.profiles to authenticated;

-- ---------- Bildirim abonelikleri (cihaz başına bir satır) ----------
create table if not exists public.push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from anon, authenticated;

-- Aynı tarayıcıda hesap değişirse abonelik yeni hesaba geçer
create or replace function public.abone_ol(p_endpoint text, p_p256dh text, p_auth text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'giriş gerekli' using errcode = '42501'; end if;
  insert into public.push_subscriptions (endpoint, user_id, p256dh, auth)
  values (p_endpoint, auth.uid(), p_p256dh, p_auth)
  on conflict (endpoint) do update set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth;
end $$;
create or replace function public.abonelik_sil(p_endpoint text)
returns void language sql security definer set search_path = '' as $$
  delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid();
$$;
revoke all on function public.abone_ol(text, text, text), public.abonelik_sil(text) from public;
grant execute on function public.abone_ol(text, text, text), public.abonelik_sil(text) to authenticated;

-- ---------- Dürtme ----------
create table if not exists public.pokes (
  id uuid primary key default gen_random_uuid(),
  sender uuid not null references auth.users(id) on delete cascade,
  target uuid not null references auth.users(id) on delete cascade,
  task_id uuid references public.tasks(id) on delete set null,
  task_name text,
  note text check (char_length(note) <= 80),
  created_at timestamptz not null default now(),
  pushed_at timestamptz
);
create index if not exists pokes_target_idx on public.pokes (target, created_at);
create index if not exists pokes_sender_idx on public.pokes (sender, created_at);
alter table public.pokes enable row level security;
revoke all on public.pokes from anon, authenticated;

-- Arkadaşın, dürtülmeye izin verdiği ve o gün yapması gereken işleri
create or replace function public.arkadas_gorevleri(p_hedef uuid, p_gun date)
returns table (id uuid, name text, done boolean)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not exists (
    select 1 from public.friendships f where f.status = 'accepted'
      and ((f.requester = auth.uid() and f.addressee = p_hedef) or (f.requester = p_hedef and f.addressee = auth.uid()))
  ) then
    raise exception 'arkadas_degil' using errcode = '42501';
  end if;
  return query
    select t.id, t.name, coalesce(t.id::text = any(d.done), false)
    from public.tasks t
    left join public.day_logs d on d.user_id = t.user_id and d.day = p_gun
    where t.user_id = p_hedef and t.type = 'daily' and t.pokeable
      and (t.days & (1 << (extract(isodow from p_gun)::int - 1))) <> 0
    order by t.position;
end $$;

-- Dürtme kaydı açar; bildirimi Edge Function 'durt-bildir' gönderir.
-- Hatalar: arkadas_degil, durtme_kapali, sessiz_saat, gorev_yok, gorev_bitti, cok_sik, gunluk_sinir
create or replace function public.durt(p_hedef uuid, p_gorev uuid, p_not text, p_gun date)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  saat int := extract(hour from now() at time zone 'Europe/Istanbul');
  g public.tasks;
  pid uuid;
  n text := nullif(left(trim(coalesce(p_not, '')), 80), '');
begin
  if not exists (
    select 1 from public.friendships f where f.status = 'accepted'
      and ((f.requester = me and f.addressee = p_hedef) or (f.requester = p_hedef and f.addressee = me))
  ) then
    raise exception 'arkadas_degil' using errcode = '42501';
  end if;
  if not coalesce((select allow_poke from public.profiles where id = p_hedef), false) then
    raise exception 'durtme_kapali';
  end if;
  if saat >= 23 or saat < 8 then raise exception 'sessiz_saat'; end if;
  if p_gorev is not null then
    select * into g from public.tasks where id = p_gorev and user_id = p_hedef and pokeable and type = 'daily';
    if g.id is null then raise exception 'gorev_yok'; end if;
    if exists (select 1 from public.day_logs d where d.user_id = p_hedef and d.day = p_gun and p_gorev::text = any(d.done)) then
      raise exception 'gorev_bitti';
    end if;
  end if;
  if exists (select 1 from public.pokes where sender = me and target = p_hedef and task_id is not distinct from p_gorev
             and created_at > now() - interval '1 hour') then
    raise exception 'cok_sik';
  end if;
  if (select count(*) from public.pokes where sender = me and created_at > now() - interval '1 day') >= 30 then
    raise exception 'gunluk_sinir';
  end if;
  insert into public.pokes (sender, target, task_id, task_name, note) values (me, p_hedef, g.id, g.name, n)
    returning id into pid;
  return pid;
end $$;

-- Son 7 günde gelen dürtmeler; gönderen, alıcının taktığı lakapla görünür
create or replace function public.durtmelerim()
returns table (id uuid, gonderen text, task_name text, note text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select p.id, coalesce(n.nickname, pr.full_name), p.task_name, p.note, p.created_at
  from public.pokes p
  join public.profiles pr on pr.id = p.sender
  left join public.nicknames n on n.owner = auth.uid() and n.target = p.sender
  where p.target = auth.uid() and p.created_at > now() - interval '7 days'
  order by p.created_at desc
  limit 20;
$$;

revoke all on function public.arkadas_gorevleri(uuid, date), public.durt(uuid, uuid, text, date), public.durtmelerim() from public;
grant execute on function public.arkadas_gorevleri(uuid, date), public.durt(uuid, uuid, text, date), public.durtmelerim() to authenticated;

-- ---------- Hatırlatmalar: kime ne gönderileceği ----------
create or replace function public.hatirlatma_listesi(p_tur text)
returns table (user_id uuid, baslik text, govde text)
language plpgsql stable security definer set search_path = '' as $$
declare
  yerel timestamp := now() at time zone 'Europe/Istanbul';
  gun date := yerel::date;
  bit int := 1 << (extract(isodow from yerel)::int - 1);
begin
  if p_tur = 'sabah' then
    return query
      select p.id, 'Günaydın'::text,
             format('Bugün %s işin var. İlki: %s', count(t.id), (array_agg(t.name order by t.position))[1])
      from public.profiles p
      join public.tasks t on t.user_id = p.id and t.type = 'daily' and (t.days & bit) <> 0
      where p.remind_morning
        and exists (select 1 from public.push_subscriptions s where s.user_id = p.id)
        and not exists (select 1 from public.day_logs d where d.user_id = p.id and d.day = gun and d.frozen)
      group by p.id;
  elsif p_tur = 'aksam' then
    return query
      with plan as (
        select t.user_id, count(*)::int as n from public.tasks t
        where t.type = 'daily' and (t.days & bit) <> 0 group by t.user_id
      )
      select p.id, 'Gün bitmeden'::text,
             case when coalesce(cardinality(d.done), 0) = 0
               then format('Bugün henüz başlamadın. %s işin seni bekliyor.', pl.n)
               else format('%s iş kaldı.%s', pl.n - cardinality(d.done),
                           case when p.streak > 0 then format(' Serin %s gün, bozma.', p.streak) else '' end)
             end
      from public.profiles p
      join plan pl on pl.user_id = p.id
      left join public.day_logs d on d.user_id = p.id and d.day = gun
      where p.remind_evening
        and exists (select 1 from public.push_subscriptions s where s.user_id = p.id)
        and not coalesce(d.frozen, false)
        and coalesce(cardinality(d.done), 0) < pl.n;
  elsif p_tur = 'haftalik' then
    return query
      select p.id, 'Haftalık özet'::text,
             format('Bu hafta %s/7 gün tamam. Serin %s gün, en uzun serin %s gün.',
                    (select count(*) from public.day_logs d
                      where d.user_id = p.id and d.day > gun - 7 and d.day <= gun
                        and d.total > 0 and cardinality(d.done) >= d.total),
                    p.streak, p.best_streak)
      from public.profiles p
      where p.weekly_summary
        and exists (select 1 from public.push_subscriptions s where s.user_id = p.id);
  end if;
end $$;
revoke all on function public.hatirlatma_listesi(text) from public, anon, authenticated;
grant execute on function public.hatirlatma_listesi(text) to service_role;

-- ---------- Zamanlanmış görevler (saatler UTC; Türkiye = UTC+3) ----------
select cron.unschedule(jobname) from cron.job where jobname in ('gr-sabah', 'gr-aksam', 'gr-haftalik');
select cron.schedule('gr-sabah', '0 6 * * *', $$
  select net.http_post(
    url := 'https://foxacfsypoceaiqlrcwv.supabase.co/functions/v1/hatirlat',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron', (select deger from private.ayarlar where ad = 'cron')),
    body := '{"tur":"sabah"}'::jsonb)
$$);
select cron.schedule('gr-aksam', '0 18 * * *', $$
  select net.http_post(
    url := 'https://foxacfsypoceaiqlrcwv.supabase.co/functions/v1/hatirlat',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron', (select deger from private.ayarlar where ad = 'cron')),
    body := '{"tur":"aksam"}'::jsonb)
$$);
select cron.schedule('gr-haftalik', '0 17 * * 0', $$
  select net.http_post(
    url := 'https://foxacfsypoceaiqlrcwv.supabase.co/functions/v1/hatirlat',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cron', (select deger from private.ayarlar where ad = 'cron')),
    body := '{"tur":"haftalik"}'::jsonb)
$$);
