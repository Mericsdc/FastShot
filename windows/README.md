# FastShot for Windows

Windows için görev çubuğunun bildirim alanında (saatin yanında) çalışan hızlı ekran görüntüsü ve ekran kaydı aracı. Alan seç, üzerine çiz, kopyala veya kaydet; ya da seçtiğin alanı videoya kaydet. Tüm çizimler katman olarak saklanır, istediğin zaman yeniden açıp düzenleyebilirsin.

macOS sürümünün (bu deponun kökü, [Mericsdc/FastShot](https://github.com/Mericsdc/FastShot)) Windows 10/11 karşılığıdır. Çizim modeli, düzenleyiciler, zaman çizelgesi ve proje biçimi aynıdır; `.fastshot` projeleri iki sistem arasında taşınabilir.

## Kurulum

[Releases](https://github.com/Mericsdc/FastShot/releases) › en yeni **FastShot for Windows** › `FastShot-Setup-x64.exe` dosyasını indirip açın. .NET'i içinde taşır, başka bir şey gerekmez.

- `%LOCALAPPDATA%\Programs\FastShot` klasörüne (C: sürücüsü, yalnızca sizin kullanıcınız için; yönetici izni istemez) kurulur, Başlat menüsüne eklenir ve Windows açılınca başlar. İndirdiğiniz dosya sonra silinebilir.
- Yeni sürümleri kendisi denetler (açılıştan kısa süre sonra, sonra 6 saatte bir). Yeni sürüm çıkınca bir bildirim ve bildirim alanı menüsünün en üstünde **Güncelle** görünür; tek tıkla indirip kurar ve yeniden açılır. Ayarlar › Genel › Güncellemeler'den elle denetlenir ya da otomatik denetleme kapatılır.
- Kaldırmak için: Windows Ayarları › Uygulamalar › FastShot › Kaldır. Geçmiş'teki yakalamalar ve ayarlar silinmez.
- Simgeyi bildirim alanından kaldırmak için: Ayarlar › Genel › "Simgeyi bildirim alanında göster". FastShot çalışmaya devam eder; ayarlara dönmek için Başlat menüsünden yeniden açın.

İmzasız olduğu için Windows kurulum dosyasının ilk açılışında **"Windows bilgisayarınızı korudu"** diyebilir: **Ek bilgi → Yine de çalıştır** (ya da dosyaya sağ tık › Özellikler › **Engellemeyi kaldır**). Kurulu FastShot'ta bu uyarı bir daha çıkmaz.

## Kısayollar

| Kısayol | İşlev |
| --- | --- |
| **Ctrl+Shift+2** veya **Print Screen** | Ekran görüntüsü: alan seç, çiz, kopyala/kaydet |
| **Ctrl+Shift+7** veya **Shift+Print Screen** | Alanı videoya kaydet; kayıt sırasında tekrar basınca kayıt biter |

Kısayolları değiştirmek için bildirim alanındaki FastShot simgesine tıklayın › **Ayarlar…** › Kısayollar. FastShot'ı Başlat menüsünden veya exe'ye çift tıklayarak yeniden açtığınızda da ayarlar açılır.

**Print Screen tuşu:** Windows 11'de Print Screen varsayılan olarak Ekran Alıntısı Aracı'nı açar ve FastShot'a ulaşmaz. Ayarlar › Kısayollar › "Windows'un Print Screen tuşu" bölümündeki **FastShot'a ver** düğmesi bu Windows seçeneğini kapatır; **Windows'a geri ver** eski hâline döndürür. Başka bir uygulama (ör. başka bir ekran görüntüsü aracı) tuşu tutuyorsa ayarlarda turuncu bir uyarı görünür.

### Dosya çarkı: dönüştür, araçlar, işlemler

Gezgin'de veya masaüstünde dosyaları (ya da klasörleri) sürüklerken **AltGr**'ye bir kez basın; imlecin etrafında **Dönüştür** çarkı açılır. AltGr'ye tekrar bastıkça **Araçlar** ve **İşlemler** çarklarına geçilir; halkanın üstündeki çubukta bir an beklemek de o çarkı açar. Seçeneğin üzerine bırakın.

| Çark | Ne yapar |
| --- | --- |
| Dönüştür | Dosyayı başka bir biçime çevirir (tablo aşağıda) |
| Araçlar | Görüntü: Düzenle · Kırp (Serbest, Orijinal, 1:1, 4:3, 3:2, 16:9, 9:16) · Arka plan · Sıkıştır · Meta veri sil · Metni kopyala (OCR). Video: Düzenle · Sıkıştır · Sesi kaldır · Meta veri sil. Ses: Sıkıştır (MPEG-4 seste meta veri sil). PDF: Sıkıştır · Meta veri sil · Birleştir (birden çok PDF) |
| İşlemler | Her dosya ve klasör için: ZIP'le / ZIP'i aç · Paylaş (Windows'un paylaşım paneli, Yakındaki paylaşım dahil) · Panoya kopyala · Yolu kopyala · Ekrana sabitle (görüntüler) · Terminal'de aç |

Bir çarkta o dosyalar için seçenek yoksa sıradaki çark açılır. AltGr yalnızca dosya sürüklerken çark açar; yazı yazarken (ör. AltGr+Q ile @) etkilemez. Tuş Ayarlar › Dosya çarkı'ndan Shift, Ctrl veya Alt yapılabilir.

Sürüklemeden açmanın yolları:

- **Sağ tık:** dosyalara veya klasörlere sağ tıklayın › **FastShot çarkı** (Windows 11'de önce **Daha fazla seçenek göster**). Açılan çarkta seçeneğe tıklayın; AltGr orada da çark değiştirir.
- **Bildirim alanı menüsü:** FastShot › **Dosya çarkı…**

Kaynak dosyalar hiçbir zaman değişmez; sonuç her zaman yeni bir dosyadır: `foto (küçük).jpg`, `foto (temiz).jpg`, `foto (kırpılmış).png`, `foto (arka plan).png`, `klip (sessiz).mp4`, `rapor (birleşik).pdf`, tek öğe için `Rapor.zip`, birden çok öğe için `Arşiv.zip`.

PDF sıkıştırma, birleştirme ve meta veri silme sayfaları yeniden çizmez: metin, bağlantılar ve vektörler olduğu gibi kopyalanır, sıkıştırmada yalnızca büyük görüntüler JPEG olarak yeniden kodlanır. Şifreli PDF'ler işlenmez.

#### Dönüştür çarkının biçimleri

| Kaynak | Hedef biçimler |
| --- | --- |
| Görüntü (PNG, JPEG, HEIC, WebP, TIFF, AVIF, GIF, BMP, ICO…) | PNG, JPEG, HEIC, PDF (birden çok görüntü tek PDF olur), TIFF, GIF, BMP |
| Video (MP4, MOV, MKV, AVI, WMV, WebM…) | MP4, HEVC, GIF, M4A, WAV ve MP3 (ses çıkarma) |
| Ses (MP3, M4A, WAV, FLAC, WMA, AIFF, CAF…) | M4A, MP3, WAV, AIFF, FLAC, CAF |
| PDF | Sayfa görüntüleri (PNG, JPEG, HEIC, TIFF), TXT, RTF, DOCX |
| Belge (DOCX, DOC, ODT, RTF, TXT, HTML, Markdown) | PDF, DOCX, RTF, TXT, HTML, ODT, DOC |

Her şey Windows'un kendi motorlarıyla yapılır: görüntüler için WIC, video ve ses için Media Foundation, PDF sayfaları için Windows'un PDF motoru, belgeler için FastShot'ın kendi DOCX/ODT/RTF/HTML/Markdown okuyucu ve yazıcıları. MOV'u MP4'e çevirmek mümkünse yeniden kodlamadan, kayıpsız yapılır.

- **Microsoft Word** yüklüyse DOC dönüşümleri ve belgelerin en doğru PDF'i Word ile yapılır; PDF'ten DOCX/RTF/TXT de Word'ün PDF açma özelliğini kullanır. Word yoksa belge PDF'leri Microsoft Edge ile yazdırılır, PDF metni Windows'un metin tanımasıyla okunur ve DOC hedefi çarkta görünmez. Ayarlar › Dosya çarkı'ndan Word kapatılabilir.
- **HEIC ve HEVC** için Windows'un HEIF ve HEVC uzantıları gerekir; kurulu değilse bu hedefler çarkta görünmez.
- **WebP ve AVIF çıktısı** Windows'ta yerleşik değildir. `winget install ffmpeg` ile ffmpeg kurarsanız çarka otomatik eklenir.

Çarkları açan tuşlar, sağ tık menüsü ve çıktı klasörü (kaynağın yanı / İndirilenler / seçilen klasör) Ayarlar › Dosya çarkı'ndan değiştirilir. Sağ tık menüsü yalnızca sizin kullanıcı hesabınıza (HKCU) eklenir. FastShot'ı silmeden önce bu seçeneği kapatırsanız menü de kalkar.

### Seçim ekranında

- Sürükle: alan seç · Tıkla: imlecin altındaki pencere · **Enter**: tam ekran · **Esc**: çık · Sağ tık: iptal
- Seçimin kenar/köşe tutamaçlarıyla boyutlandır, içinden sürükleyerek taşı, ok tuşlarıyla 1 piksel (Shift ile 10) kaydır
- **Ctrl+C / Enter** kopyala · **Ctrl+S** kaydet · **Ctrl+Shift+S** farklı kaydet · **Ctrl+P** ekrana sabitle · **Ctrl+T** metni tanı (OCR) · **Ctrl+E** düzenleyicide aç · **Ctrl+R** bu alanı videoya kaydet
- Büyüteç imlecin altındaki pikselleri, koordinatı ve rengi gösterir (Ayarlar › Genel'den kapatılabilir)

### Çizim araçları

V seç/taşı · P kalem · L çizgi · A ok · R dikdörtgen · O elips · M işaretleyici · T metin · B bulanıklaştır (piksel) · N numara

- Her çizim sonradan seçilebilir, taşınabilir, boyutlandırılabilir, rengi/kalınlığı değiştirilebilir; **Delete** siler, **Ctrl+Z** / **Ctrl+Y** (veya Ctrl+Shift+Z) geri al / yinele
- Shift ile çizgi ve ok 45°'ye, dikdörtgen ve elips kare/daireye kilitlenir
- Metne çift tıklayarak yeniden düzenle; **Ctrl+Enter** veya Esc düzenlemeyi bitirir; "Dolgulu" seçeneği metni etiket kutusuna çevirir

### Ekrana sabitleme

Sabitlenen görüntü diğer pencerelerin üstünde kalır. Sürükleyerek taşı, fare tekerleğiyle boyutlandır, çift tıkla veya Esc ile kapat; sağ tık: Kopyala, Kaydet…, Gerçek boyut.

### Video

- Kayıt sırasında kontrol çubuğundaki kalemle ekrana canlı çizebilirsin. Bu çizimler videoya gömülmez; çizildikleri anın zaman bilgisiyle düzenlenebilir katman olarak saklanır. Kayıt çerçevesi, kontrol çubuğu ve çizim katmanı kayda girmez.
- Sistem sesi (hoparlörden çıkan ses) ve mikrofon ayrı ayrı açılıp kapatılır; ikisi aynı anda açıksa tek ses izinde karışır.
- Video düzenleyicide oynatma çubuğunu istediğin ana getirip çiz; zaman çizelgesindeki çubukların uçlarını sürükleyerek çizimin ne zaman görünüp kaybolacağını ayarla.
- **Boşluk** oynat/duraklat · **I** / **O** kırpma başlangıç/bitiş · **[** / **]** seçili çizimi oynatma çubuğunda başlat/bitir · **←/→** kare kare (Shift ile 1 sn)
- Dışa aktarma: MP4 (H.264 veya HEVC) ya da GIF; çizimler ve kırpma dışa aktarılan dosyaya işlenir, ses korunur. Orijinal kayıt hiç değişmez.

### Geçmiş ve düzenlenebilir projeler

Kopyaladığın, kaydettiğin veya kaydını aldığın her yakalama `%LOCALAPPDATA%\FastShot\Library` altında orijinal medya + çizimler olarak saklanır. Menü › **Geçmiş…** ile açıp düzenlemeye devam edebilirsin. Düzenleyicideki ⋯ menüsünden `.fastshot` klasörü olarak dışa aktarılan projeler başka bir Windows bilgisayarda veya Mac'te de düzenlenebilir; Mac'ten gelen bir `.fastshot` klasörünü menü › **FastShot projesi aç…** ile açabilirsin.

Ayarlar `%APPDATA%\FastShot\settings.json` dosyasında, beklenmeyen hatalar `%LOCALAPPDATA%\FastShot\errors.log` dosyasında tutulur.

## Derleme

Gereksinimler: Windows 10 (2004) veya 11, [.NET 10 SDK](https://dotnet.microsoft.com/download/dotnet/10.0).

```powershell
scripts\build.ps1
```

Uygulama `build\FastShot.exe` olarak tek dosya hâlinde çıkar; çalışması için hedef bilgisayarda .NET 10 Masaüstü Çalışma Zamanı gerekir. .NET kurulu olmayan bilgisayarlar için:

```powershell
scripts\build.ps1 -SelfContained
```

Geliştirirken doğrudan çalıştırmak için:

```powershell
dotnet run --project src\FastShot
```

Testler:

```powershell
dotnet test
```

Uygulama simgesi `src\FastShot\Assets\AppIcon.png` logosudur (1024 px, saydam zemin); `AppIcon.cs` her boyutu ondan çizer, kayıt sırasında tepsi simgesi kırmızı bir durdur işaretine döner. Logoyu değiştirince `scripts\make-icon.ps1` exe'ye gömülen `Assets\AppIcon.ico` dosyasını yeniden üretir.

## Sürüm çıkarmak

Yeni bir `windows-v*` etiketi GitHub Actions'ta exe'yi derleyip yayınlar (`.github/workflows/windows.yml`). Etiketin mesajı sürüm notu olur, etiketteki sürüm exe'ye yazılır:

```powershell
git tag -a windows-v1.1.0 -m "Bu sürümde neler değişti"
git push origin windows-v1.1.0
```

İş akışı exe'yi derler, `--embedded` ile bir kez açıp kapanabildiğini dener, sonra `FastShot-Setup-x64.exe`'yi sürüme ekler; kurulu FastShot'lar güncellemeyi buradan alır. Aynı etiket yeniden çalışırsa exe değiştirilir. Actions › Windows › "Run workflow" (sadece derle) yayınlamadan dener; exe işin "Artifacts" bölümünden indirilebilir. macOS uygulaması bu iş akışından etkilenmez.

Xloer'in içindeki FastShot bu klasörden kopyalanır: Xloer'de `npm run sync-fastshot`.

## Yapı

- `src/FastShot.Core`: çizim modeli, WPF çizim motoru, görüntü/video dışa aktarma, GIF ve PDF yazıcıları, dosya dönüştürme (`Convert/`), proje kütüphanesi ve Media Foundation (MP4 okuma/yazma, ses) katmanı. Pencere açmaz; testlerle sınanır.
- `src/FastShot/Capture`: dondurulmuş ekranlar, alan ve pencere seçimi, büyüteç, araç çubukları
- `src/FastShot/Canvas`: tüm yüzeylerin paylaştığı düzenlenebilir kanvas, araç durumu ve denetimler
- `src/FastShot/Recording`: bölge kaydı, WASAPI ile sistem sesi ve mikrofon, canlı çizim katmanı
- `src/FastShot/Editor`: görüntü ve video düzenleyicileri, oynatıcı, zaman çizelgesi
- `src/FastShot/Convert`: dosya çarkı (dönüştür, araçlar, işlemler), kırpma penceresi, paylaşım paneli, iş kuyruğu ve ilerleme paneli, Gezgin seçimi, sürükleme izleyicisi, sağ tık menüsü
- `src/FastShot/App`: bildirim alanı simgesi, genel kısayollar, ayarlar, Win32 çağrıları
- `tests/FastShot.Core.Tests`: geometri, proje biçimi (Mac ile uyumluluk dahil), çizim, video/ses dışa aktarma, dönüştürme ve dosya araçları (sıkıştırma, meta veri, kırpma, PDF birleştirme, ZIP) testleri. Word testleri `FASTSHOT_TEST_WORD=1` ile açılır.

## macOS sürümünden farklar

- **Sistem kısayollarını devralma** Windows'ta Print Screen / Ekran Alıntısı Aracı ayarı olarak çalışır (yukarıya bakın).
- **MOV çıktısı yoktur**, çünkü Windows'ta yerleşik QuickTime yazıcısı bulunmaz. Video dışa aktarma ve dönüştürme MP4 (H.264 veya HEVC) ve GIF'e yapılır. MOV dosyaları açılıp düzenlenebilir ve dönüştürülebilir.
- **Dönüştürme çarkı** sürüklenen dosyaları Gezgin'in seçiminden okur. Bu yüzden sürükle + tuş yolu yalnızca Gezgin'den ve masaüstünden yapılan sürüklemelerde açılır. Mac'teki "Hizmetler" menüsünün karşılığı sağ tık menüsüdür. Mac'te ⌘ / ⌃ olan Araçlar ve İşlemler tuşları burada Ctrl / Alt'tır; AirDrop'un yerini Windows'un paylaşım paneli, Terminal'in yerini Windows Terminal (yoksa PowerShell) alır.
- **PDF'ten metin** Mac'te PDF'in kendi metin katmanından alınır. Windows'ta bu Word ile, Word yoksa metin tanımayla yapılır.
- **Metin tanıma** Windows'un yerleşik OCR motorunu kullanır; tanınan diller Windows'a yüklü dil paketlerine bağlıdır.
- **Ekran kaydı izni** gerekmez. Mikrofon için Windows'un Ayarlar › Gizlilik ve güvenlik › Mikrofon izni geçerlidir.
