-- Günlük Rutin: görev günleri, izin günü, ilerleme paylaşımı, giriş deneme sınırı, hesap silme
-- 2-arkadaslar.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.

-- Haftanın günleri bit olarak: Pzt=1, Sal=2, Çar=4, Per=8, Cum=16, Cmt=32, Paz=64 (127 = her gün)
alter table public.tasks add column if not exists days int not null default 127;
alter table public.tasks drop constraint if exists tasks_days_check;
alter table public.tasks add constraint tasks_days_check check (days between 1 and 127);

-- İzin günü: seri bozulmaz, artmaz
alter table public.day_logs add column if not exists frozen boolean not null default false;

-- Arkadaşların görebileceği özet (kişi paylaşmayı kapatabilir)
alter table public.profiles
  add column if not exists streak int not null default 0,
  add column if not exists today_done int not null default 0,
  add column if not exists today_total int not null default 0,
  add column if not exists progress_day date,
  add column if not exists share_progress boolean not null default true;
grant update (full_name, best_streak, last_seen_at, streak, today_done, today_total, progress_day, share_progress)
  on public.profiles to authenticated;

-- ---------- Ad soyadla girişe deneme sınırı: 10 dakikada 5 yanlış deneme ----------
create table if not exists public.login_attempts (
  name_key text not null,
  at timestamptz not null default now()
);
create index if not exists login_attempts_idx on public.login_attempts (name_key, at);
alter table public.login_attempts enable row level security;
revoke all on public.login_attempts from anon, authenticated;

create or replace function public.giris_eposta(p_ad text, p_sifre text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v text;
  k text := lower(trim(p_ad));
begin
  delete from public.login_attempts where at < now() - interval '1 day';
  if (select count(*) from public.login_attempts where name_key = k and at > now() - interval '10 minutes') >= 5 then
    raise exception 'cok_fazla_deneme' using errcode = 'P0001';
  end if;
  select u.email into v
  from auth.users u join public.profiles p on p.id = u.id
  where lower(p.full_name) = k
    and u.encrypted_password = extensions.crypt(p_sifre, u.encrypted_password)
  limit 1;
  if v is null then
    insert into public.login_attempts (name_key) values (k);
  else
    delete from public.login_attempts where name_key = k;
  end if;
  return v;
end $$;
revoke all on function public.giris_eposta(text, text) from public;
grant execute on function public.giris_eposta(text, text) to anon, authenticated;

-- ---------- Arkadaş listesi artık paylaşılan ilerlemeyi de döndürür ----------
drop function if exists public.arkadaslarim();
create function public.arkadaslarim()
returns table (id uuid, friend_id uuid, full_name text, status text, gelen boolean, lakap text, created_at timestamptz,
               paylasiyor boolean, streak int, today_done int, today_total int, progress_day date)
language sql stable security definer set search_path = '' as $$
  select f.id, p.id, p.full_name, f.status, f.addressee = auth.uid(), n.nickname, coalesce(f.accepted_at, f.created_at),
         p.share_progress and f.status = 'accepted',
         case when p.share_progress and f.status = 'accepted' then p.streak end,
         case when p.share_progress and f.status = 'accepted' then p.today_done end,
         case when p.share_progress and f.status = 'accepted' then p.today_total end,
         case when p.share_progress and f.status = 'accepted' then p.progress_day end
  from public.friendships f
  join public.profiles p
    on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  left join public.nicknames n on n.owner = auth.uid() and n.target = p.id
  where auth.uid() in (f.requester, f.addressee)
  order by lower(coalesce(n.nickname, p.full_name));
$$;
revoke all on function public.arkadaslarim() from public;
grant execute on function public.arkadaslarim() to authenticated;

-- ---------- Hesabı silme: profil, görevler, günler, arkadaşlıklar ve lakaplar birlikte silinir ----------
create or replace function public.hesabimi_sil()
returns void language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'giriş gerekli' using errcode = '42501'; end if;
  delete from auth.users where id = auth.uid();
end $$;
revoke all on function public.hesabimi_sil() from public;
grant execute on function public.hesabimi_sil() to authenticated;

-- ---------- Yönetici özeti ----------
create or replace function public.yonetici_ozet()
returns json language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_admin) then
    raise exception 'yetki yok' using errcode = '42501';
  end if;
  return json_build_object(
    'kullanici', (select count(*) from public.profiles),
    'bugun_is_yapan', (select count(*) from public.profiles
                        where progress_day = (now() at time zone 'Europe/Istanbul')::date and today_done > 0),
    'arkadaslik', (select count(*) from public.friendships where status = 'accepted'),
    'lakap', (select count(*) from public.nicknames)
  );
end $$;
revoke all on function public.yonetici_ozet() from public;
grant execute on function public.yonetici_ozet() to authenticated;
