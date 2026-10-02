-- Günlük Rutin: görev notları
-- 8-gorevi-veren.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.
-- note: işin sahibinin kendi notu. assign_note: ekip başkanının görevi verirken yazdığı not (üye değiştiremez).

alter table public.tasks add column if not exists note text;
alter table public.tasks add column if not exists assign_note text;
alter table public.tasks drop constraint if exists tasks_note_len;
alter table public.tasks add constraint tasks_note_len check (char_length(note) <= 500 and char_length(assign_note) <= 500);

grant insert (id, user_id, name, type, dur, days, pokeable, due, done, done_at, position, time, end_time, note) on public.tasks to authenticated;
grant update (id, user_id, name, type, dur, days, pokeable, due, done, done_at, position, time, end_time, note) on public.tasks to authenticated;

-- Görev verirken not da yazılabilir
drop function if exists public.gorev_ver(uuid, uuid, text, text, int, time, time, int, date);
create or replace function public.gorev_ver(p_team uuid, p_uye uuid, p_ad text, p_tur text, p_gunler int,
                                            p_saat time, p_bitis time, p_sure int, p_son date, p_not text default null)
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
  insert into public.tasks (user_id, name, type, dur, days, time, end_time, due, team_id, assigned_by, position, assign_note)
  values (p_uye, left(trim(p_ad), 80), case when p_tur = 'general' then 'general' else 'daily' end,
          case when p_tur = 'general' then 0 else greatest(0, least(600, coalesce(p_sure, 0))) end,
          case when p_gunler between 1 and 127 then p_gunler else 127 end,
          p_saat, case when p_saat is not null and p_bitis > p_saat then p_bitis end,
          case when p_tur = 'general' then p_son end,
          p_team, auth.uid(),
          coalesce((select max(position) + 1 from public.tasks where user_id = p_uye), 0),
          nullif(left(trim(coalesce(p_not, '')), 500), ''))
  returning id into gid;
  return gid;
end $$;
revoke all on function public.gorev_ver(uuid, uuid, text, text, int, time, time, int, date, text) from public;
grant execute on function public.gorev_ver(uuid, uuid, text, text, int, time, time, int, date, text) to authenticated;
