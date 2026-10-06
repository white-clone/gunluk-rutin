# DEVLOG

## Mevcut durum
- Uygulama tek dosya: `index.html` (~2.400 satır). Supabase arka uç, GitHub Pages'te yayında.

## 2026-10-06 — Telefon uygulaması hissi (öneri 1, 2, 3, 5)
Yapılan değişiklikler:
- Sekmeler önce alta taşındı; kullanıcı beğenmedi, eski haliyle üste geri alındı (aşağıya bak).
- Başlık sadeleşti: tarih, seri, hesap. Tema seçimi hesap penceresine taşındı (Sistem / Açık / Koyu).
- Sağ altta sabit + düğmesi; tek "Yeni iş" penceresi: ad, tekrarlı/tek seferlik, günler, tarih, saat aralığı, süre, not, paylaş.
  - Günlük ve Arkadaşlar'da tekrarlı, Takvim'de tek seferlik + seçili gün ile açılır.
  - Günlük, Liste ve takvim günündeki eski ekleme formları kaldırıldı (takvim gününde "+ Bu güne iş ekle" düğmesi var).
- Bütün pencereler alttan kayarak açılır; aşağı çekince ve telefonun geri tuşuyla kapanır.
- Dokunma alanları en az 44 px (paylaş, sil, geri, simge düğmeleri); gün düğmeleri 40 px.
- Satırdaki "ekip · paylaşıldı · not" yazıları simgeye dönüştü.
- Hesap penceresindeki yuvarlak avatarın kare görünmesi düzeltildi.
- Service worker önbellek sürümü v2.

## 2026-10-06 — Ekipten arkadaş ekleme
- Ekip penceresinde bir üyeye dokununca: arkadaş değilse onay sorulur ve istek gider (kod gerekmez);
  arkadaşsa arkadaş penceresi açılır; o istek gönderdiyse kabul etme sorulur; istek bekliyorsa bilgi verilir.
- Üye satırında durum yazar: arkadaşın / istek gönderildi / + Arkadaş ekle / sen.
- Yeni veritabanı fonksiyonu: `supabase/11-ekipten-arkadas.sql` (`ekipten_arkadas_ekle`). Supabase'de çalıştırılmadan istek gönderme hata verir.
- Onay penceresi silme dışı işler için de kullanılabiliyor (renkli düğme).

## 2026-10-06 — Haftalık saat çizelgesi (öneri 4), sekmeler üste geri alındı
- Hafta görünümü: 7 gün sütun, saatler satır. Saatli işler aralığı kaplayan blok (bitişsiz işte süre ya da 1 saat).
  Saatsiz işler üstte "tüm gün" satırında. Çakışan bloklar yan yana. Bugün sütununda kırmızı "şimdi" çizgisi.
- Saat aralığı işlere göre genişler (en az 07–22). Açılışta şimdiki saate kaydırılır, yeniden çizimde yer korunur.
- Bloğa dokununca düzenleme penceresi; boş saate dokununca o gün + saatle "Yeni iş" penceresi (geçmiş günde yalnızca gün seçilir).
- Sekmeler eski haliyle üstte (hap şeklinde). Tema seçimi hesap penceresinde kaldı; + düğmesi sağ altta.

## 2026-10-06 — Tasarım konuşması ve kararlar
- Hedef kitle: herkes (genel alışkanlık takibi). Ana ekranda önce günün listesi görünmeli.
- Sosyal taraf: ekip içi planlama ve görev paylaşımı kolaylaşmalı.
- His: "arada" — sade zemin, bitirince ve seri anlarında güçlü geri bildirim.
- Hatırlatma süresi: herkese gider (sahibi, görev alan, görevi veren, paylaşılanlar); hazır seçenekler; herkes kendi süresini seçer.

## 2026-10-06 — Görev başına hatırlatma süresi
- Yeni iş ve düzenleme penceresinde "Hatırlat": Yok, Tam saatinde, 5/10/15/30 dk, 1 saat, 1 gün önce (yalnızca saati olan işte).
- Görev verirken (ekip penceresi ve "Görev olarak ver") süre seçilir; üyeye varsayılan olur, üye değiştirebilir.
  Başkana da bu sürede "Üye adı · 15 dk sonra başlıyor" bildirimi gider (üye bitirmediyse).
- Paylaşılan planlarda takvimin gün ayrıntısında herkes kendi süresini seçer; seçmezse paylaşanın süresi geçerli.
  Plan "Listeme ekle" ile kopyalanınca planın hatırlatması kapanır, kopya aynı süreyi alır (çift bildirim olmaz).
- Satırda zil simgesi: 0'dan büyük süre seçili işlerde.
- Veritabanı: `supabase/12-hatirlatma-suresi.sql` (remind_before, giver_remind, plan_reminders, plan_hatirlat,
  plan_hatirlatmalarim, gorev_ver'e p_hatirlat, hatirlatma_listesi yenilendi). Edge Function değişmedi.
- Mevcut işler varsayılan "Tam saatinde" (eski davranış korunur).
- SQL çalıştırılmadan uygulama eskisi gibi çalışır; Hatırlat seçimi görünmez.
- Yerel Postgres 16'da bütün SQL dosyaları sırayla çalıştırıldı, hatırlatma listesi örnek verilerle doğrulandı.

## 2026-10-06 — Ekip ortak işleri, yetkili üyeler, teşvik edici içerik
- Ortak işler (ekip penceresi): her üye ekler, düzenler, bitirir. "X ekledi" / "Y bitirdi" görünür.
  Tarih, saat aralığı, hatırlatma (bütün üyelere), not. Silme: ekleyen, başkan ya da yetkili.
  Tarihli ortak işler bütün üyelerin takviminde görünür ve oradan da bitirilebilir.
- Yetkili üye: başkan "Yetki ver / Yetkiyi al" ile atar. Yetkili, üyelere bireysel görev verir, görev kaldırır.
  Üye çıkarma, ekip silme ve yetki verme yalnızca başkanda.
- Ekip özeti: bugünkü ekip görevleri çubuğu, açık ortak iş sayısı, "Bu haftanın yıldızı" (en çok ortak iş bitiren).
- Teşvik: Bitti'de titreşim ve işaret animasyonu; gün bitince kutlama ekranı (konfeti);
  3, 7, 14, 21, 30, 50, 100, 200, 365 günlük seride özel mesaj; ilerleme çubuğunda duruma göre cesaret cümlesi;
  Günlük ekranında "Günün sözü" (31 söz, her gün biri).
- Veritabanı: `supabase/13-ekip-ortak-isler.sql` (team_members.yetkili, team_tasks, yetki_ver, ekip_uyeleri,
  ekip_yetkilerim, ortak_isler, ortak_is_kaydet/bitir/sil, gorev_ver ve ekip_gorev_sil yetkiliye açıldı,
  hatirlatma_listesi'ne ortak işler eklendi). Yerel Postgres'te izin kuralları ve hatırlatmalar denendi.
- SQL çalıştırılmadan ortak işler bölümü ve yetki düğmeleri görünmez, gerisi çalışır.

## Sıradaki adımlar
- 11, 12 ve 13 numaralı SQL dosyaları Supabase'de sırayla çalıştırılacak.
- Ana ekran sadeleştirme: liste önde, Şimdi kartı kalkar, seri ayrı sayfa, renk anlamları.
- Ekip müsaitlik görünümü (haftalık çizelgede üyelerin dolu saatleri).
- Kutlama ve titreşim.
- 6: Kaydırma hareketleri (sağa: bitti, sola: paylaş/sil).
- 7: Bitti animasyonu, titreşim, 7/30/100 gün kutlaması.
- 8: "Şimdi" kartını küçültme, seri bölümünü ayrı sayfaya taşıma.
- 9: İlk açılış rehberi.
- 10: index.html'i dosyalara bölme.

## Bilinen hatalar / notlar
- + düğmesi bazı durumlarda kartın sağ alt düğmesinin ("Atla") üstüne gelebiliyor; kaydırınca açılıyor.
- Simgelerin açıklaması dokunmatikte görünmez; tam bilgi işe dokununca açılan pencerede.
