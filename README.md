# FastShot

macOS için menü çubuğunda çalışan hızlı ekran görüntüsü ve ekran kaydı aracı. Alan seç, üzerine çiz, kopyala veya kaydet; ya da seçtiğin alanı videoya kaydet. Tüm çizimler katman olarak saklanır, istediğin zaman yeniden açıp düzenleyebilirsin.

**Windows:** Windows 10/11 sürümü [windows/](windows) klasöründe. Kurulum: [Releases](https://github.com/Mericsdc/FastShot/releases) › en yeni **FastShot for Windows** › `FastShot-Setup-x64.exe`.

## Kurulum ve güncellemeler

[Releases](https://github.com/Mericsdc/FastShot/releases) › en yeni **FastShot for macOS** › `FastShot-macOS.zip` dosyasını indirip açın ve `FastShot.app`'i **Uygulamalar** klasörüne taşıyın. Apple tarafından notarize edilmediği için ilk açılışta macOS uyarabilir: uygulamaya sağ tık › **Aç** (ya da Sistem Ayarları › Gizlilik ve Güvenlik › **Yine de Aç**).

- Uygulamalar klasöründeki FastShot yeni sürümleri kendisi denetler (açılıştan kısa süre sonra, sonra 6 saatte bir). Yeni sürüm çıkınca bir bildirim ve menünün en üstünde **Güncelle** görünür; tek tıkla indirip kurar ve yeniden açılır. Ayarlar › Genel › Güncellemeler'den elle denetlenir ya da otomatik denetleme kapatılır.
- Menü çubuğu simgesi Ayarlar › Genel'den gizlenebilir; FastShot çalışmaya devam eder, ayarlara dönmek için Uygulamalar'dan yeniden açın. Aynı yerde **FastShot'tan çık** düğmesi de var.
- Beklenmeyen hatalar `~/Library/Logs/FastShot/errors.log` dosyasına yazılır.

## Kısayollar

| Kısayol | İşlev |
| --- | --- |
| **⇧⌘2** (harici PC klavyesinde **Print Screen**) | Ekran görüntüsü: alan seç, çiz, kopyala/kaydet |
| **⇧⌘7** (harici PC klavyesinde **⇧ Print Screen**) | Alanı videoya kaydet; kayıt sırasında tekrar basınca kayıt biter |

Kısayolları değiştirmek için FastShot'ı Uygulamalar'dan (veya Spotlight'tan) yeniden açın; Ayarlar › Kısayollar açılır. Menü çubuğundaki kamera simgesinden de ulaşabilirsiniz.

**Mac'in kendi ekran görüntüsü tuşlarını kullanmak:** Ayarlar › Kısayollar › "Mac'in ekran görüntüsü tuşları" bölümündeki **FastShot'a ver** düğmesi; macOS'ta "Seçili alanın resmi" (panoya/dosyaya) ve "Ekran görüntüsü ve kayıt seçenekleri" kısayollarını kapatır ve aynı tuşları FastShot'a atar (ör. ⇧⌘4 → FastShot ekran görüntüsü, ⇧⌘5 → FastShot video). Tam ekran kısayolları macOS'ta kalır. **macOS'a geri ver** eski ayarı aynen geri yükler.

### Metni çevir

Seçim ekranında **Metni tanı ve çevir** (⇧⌘T), dosya çarkında Araçlar › **Çevir** ya da menü çubuğunda **Çeviri…**. Seçilen alandaki metin tanınır, ekrandaki satırlar paragraflara birleştirilir (bölünmüş kelimeler de) ve imlecin yanında açılan bir çeviri kartında gösterilir: üstte dil seçicileri ve kullanılan motor, ortada çeviri, altında düzenlenebilir orijinal metin (düzenledikçe çeviri yenilenir), altta Kopyala ve Orijinali kopyala. Kart her yerinden sürüklenir, Esc ile kapanır. Metin zaten hedef dildeyse hedef kendiliğinden değişir (Türkçe → İngilizce, diğerleri → Türkçe). "Metni kopyala" da artık satırları paragraf olarak birleştirir.

- **Çevrimdışı (varsayılan):** Apple'ın çeviri motoru bu Mac'te çalışır; anahtar, hesap ve internet (dil bir kez indirildikten sonra) gerekmez, metin Mac'ten çıkmaz. Bir dil ilk kez gerektiğinde macOS onu indirmeyi önerir; indirilenler Sistem Ayarları › Genel › Dil ve Bölge › Çeviri Dilleri'nden yönetilir.
- **DeepL (isteğe bağlı):** Ayarlar › Çeviri'ye kendi DeepL API anahtarınızı girin (ücretsiz plan: ayda 500.000 karakter). Anahtar denenip kaydedilir ve yalnızca bu Mac'te, Anahtar Zinciri'nde saklanır.

### Dosya çarkı: dönüştür, araçlar, işlemler

Finder'da veya masaüstünde dosyaları sürüklerken bir tuşa bir kez basın; imlecin etrafında o çark açılır, seçeneğin üzerine bırakın. Aynı tuşa tekrar bastıkça sıradaki çarka geçilir; başka bir çarkın tuşu o çarkı açar, üstteki çubuğun üzerinde bir an beklemek de. Bir çarkta o dosyalar için seçenek yoksa sıradaki açılır. İsterseniz Ayarlar › Dosya çarkı › Tuşlar'dan **tek tuş** moduna geçin: varsayılan **sağ ⌥** (Mac'teki AltGr) çarkı açar ve bastıkça çarklar arasında dolaşır; yalnızca dosya sürüklerken etkilidir, yazı yazmayı etkilemez.

| Tuş | Çark | Seçenekler |
| --- | --- | --- |
| **⇧** | Dönüştür | Aşağıdaki biçimler |
| **⌘** | Araçlar | Görüntü: Düzenle (FastShot düzenleyicisinde çiz, yaz, bulanıklaştır) · Kırp (oran seçenekleriyle) · Arka plan (paylaşıma hazır çerçeve) · Sıkıştır · Meta veri sil (konum vb.) · Metni kopyala (OCR) · Çevir — Video: Düzenle · Sıkıştır · Sesi kaldır · Meta veri sil — Ses/PDF: Sıkıştır · Meta veri sil · PDF birleştir |
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
- **⌘C / ↩** kopyala · **⌘S** kaydet · **⇧⌘S** farklı kaydet · **⌘P** ekrana sabitle · **⌘T** metni tanı (OCR) · **⇧⌘T** metni tanı ve çevir · **⌘E** düzenleyicide aç · **⌘R** bu alanı videoya kaydet

### Çizim araçları

V seç/taşı · P kalem · L çizgi · A ok · R dikdörtgen · O elips · M işaretleyici · T metin · B bulanıklaştır (piksel) · N numara

- Her çizim sonradan seçilebilir, taşınabilir, boyutlandırılabilir, rengi/kalınlığı değiştirilebilir; ⌫ siler, ⌘Z / ⇧⌘Z geri al / yinele
- ⇧ ile çizgi ve ok 45°'ye, dikdörtgen ve elips kare/daireye kilitlenir
- Metne çift tıklayarak yeniden düzenle; "Dolgulu" seçeneği metni etiket kutusuna çevirir
- Beş kalınlık: 1, 2, 3, 5 ve 8 pt (varsayılan İnce, 2 pt); yazı boyutu 12–40 pt

### Video

- Kayıt sırasında kontrol çubuğundaki kalemle ekrana canlı çizebilirsin. Bu çizimler videoya gömülmez; çizildikleri anın zaman bilgisiyle düzenlenebilir katman olarak saklanır.
- Sistem sesi ve mikrofon ayrı ayrı açılıp kapatılır; ikisi aynı anda açıksa (macOS 27 ve sonrasında) tek ses izinde karışır.
- Video düzenleyicide oynatma çubuğunu istediğin ana getirip çiz; zaman çizelgesindeki çubukların uçlarını sürükleyerek çizimin ne zaman görünüp kaybolacağını ayarla.
- Boşluk oynat/duraklat · I / O kırpma başlangıç/bitiş · [ / ] seçili çizimi oynatma çubuğunda başlat/bitir · ←/→ kare kare (⇧ ile 1 sn)
- Dışa aktarma: MP4, MOV veya GIF; çizimler ve kırpma dışa aktarılan dosyaya işlenir. Orijinal kayıt hiç değişmez.

### Geçmiş ve düzenlenebilir projeler

Kopyaladığın, kaydettiğin veya kaydettiğin her yakalama `~/Library/Application Support/FastShot/Library` altında orijinal medya + çizimler olarak saklanır. Menü › Geçmiş… ile açıp düzenlemeye devam edebilirsin. Düzenleyicideki ⋯ menüsünden `.fastshot` paketi olarak dışa aktarılan projeler başka bir Mac'te ya da FastShot for Windows'ta da düzenlenebilir; Windows'tan gelen bir `.fastshot` klasörünü menü › **FastShot projesi aç…** ile açabilirsin.

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

## Sürüm çıkarmak

```bash
scripts/release-macos.sh 1.2.1 "Bu sürümde neler değişti"
```

Testleri çalıştırır, uygulamayı o sürüm numarasıyla derleyip imzalar, `FastShot-macOS.zip` olarak `macos-v1.2.1` GitHub sürümüne ekler (sürüm varsa zip'i değiştirir). Kurulu FastShot'lar güncellemeyi buradan alır. Her sürüm aynı sertifikayla imzalandığında Ekran Kaydı izni güncellemelerde korunur.

## Yapı

- `Sources/FastShotCore`: çizim modeli, Core Graphics çizim motoru, görüntü/video dışa aktarma, proje kütüphanesi (arayüzden bağımsız, test edilebilir)
- `Sources/FastShot/Capture`: dondurulmuş ekran, alan seçimi, büyüteç, araç çubukları
- `Sources/FastShot/Canvas`: tüm yüzeylerin paylaştığı düzenlenebilir tuval ve araç durumu
- `Sources/FastShot/Recording`: ScreenCaptureKit bölge kaydı, canlı çizim katmanı
- `Sources/FastShot/Editor`: görüntü ve video düzenleyicileri, zaman çizelgesi
- `Sources/FastShot/Convert`: dosya çarkı (dönüştür, araçlar, işlemler), kırpma penceresi, iş kuyruğu, sürükleme izleyicisi
- `Sources/FastShot/Translate`: çeviri kartı, Apple'ın cihaz üzerindeki çeviri motoru ve DeepL
- `Sources/FastShot/App`: menü çubuğu, global kısayollar, ayarlar, izinler, güncellemeler
