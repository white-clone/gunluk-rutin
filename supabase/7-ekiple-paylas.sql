-- Günlük Rutin: kişinin kendi planladığı işi sonradan ekipleriyle paylaşması
-- 6-ekip-arkadas.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.
-- Paylaşılan iş, ekip üyelerinin takviminde "ekip planı" olarak görünür; üyeler isterse kendi listesine kopyalar.

create table if not exists public.task_shares (
  task_id uuid not null references public.tasks(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete cascade,
  shared_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (task_id, team_id)
);
create index if not exists task_shares_team_idx on public.task_shares (team_id);
alter table public.task_shares enable row level security;
revoke all on public.task_shares from anon, authenticated;

-- Kendi işini, üyesi olduğun bir ekiple paylaş (ekip görevleri paylaşılamaz)
create or replace function public.paylas(p_task uuid, p_team uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.tasks where id = p_task and user_id = auth.uid() and team_id is null) then
    raise exception 'gorev_senin_degil' using errcode = '42501';
  end if;
  if not public.ekip_uyesi_mi(p_team) then raise exception 'ekip_uyesi_degil' using errcode = '42501'; end if;
  insert into public.task_shares (task_id, team_id, shared_by) values (p_task, p_team, auth.uid())
  on conflict do nothing;
end $$;

create or replace function public.paylasimi_kaldir(p_task uuid, p_team uuid)
returns void language sql security definer set search_path = '' as $$
  delete from public.task_shares where task_id = p_task and team_id = p_team and shared_by = auth.uid();
$$;

-- Kendi işlerimin hangi ekiplerle paylaşıldığı
create or replace function public.paylasimlarim()
returns table (task_id uuid, team_id uuid)
language sql stable security definer set search_path = '' as $$
  select s.task_id, s.team_id from public.task_shares s where s.shared_by = auth.uid();
$$;

-- Üyesi olduğum ekiplerde paylaşılan planlar (kendi paylaştıklarım da, "benim" işaretiyle)
create or replace function public.ekip_planlari()
returns table (task_id uuid, name text, type text, due date, days int, saat time, bitis time,
               team_id uuid, team_name text, owner_name text, benim boolean)
language sql stable security definer set search_path = '' as $$
  select k.id, k.name, k.type, k.due, k.days, k.time, k.end_time, t.id, t.name, p.full_name, k.user_id = auth.uid()
  from public.task_shares s
  join public.tasks k on k.id = s.task_id
  join public.teams t on t.id = s.team_id
  join public.profiles p on p.id = k.user_id
  where public.ekip_uyesi_mi(s.team_id)
    and (k.type = 'daily' or not k.done)
  order by k.due nulls first, k.time nulls last, k.name;
$$;

-- Ekipten çıkan ya da çıkarılan kişinin o ekipteki paylaşımları da kalkar
create or replace function public.uye_cikar(p_team uuid, p_uye uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.teams where id = p_team and leader = auth.uid()) then
    raise exception 'baskan_degil' using errcode = '42501';
  end if;
  if p_uye = auth.uid() then raise exception 'baskan_cikamaz'; end if;
  delete from public.team_members where team_id = p_team and user_id = p_uye;
  delete from public.tasks where team_id = p_team and user_id = p_uye;
  delete from public.task_shares where team_id = p_team and shared_by = p_uye;
end $$;

create or replace function public.ekipten_ayril(p_team uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.teams where id = p_team and leader = auth.uid()) then
    raise exception 'baskan_ayrilamaz';
  end if;
  delete from public.team_members where team_id = p_team and user_id = auth.uid();
  delete from public.tasks where team_id = p_team and user_id = auth.uid();
  delete from public.task_shares where team_id = p_team and shared_by = auth.uid();
end $$;

revoke all on function public.paylas(uuid, uuid), public.paylasimi_kaldir(uuid, uuid), public.paylasimlarim(),
  public.ekip_planlari() from public;
grant execute on function public.paylas(uuid, uuid), public.paylasimi_kaldir(uuid, uuid), public.paylasimlarim(),
  public.ekip_planlari() to authenticated;
