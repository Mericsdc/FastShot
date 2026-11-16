Windows 1.3.2 — Kısayollar korunur, tek tuş, kendiliğinden güncelleme

- Kısayollar ve diğer ayarlar Windows yeniden başlayınca artık sıfırlanmaz. Ayar dosyası açılışta okunamadığında (başka bir program dosyayı bir anlığına tutuyorsa, dosya yarım kaldıysa ya da tek bir değer okunamıyorsa) FastShot varsayılanlarla açılıp bunları dosyanın üstüne yazıyordu. Artık kilitli dosya yeniden denenir, bozuk bir değer yalnızca kendisini sıfırlar, okunamayan dosya üstüne yazılmadan önce settings.unreadable.json olarak saklanır ve dosya hiçbir zaman yarım yazılmaz.
- Kısayol olarak tek bir tuş atanabilir (ör. P, 5, Boşluk) ya da yalnız Shift ile. Ctrl, Alt veya Win'siz bir yazı tuşu FastShot çalışırken hiçbir yerde yazmaz; Ayarlar bunu belirtir.
- FastShot kendini günceller: Windows açılınca (sonra 6 saatte bir) yeni sürümü denetler, varsa indirip sormadan kurar ve yeniden açılır. Kayıt, düzenleme veya dönüştürme sürüyorsa bitmesini bekler; bildirimdeki ya da menüdeki Güncelle beklemeden kurar. "Güncellemeleri otomatik denetle" seçeneği kaldırıldı; herkes aynı, en yeni sürümü kullanır.
- Releases sayfasında yalnızca en yeni Windows sürümü kalır.

Doğrulama: 107 Windows regresyon testi (17'si yeni ayar ve kısayol testi) geçti; yayın akışı kurulum dosyasını derleyip başlatma/kapatma testini çalıştırır.

Güncelleme: 1.3.1 ve öncesinde FastShot'ın gösterdiği bildirimden veya menüdeki Güncelle'den bir kez güncelleyin; 1.3.2'den sonra güncellemeler kendiliğinden kurulur. Yeni kurulum için FastShot-Setup-x64.exe dosyasını indirip açın.
