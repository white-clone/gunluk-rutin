-- Günlük Rutin: özellik kullanım sayaçları (yönetici panelinde "Özellikler" sekmesi)
-- 14-akis-ve-tepki.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.
-- Kişi başına, gün başına, özellik başına bir sayaç tutulur; içerik (iş adı vb.) tutulmaz.

create table if not exists public.feature_usage (
  user_id uuid not null references auth.users(id) on delete cascade,
  feature text not null check (feature ~ '^[a-z_]{2,30}$'),
  day date not null,
  count int not null default 0,
  primary key (user_id, feature, day)
);
create index if not exists feature_usage_day_idx on public.feature_usage (day);
alter table public.feature_usage enable row level security;
revoke all on public.feature_usage from anon, authenticated;

-- Uygulama biriken sayaçları toplu gönderir: {"bitti": 3, "is_ekle": 1}
create or replace function public.kullanim_yaz(p_sayac jsonb)
returns void language plpgsql security definer set search_path = '' as $$
declare
  k text; v int;
  gun date := (now() at time zone 'Europe/Istanbul')::date;
  n int := 0;
begin
  if auth.uid() is null or jsonb_typeof(p_sayac) <> 'object' then return; end if;
  for k, v in select key, least(greatest(coalesce((value #>> '{}')::int, 0), 0), 200) from jsonb_each(p_sayac) loop
    n := n + 1;
    exit when n > 60;
    continue when v = 0 or k !~ '^[a-z_]{2,30}$';
    insert into public.feature_usage (user_id, feature, day, count) values (auth.uid(), k, gun, v)
    on conflict (user_id, feature, day) do update set count = public.feature_usage.count + excluded.count;
  end loop;
end $$;

-- Yönetici: son p_gun gündeki kullanım, kişi sayısı ve önceki aynı uzunluktaki dönemle karşılaştırma
create or replace function public.yonetici_ozellikler(p_gun int default 30)
returns table (feature text, toplam bigint, kisi bigint, onceki bigint, son_gun date)
language plpgsql stable security definer set search_path = '' as $$
declare bugun date := (now() at time zone 'Europe/Istanbul')::date;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_admin) then
    raise exception 'yetki yok' using errcode = '42501';
  end if;
  p_gun := least(greatest(coalesce(p_gun, 30), 1), 365);
  return query
    select u.feature,
           coalesce(sum(u.count) filter (where u.day > bugun - p_gun), 0)::bigint,
           count(distinct u.user_id) filter (where u.day > bugun - p_gun)::bigint,
           coalesce(sum(u.count) filter (where u.day <= bugun - p_gun and u.day > bugun - 2 * p_gun), 0)::bigint,
           max(u.day)
    from public.feature_usage u
    where u.day > bugun - 2 * p_gun
    group by u.feature
    order by 2 desc;
end $$;

-- Yönetici: günlük toplam kullanım ve aktif kişi (grafik için)
create or replace function public.yonetici_kullanim_gunluk(p_gun int default 30)
returns table (day date, toplam bigint, kisi bigint)
language plpgsql stable security definer set search_path = '' as $$
declare bugun date := (now() at time zone 'Europe/Istanbul')::date;
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_admin) then
    raise exception 'yetki yok' using errcode = '42501';
  end if;
  p_gun := least(greatest(coalesce(p_gun, 30), 1), 365);
  return query
    select g.d::date, coalesce(sum(u.count), 0)::bigint, count(distinct u.user_id)::bigint
    from generate_series(bugun - p_gun + 1, bugun, interval '1 day') g(d)
    left join public.feature_usage u on u.day = g.d::date
    group by g.d order by g.d;
end $$;

revoke all on function public.kullanim_yaz(jsonb), public.yonetici_ozellikler(int), public.yonetici_kullanim_gunluk(int) from public;
grant execute on function public.kullanim_yaz(jsonb), public.yonetici_ozellikler(int), public.yonetici_kullanim_gunluk(int) to authenticated;
