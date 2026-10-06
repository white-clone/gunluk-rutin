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

## Sıradaki adımlar
- 11-ekipten-arkadas.sql Supabase SQL Editor'de çalıştırılacak.
- 6: Kaydırma hareketleri (sağa: bitti, sola: paylaş/sil).
- 7: Bitti animasyonu, titreşim, 7/30/100 gün kutlaması.
- 8: "Şimdi" kartını küçültme, seri bölümünü ayrı sayfaya taşıma.
- 9: İlk açılış rehberi.
- 10: index.html'i dosyalara bölme.

## Bilinen hatalar / notlar
- + düğmesi bazı durumlarda kartın sağ alt düğmesinin ("Atla") üstüne gelebiliyor; kaydırınca açılıyor.
- Simgelerin açıklaması dokunmatikte görünmez; tam bilgi işe dokununca açılan pencerede.
