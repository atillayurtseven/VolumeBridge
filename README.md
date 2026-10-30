# SesKopru

Ses seviyesi kontrolü olmayan çıkış aygıtlarında (DisplayPort/HDMI monitörler) Mac'in ses tuşlarını çalıştıran menü çubuğu uygulaması. Sesi Core Audio Process Tap ile yakalar, kazanç uygulayıp aynı çıkışa geri verir. Sürücü veya DDC kullanmaz.

## Gereksinimler

- macOS 14.4 veya üstü
- Xcode Command Line Tools (`xcode-select --install`)

## Derleme ve kurulum

```bash
git clone https://github.com/atillayurtseven/SesKopru.git
```

```bash
cd SesKopru && ./build.sh install
```

Uygulama `/Applications/SesKopru.app` olarak kurulur ve başlatılır. İlk derlemede `SesKopru Dev` adlı yerel bir imza sertifikası oluşturulur. Anahtar zinciri parola isterse **Her Zaman İzin Ver** seçilmelidir.

## İzinler

Her Mac'te bir kez verilir:

- **Erişilebilirlik:** Ses tuşlarını yakalamak için. Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik.
- **Sistem sesi kaydı:** Sesi işlemek için. Sorulduğunda izin verilmelidir, verilmezse ses gelmez.

## Bilinen sorun

Dell Display and Peripheral Manager (DDPM) çalışırken ses tuşlarının basma olayları kaybolabilir ve basılı tutma çalışmayabilir. Bu durumda DDPM kapatılmalı ve giriş öğelerinden kaldırılmalıdır.
