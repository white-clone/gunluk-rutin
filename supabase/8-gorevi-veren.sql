-- Günlük Rutin: ekip görevlerinde görevi kimin verdiği
-- 7-ekiple-paylas.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.

-- Bana verilmiş ekip görevleri: görevi veren kişinin adı ve ekip adı
create or replace function public.gorev_verenler()
returns table (task_id uuid, veren text, ekip text)
language sql stable security definer set search_path = '' as $$
  select k.id, p.full_name, t.name
  from public.tasks k
  left join public.profiles p on p.id = k.assigned_by
  left join public.teams t on t.id = k.team_id
  where k.user_id = auth.uid() and k.assigned_by is not null;
$$;
revoke all on function public.gorev_verenler() from public;
grant execute on function public.gorev_verenler() to authenticated;
