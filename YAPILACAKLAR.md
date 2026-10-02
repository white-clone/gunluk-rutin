# Yapılacaklar

## A. Seri kuralları ve hesap (şimdi)
- [x] Görev başına haftanın günleri; seri yalnızca o günün işlerine bakar, işi olmayan gün nötr sayılır.
- [x] Dünü sonradan düzeltme (yalnızca dün).
- [x] İzin günü: ayda 2 hak, seri bozulmaz ama artmaz (bugün ya da dün için).
- [x] Ad soyadla girişe deneme sınırı (10 dakikada 5 yanlış deneme).
- [x] Hesap ayarları: ad soyad, şifre değiştirme, ilerleme paylaşımı, hesabı silme.
- [x] Son 7 gün özeti (tamamlanan gün, en çok kaçırılan iş).
- [x] Yönetici paneline özet sayılar (kullanıcı, bugün iş yapan, arkadaşlık, lakap).

## B. Arkadaşlar
- [x] Arkadaş kodu ile ekleme ve onay, lakap takma (supabase/2-arkadaslar.sql).
- [x] Arkadaşın serisini ve bugünkü ilerlemesini görme (paylaşım kişinin kendi seçimi).

## C. Telefon ve bildirimler
- [x] Telefona yüklenebilir uygulama (PWA: manifest, ikon, service worker).
- [x] Bildirim izni ve abonelik (Web Push, VAPID anahtarları).
- [x] Dürtme: arkadaşın bitmemiş işi için bildirim gönderme (Edge Function), saatte 1 sınırı, sessiz saatler.
- [x] Sabah / akşam hatırlatması (pg_cron + Edge Function); akşamki yalnızca iş kaldıysa.
- [x] Haftalık özet bildirimi (Pazar akşamı).

## E. Saat ve ekipler (supabase/5-saat-ve-ekip.sql)
- [x] Göreve saat; bugünün sırası saate göre, saat geçince kırmızı.
- [x] Sabah/akşam hatırlatma saatini kişi seçer; görev saatinde hatırlatma (pg_cron 5 dakikada bir).
- [x] Şifre değişiminde mevcut şifre doğrulaması.
- [x] Günlük iş eklerken gün ve saat seçimi.
- [x] Ekip kurma, kodla katılma, başkanın üyelere görev vermesi, ekip durumu.
- [x] Takvim (ay ve hafta görünümü, gün ayrıntısı, güne iş ekleme), saat aralığı (başlangıç–bitiş), listelerde Düzenle ile silme.
- [x] 5-saat-ve-ekip.sql çalıştırıldı, iki Edge Function güncellendi, yayına alındı.

## D. E-posta (kullanıcı bekletti)
- [ ] E-posta gönderici (SMTP) kur: Gmail uygulama şifresi ya da Brevo.
      Authentication → Emails → SMTP Settings. Kurulmadan doğrulama ve şifre sıfırlama
      mailleri yalnızca proje ekibindeki adreslere gider.
- [ ] SMTP kurulunca e-posta şablonlarını Türkçeleştir (Kayıt doğrulama, Şifre sıfırlama).
- [ ] SMTP kurulunca "Confirm email" (e-posta doğrulama) ayarını tekrar aç.
      Authentication → Sign In / Providers → Confirm email. Şu an kapalı.

## Proje bilgileri
- Supabase projesi: gunluk-rutin (Frankfurt) — https://foxacfsypoceaiqlrcwv.supabase.co
- Site: https://white-clone.github.io/gunluk-rutin/
- Veritabanı: supabase/kurulum.sql → 2-arkadaslar.sql → 3-seri-ve-hesap.sql (sırayla çalıştırılır)
