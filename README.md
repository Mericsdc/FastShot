# FastShot

macOS için menü çubuğunda çalışan hızlı ekran görüntüsü ve ekran kaydı aracı. Alan seç, üzerine çiz, kopyala veya kaydet; ya da seçtiğin alanı videoya kaydet. Tüm çizimler katman olarak saklanır, istediğin zaman yeniden açıp düzenleyebilirsin.

## Kısayollar

| Kısayol | İşlev |
| --- | --- |
| **⇧⌘2** (harici PC klavyesinde **Print Screen**) | Ekran görüntüsü: alan seç, çiz, kopyala/kaydet |
| **⇧⌘7** (harici PC klavyesinde **⇧ Print Screen**) | Alanı videoya kaydet; kayıt sırasında tekrar basınca kayıt biter |

Kısayolları değiştirmek için FastShot'ı Uygulamalar'dan (veya Spotlight'tan) yeniden açın; Ayarlar › Kısayollar açılır. Menü çubuğundaki kamera simgesinden de ulaşabilirsiniz.

**Mac'in kendi ekran görüntüsü tuşlarını kullanmak:** Ayarlar › Kısayollar › "Mac'in ekran görüntüsü tuşları" bölümündeki **FastShot'a ver** düğmesi; macOS'ta "Seçili alanın resmi" (panoya/dosyaya) ve "Ekran görüntüsü ve kayıt seçenekleri" kısayollarını kapatır ve aynı tuşları FastShot'a atar (ör. ⇧⌘4 → FastShot ekran görüntüsü, ⇧⌘5 → FastShot video). Tam ekran kısayolları macOS'ta kalır. **macOS'a geri ver** eski ayarı aynen geri yükler.

### Dosya çarkı: dönüştür, araçlar, işlemler

Finder'da veya masaüstünde dosyaları sürüklerken bir tuşa bir kez basın; imlecin etrafında o çark açılır, seçeneğin üzerine bırakın. Çark açıkken başka bir tuşa basarak (ya da üstteki çubuğun üzerinde bekleyerek) çarklar arasında geçebilirsiniz.

| Tuş | Çark | Seçenekler |
| --- | --- | --- |
| **⇧** | Dönüştür | Aşağıdaki biçimler |
| **⌘** | Araçlar | Görüntü: Düzenle (FastShot düzenleyicisinde çiz, yaz, bulanıklaştır) · Kırp (oran seçenekleriyle) · Arka plan (paylaşıma hazır çerçeve) · Sıkıştır · Meta veri sil (konum vb.) · Metni kopyala (OCR) — Video: Düzenle · Sıkıştır · Sesi kaldır · Meta veri sil — Ses/PDF: Sıkıştır · Meta veri sil · PDF birleştir |
| **⌃** | İşlemler | ZIP'le / ZIP'i aç · AirDrop · Panoya kopyala · Yolu kopyala · Ekrana sabitle · Terminal'de aç (her dosya ve klasör için) |

Sürüklemeden kullanmak için:

- **Seç + kısayol:** Finder'da dosyaları seçin, **⌃⇧D**'ye basın; çark tıklanabilir açılır (⇧ ⌘ ⌃ ile veya üstteki çubuktan çark değiştirilir). İlk kullanımda macOS, FastShot'ın Finder seçimini okumasına izin ister.
- **Sağ tık:** dosyalara sağ tık (touchpad'de **iki parmakla tıklama** veya **Control + tıklama**) › Hizmetler › **FastShot çarkı**.
- **Menü çubuğu:** FastShot › **Dosyaları dönüştür…**
- Touchpad'de rahat sürüklemek için: Sistem Ayarları › Erişilebilirlik › İşaretleyici Denetimi › İzleme Dörtgeni Seçenekleri › "Üç parmakla sürükle".

Orijinal dosyalar hiç değiştirilmez; sonuçlar `ad (küçük).jpg`, `ad (kırpılmış).png` gibi yeni dosyalar olarak kaynağın yanına (veya Ayarlar'da seçtiğiniz klasöre) kaydedilir.

**Dönüştürme biçimleri**

| Kaynak | Hedef biçimler |
| --- | --- |
| Görüntü (PNG, JPEG, HEIC, WebP, TIFF, AVIF, GIF, BMP, PSD…) | PNG, JPEG, HEIC, WebP, PDF (birden çok görüntü tek PDF olur), TIFF, AVIF, GIF, BMP |
| Video (MOV, MP4, M4V…) | MP4, MOV, HEVC, GIF, M4A / WAV / MP3 (ses çıkarma) |
| Ses (MP3, M4A, WAV, AIFF, FLAC, CAF…) | M4A, MP3, WAV, AIFF, FLAC, CAF |
| PDF | Sayfa görüntüleri (PNG, JPEG, HEIC, TIFF), TXT, RTF, DOCX |
| Belge (DOCX, DOC, ODT, RTF, TXT, HTML, Markdown) | PDF, DOCX, RTF, TXT, HTML, ODT, DOC |

Her şey macOS'un kendi motorlarıyla yapılır. WebP ve MP3 çıktısı için `brew install webp lame` (veya `ffmpeg`) gerekir; kuruluysa çarka otomatik eklenir. Çark tuşları ve çıktı klasörü Ayarlar › Dosya çarkı'ndan değiştirilir.

### Seçim ekranında

- Sürükle: alan seç · Tıkla: imlecin altındaki pencere · ↩: tam ekran · Esc: çık
- Seçimin kenar/köşe tutamaçlarıyla boyutlandır, içinden sürükleyerek taşı, ok tuşlarıyla 1 px (⇧ ile 10 px) kaydır
- **⌘C / ↩** kopyala · **⌘S** kaydet · **⇧⌘S** farklı kaydet · **⌘P** ekrana sabitle · **⌘T** metni tanı (OCR) · **⌘E** düzenleyicide aç · **⌘R** bu alanı videoya kaydet

### Çizim araçları

V seç/taşı · P kalem · L çizgi · A ok · R dikdörtgen · O elips · M işaretleyici · T metin · B bulanıklaştır (piksel) · N numara

- Her çizim sonradan seçilebilir, taşınabilir, boyutlandırılabilir, rengi/kalınlığı değiştirilebilir; ⌫ siler, ⌘Z / ⇧⌘Z geri al / yinele
- ⇧ ile çizgi ve ok 45°'ye, dikdörtgen ve elips kare/daireye kilitlenir
- Metne çift tıklayarak yeniden düzenle; "Dolgulu" seçeneği metni etiket kutusuna çevirir

### Video

- Kayıt sırasında kontrol çubuğundaki kalemle ekrana canlı çizebilirsin. Bu çizimler videoya gömülmez; çizildikleri anın zaman bilgisiyle düzenlenebilir katman olarak saklanır.
- Video düzenleyicide oynatma çubuğunu istediğin ana getirip çiz; zaman çizelgesindeki çubukların uçlarını sürükleyerek çizimin ne zaman görünüp kaybolacağını ayarla.
- Boşluk oynat/duraklat · I / O kırpma başlangıç/bitiş · [ / ] seçili çizimi oynatma çubuğunda başlat/bitir · ←/→ kare kare (⇧ ile 1 sn)
- Dışa aktarma: MP4, MOV veya GIF; çizimler ve kırpma dışa aktarılan dosyaya işlenir. Orijinal kayıt hiç değişmez.

### Geçmiş ve düzenlenebilir projeler

Kopyaladığın, kaydettiğin veya kaydettiğin her yakalama `~/Library/Application Support/FastShot/Library` altında orijinal medya + çizimler olarak saklanır. Menü › Geçmiş… ile açıp düzenlemeye devam edebilirsin. Düzenleyicideki ⋯ menüsünden `.fastshot` paketi olarak dışa aktarılan projeler başka bir Mac'te de düzenlenebilir.

## Derleme

Gereksinimler: macOS 15+, Xcode 16+ (Swift 6).

```bash
scripts/build-app.sh release --install
```

Uygulama `build/FastShot.app` olarak derlenir; `--install` ile `/Applications` klasörüne kopyalanıp başlatılır. Anahtar zincirinde bir Apple Development / Developer ID sertifikası varsa onunla imzalanır; böylece Ekran Kaydı izni her derlemede yeniden istenmez.

İlk açılışta macOS **Ekran ve Sistem Sesi Kaydı** izni ister (Sistem Ayarları › Gizlilik ve Güvenlik). Mikrofon kaydı için ayrıca mikrofon izni istenir.

Testler:

```bash
swift test
```

## Yapı

- `Sources/FastShotCore`: çizim modeli, Core Graphics çizim motoru, görüntü/video dışa aktarma, proje kütüphanesi (arayüzden bağımsız, test edilebilir)
- `Sources/FastShot/Capture`: dondurulmuş ekran, alan seçimi, büyüteç, araç çubukları
- `Sources/FastShot/Canvas`: tüm yüzeylerin paylaştığı düzenlenebilir tuval ve araç durumu
- `Sources/FastShot/Recording`: ScreenCaptureKit bölge kaydı, canlı çizim katmanı
- `Sources/FastShot/Editor`: görüntü ve video düzenleyicileri, zaman çizelgesi
- `Sources/FastShot/App`: menü çubuğu, global kısayollar, ayarlar, izinler
