-- Günlük Rutin: veritabanı kurulumu
-- Supabase → SQL Editor'de bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.

-- ---------- Tablolar ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null check (char_length(full_name) between 2 and 80),
  friend_code text not null unique,
  is_admin boolean not null default false,
  best_streak int not null default 0,
  last_seen_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.tasks (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 80),
  type text not null check (type in ('daily', 'general')),
  dur int not null default 0 check (dur between 0 and 600),
  due date,
  done boolean not null default false,
  done_at timestamptz,
  position int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists tasks_user_idx on public.tasks (user_id, position);

-- Her gün için: biten ve atlanan görevler, bitiş saatleri ve o günkü günlük görev sayısı
create table if not exists public.day_logs (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  day date not null,
  done text[] not null default '{}',
  skip text[] not null default '{}',
  at jsonb not null default '{}',
  total int not null default 0,
  primary key (user_id, day)
);

-- ---------- Erişim kuralları: herkes yalnızca kendi verisini görür ----------
alter table public.profiles enable row level security;
alter table public.tasks enable row level security;
alter table public.day_logs enable row level security;

drop policy if exists "profil_oku" on public.profiles;
create policy "profil_oku" on public.profiles for select to authenticated using (id = auth.uid());
drop policy if exists "profil_guncelle" on public.profiles;
create policy "profil_guncelle" on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "gorev_kendi" on public.tasks;
create policy "gorev_kendi" on public.tasks for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "gun_kendi" on public.day_logs;
create policy "gun_kendi" on public.day_logs for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Kullanıcı profilinde yalnızca bu sütunları değiştirebilir; is_admin ve friend_code korunur.
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (full_name, best_streak, last_seen_at) on public.profiles to authenticated;

revoke all on public.tasks, public.day_logs from anon;
grant select, insert, update, delete on public.tasks, public.day_logs to authenticated;

-- ---------- Kayıtta profil ve arkadaş kodu ----------
create or replace function public.yeni_kullanici()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  kod text;
  harfler constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  loop
    kod := '';
    for i in 1..6 loop
      kod := kod || substr(harfler, 1 + floor(random() * length(harfler))::int, 1);
    end loop;
    exit when not exists (select 1 from public.profiles where friend_code = kod);
  end loop;
  insert into public.profiles (id, full_name, friend_code)
  values (
    new.id,
    coalesce(nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''), split_part(new.email, '@', 1)),
    kod
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.yeni_kullanici();

-- ---------- Ad soyad ile giriş ----------
-- E-postayı yalnızca ad soyad ve şifre birlikte doğruysa döndürür; böylece kimse
-- bir ismin e-posta adresini şifresiz öğrenemez.
create or replace function public.giris_eposta(p_ad text, p_sifre text)
returns text language plpgsql security definer set search_path = '' as $$
declare v text;
begin
  select u.email into v
  from auth.users u join public.profiles p on p.id = u.id
  where lower(p.full_name) = lower(trim(p_ad))
    and u.encrypted_password = extensions.crypt(p_sifre, u.encrypted_password)
  limit 1;
  return v;
end $$;
revoke all on function public.giris_eposta(text, text) from public;
grant execute on function public.giris_eposta(text, text) to anon, authenticated;

-- ---------- Yönetici: kullanıcı adları ve giriş zamanları ----------
create or replace function public.yonetici_kullanicilar()
returns table (full_name text, created_at timestamptz, last_sign_in_at timestamptz, last_seen_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_admin) then
    raise exception 'yetki yok' using errcode = '42501';
  end if;
  return query
    select p.full_name, p.created_at, u.last_sign_in_at, p.last_seen_at
    from public.profiles p join auth.users u on u.id = p.id
    order by greatest(u.last_sign_in_at, p.last_seen_at) desc nulls last;
end $$;
revoke all on function public.yonetici_kullanicilar() from public;
grant execute on function public.yonetici_kullanicilar() to authenticated;

-- ---------- Yöneticiyi işaretleme (kayıttan sonra, e-postayı değiştirip ayrıca çalıştır) ----------
-- update public.profiles set is_admin = true
--   where id = (select id from auth.users where email = 'SENIN@EPOSTAN.com');
