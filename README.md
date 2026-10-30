# SesKopru

Ses seviyesi kontrolü olmayan çıkış aygıtlarında (DisplayPort/HDMI monitörler) Mac'in ses tuşlarını çalıştıran menü çubuğu uygulaması. Sesi Core Audio Process Tap ile yakalar, kazanç uygulayıp aynı çıkışa geri verir. Sürücü veya DDC kullanmaz.

## Gereksinimler

- Apple Silicon Mac, macOS 14.4 veya üstü
- macOS 26 veya üstü SDK'lı Xcode ya da Command Line Tools
- Anahtar zincirinde `SesKopru Dev` adlı kod imzalama sertifikası

## Sertifika

`build.sh` uygulamayı `SesKopru Dev` sertifikasıyla imzalar. Sertifika repoda yoktur, derlemeden önce aşağıdaki yollardan biriyle hazırlanmalıdır.

**Var olan sertifikayı taşımak (önerilir):** İmza makineler arasında aynı kalır.

1. Sertifikanın olduğu Mac'te Anahtar Zinciri Erişimi'ni aç, `SesKopru Dev`e sağ tıkla, **Dışa Aktar** ile `.p12` olarak kaydet ve bir parola belirle.
2. Dosyayı diğer Mac'e taşıyıp içe aktar:

```bash
security import SesKopruDev.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
```

**Yeni sertifika oluşturmak:**

1. **Anahtar Zinciri Erişimi → Sertifika Asistanı → Sertifika Oluştur** yolunu izle.
2. Ad `SesKopru Dev`, kimlik türü **Kendinden İmzalı Kök**, sertifika türü **Kod İmzalama** olsun.

## Derleme ve kurulum

```bash
git clone https://github.com/atillayurtseven/SesKopru.git
```

```bash
cd SesKopru && ./build.sh install
```

Uygulama `/Applications/SesKopru.app` olarak kurulur ve başlatılır. Anahtar zinciri parola isterse **Her Zaman İzin Ver** seçilmelidir.

## İzinler

Her Mac'te bir kez verilir:

- **Erişilebilirlik:** Ses tuşlarını yakalamak için. Sistem Ayarları → Gizlilik ve Güvenlik → Erişilebilirlik.
- **Sistem sesi kaydı:** Sesi işlemek için. Sorulduğunda izin verilmelidir, verilmezse ses gelmez.

## Bilinen sorun

Dell Display and Peripheral Manager (DDPM) çalışırken ses tuşlarının basma olayları kaybolabilir ve basılı tutma çalışmayabilir. Bu durumda DDPM kapatılmalı ve giriş öğelerinden kaldırılmalıdır.
