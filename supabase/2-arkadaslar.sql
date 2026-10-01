-- Günlük Rutin: arkadaşlar ve lakaplar
-- kurulum.sql'den sonra SQL Editor'de bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.
-- Tablolara doğrudan erişim yoktur; her şey aşağıdaki fonksiyonlarla yapılır.

create table if not exists public.friendships (
  id uuid primary key default gen_random_uuid(),
  requester uuid not null default auth.uid() references auth.users(id) on delete cascade,
  addressee uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  check (requester <> addressee)
);
-- İki kişi arasında tek kayıt olur (A→B varken B→A açılamaz)
create unique index if not exists friendships_pair_idx
  on public.friendships (least(requester, addressee), greatest(requester, addressee));

-- Lakabı yalnızca takan kişi (ve yönetici) görür
create table if not exists public.nicknames (
  owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
  target uuid not null references auth.users(id) on delete cascade,
  nickname text not null check (char_length(nickname) between 1 and 40),
  updated_at timestamptz not null default now(),
  primary key (owner, target)
);

alter table public.friendships enable row level security;
alter table public.nicknames enable row level security;
revoke all on public.friendships, public.nicknames from anon, authenticated;

-- Kodla arkadaş ekleme. Dönen değerler: gonderildi, kabul, bekliyor, zaten, kendin, bulunamadi
create or replace function public.arkadas_ekle(p_kod text)
returns text language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  hedef uuid;
  f public.friendships;
begin
  if me is null then raise exception 'giriş gerekli' using errcode = '42501'; end if;
  select id into hedef from public.profiles where friend_code = upper(trim(p_kod));
  if hedef is null then return 'bulunamadi'; end if;
  if hedef = me then return 'kendin'; end if;
  select * into f from public.friendships
    where (requester = me and addressee = hedef) or (requester = hedef and addressee = me);
  if found then
    if f.status = 'accepted' then return 'zaten'; end if;
    if f.requester = hedef then
      update public.friendships set status = 'accepted', accepted_at = now() where id = f.id;
      return 'kabul';
    end if;
    return 'bekliyor';
  end if;
  insert into public.friendships (requester, addressee) values (me, hedef);
  return 'gonderildi';
end $$;

-- Giriş yapan kullanıcının arkadaşları, gelen ve gönderilen istekleri
create or replace function public.arkadaslarim()
returns table (id uuid, friend_id uuid, full_name text, status text, gelen boolean, lakap text, created_at timestamptz)
language sql stable security definer set search_path = '' as $$
  select f.id, p.id, p.full_name, f.status, f.addressee = auth.uid(), n.nickname, coalesce(f.accepted_at, f.created_at)
  from public.friendships f
  join public.profiles p
    on p.id = case when f.requester = auth.uid() then f.addressee else f.requester end
  left join public.nicknames n on n.owner = auth.uid() and n.target = p.id
  where auth.uid() in (f.requester, f.addressee)
  order by lower(coalesce(n.nickname, p.full_name));
$$;

-- Gelen isteği kabul et ya da reddet
create or replace function public.arkadas_yanit(p_id uuid, p_kabul boolean)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_kabul then
    update public.friendships set status = 'accepted', accepted_at = now()
      where id = p_id and addressee = auth.uid() and status = 'pending';
  else
    delete from public.friendships where id = p_id and addressee = auth.uid() and status = 'pending';
  end if;
end $$;

-- Arkadaşlıktan çıkar ya da gönderilen isteği geri al; iki taraftaki lakaplar da silinir
create or replace function public.arkadas_sil(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare f public.friendships;
begin
  delete from public.friendships where id = p_id and auth.uid() in (requester, addressee) returning * into f;
  if f.id is not null then
    delete from public.nicknames
      where (owner = f.requester and target = f.addressee) or (owner = f.addressee and target = f.requester);
  end if;
end $$;

-- Arkadaşa lakap tak; boş lakap mevcut lakabı kaldırır
create or replace function public.lakap_tak(p_hedef uuid, p_lakap text)
returns void language plpgsql security definer set search_path = '' as $$
declare l text := nullif(trim(p_lakap), '');
begin
  if not exists (
    select 1 from public.friendships
    where status = 'accepted'
      and ((requester = auth.uid() and addressee = p_hedef) or (requester = p_hedef and addressee = auth.uid()))
  ) then
    raise exception 'yalnızca arkadaşlarına lakap takabilirsin' using errcode = '42501';
  end if;
  if l is null then
    delete from public.nicknames where owner = auth.uid() and target = p_hedef;
    return;
  end if;
  insert into public.nicknames (owner, target, nickname) values (auth.uid(), p_hedef, left(l, 40))
  on conflict (owner, target) do update set nickname = excluded.nickname, updated_at = now();
end $$;

-- Yönetici: kim kime hangi lakabı takmış
create or replace function public.yonetici_lakaplar()
returns table (takan text, lakap text, hedef text, updated_at timestamptz)
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.profiles where id = auth.uid() and is_admin) then
    raise exception 'yetki yok' using errcode = '42501';
  end if;
  return query
    select a.full_name, n.nickname, b.full_name, n.updated_at
    from public.nicknames n
    join public.profiles a on a.id = n.owner
    join public.profiles b on b.id = n.target
    order by n.updated_at desc;
end $$;

revoke all on function public.arkadas_ekle(text), public.arkadaslarim(), public.arkadas_yanit(uuid, boolean),
  public.arkadas_sil(uuid), public.lakap_tak(uuid, text), public.yonetici_lakaplar() from public;
grant execute on function public.arkadas_ekle(text), public.arkadaslarim(), public.arkadas_yanit(uuid, boolean),
  public.arkadas_sil(uuid), public.lakap_tak(uuid, text), public.yonetici_lakaplar() to authenticated;
