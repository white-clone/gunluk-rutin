-- Günlük Rutin: ekipteki birine dokunarak arkadaşlık isteği gönderme
-- 10-arkadasla-paylas.sql'den sonra bir kez çalıştırılır. Tekrar çalıştırmak güvenlidir.

-- Aynı ekipteki üyeye kod gerekmeden istek gönderir.
-- Dönen değerler arkadas_ekle ile aynı: gonderildi, kabul, bekliyor, zaten, kendin
create or replace function public.ekipten_arkadas_ekle(p_team uuid, p_uye uuid)
returns text language plpgsql security definer set search_path = '' as $$
declare
  me uuid := auth.uid();
  f public.friendships;
begin
  if me is null then raise exception 'giriş gerekli' using errcode = '42501'; end if;
  if not public.ekip_uyesi_mi(p_team) then raise exception 'ekip_uyesi_degil' using errcode = '42501'; end if;
  if not exists (select 1 from public.team_members where team_id = p_team and user_id = p_uye) then
    raise exception 'uye_degil';
  end if;
  if p_uye = me then return 'kendin'; end if;
  select * into f from public.friendships
    where (requester = me and addressee = p_uye) or (requester = p_uye and addressee = me);
  if found then
    if f.status = 'accepted' then return 'zaten'; end if;
    if f.requester = p_uye then
      update public.friendships set status = 'accepted', accepted_at = now() where id = f.id;
      return 'kabul';
    end if;
    return 'bekliyor';
  end if;
  insert into public.friendships (requester, addressee) values (me, p_uye);
  return 'gonderildi';
end $$;

revoke all on function public.ekipten_arkadas_ekle(uuid, uuid) from public;
grant execute on function public.ekipten_arkadas_ekle(uuid, uuid) to authenticated;
