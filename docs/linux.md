# Linux kurulum kılavuzu

Bu belge `linux/install-jenkins-agent.sh` scriptinin ayrıntılı kullanımını anlatır. Genel bakış ve dosya listesi
için [readme.md](../readme.md), Windows için [Windows kılavuzu](windows.md) dosyasına bakın.

Örneklerdeki `jenkins.example.com`, `build-01`, `jenkins-build` gibi değerler yer tutucudur; kendi değerlerinizle
değiştirin. `<secret>`, `<sha256>`, `<jdk-klasoru>` gibi işaretleri de gerçek değerlerle değiştirin.

## İçindekiler

1. [Gereksinimler](#1-gereksinimler)
2. [Jenkins tarafında node hazırlığı](#2-jenkins-tarafında-node-hazırlığı)
3. [Hızlı başlangıç](#3-hızlı-başlangıç)
4. [Parametreler](#4-parametreler)
5. [Parametreyle ve sormadan kurulum](#5-parametreyle-ve-sormadan-kurulum)
6. [HTTPS sertifikası](#6-https-sertifikası)
7. [Yeniden çalıştırma ve güncelleme](#7-yeniden-çalıştırma-ve-güncelleme)
8. [Kaldırma](#8-kaldırma)
9. [İşletim: durum, loglar, yeniden başlatma](#9-işletim-durum-loglar-yeniden-başlatma)
10. [Sorun giderme](#10-sorun-giderme)
11. [Güvenlik notları](#11-güvenlik-notları)

## 1. Gereksinimler

| Gereksinim | Ayrıntı |
| --- | --- |
| Dağıtım | systemd kullanan bir Linux (Debian, Ubuntu, RHEL ailesi vb.). `systemctl` yoksa script başlamadan durur. |
| Shell | `bash` |
| Yetki | root ya da `sudo`. Root değilse script `sudo` ile kendini yeniden çalıştırır. |
| Java | Sürüm 17 veya üstü. Script Temurin indirebilir (varsayılan 25, x64 ve aarch64) ya da mevcut bir Java yolu kullanılır. |
| İndirme aracı | `curl` (https adresi için zorunlu) ya da `wget` (yalnızca indirme yedeği). `tar` Temurin için gerekir. |
| Sertifika | `openssl` (sertifika sabitleme ve sertifika kontrolü kararı için). `timeout` (coreutils) de gerekir. |
| Java sistem deposu | Sistem Java deposu kullanılacaksa Debian/Ubuntu'da `ca-certificates-java`, RHEL ailesinde `java` deposu (`/etc/pki/ca-trust/extracted/java/cacerts`) olmalı. Yoksa script sertifikayı sabitler. |
| Ağ (Jenkins) | Makineden Jenkins adresine çıkış. Agent WebSocket ile bağlanır. |
| Ağ (indirme) | Temurin indirilecekse `api.adoptium.net` ve `github.com` erişimi. `agent.jar` Jenkins sunucusundan iner. |

Gerekli araçların varlığını kontrol etmek için:

```bash
command -v curl tar openssl timeout systemctl
```

## 2. Jenkins tarafında node hazırlığı

Script kurulumdan önce Jenkins'te bir node oluşturulmuş olmasını bekler. Menü adları Jenkins sürümüne göre
değişebilir.

1. **Manage Jenkins > Nodes** sayfasında **New Node** ile **Permanent Agent** türünde bir node oluşturun.
2. Node adını yazın (ör. `build-01`). Bu ad script için `--name` ile birebir aynı olmalıdır. Büyük/küçük harf
   farkı da dahil.
3. **Remote root directory** alanına çalışma klasörünü yazın (ör. `/var/lib/jenkins-agent`). Script varsayılanı
   bu değerdir; iki değerin aynı olması karışıklığı önler.
4. **Launch method** olarak **Launch agent by connecting it to the controller** seçin.
5. Node'u kaydedin. Node sayfasındaki agent komutunda `-secret` ile verilen değer secret'tır. Script kurulum
   sırasında yalnızca bu değeri ister.

Jenkins'te **Jenkins URL** ayarının, agent makinesinden erişilebilen bir adres olması gerekir. `agent.jar`
dosyası `<JenkinsUrl>jnlpJars/agent.jar` adresinden indirilir.

## 3. Hızlı başlangıç

### 3.1 Tek satır

Sadece indirip çalıştırmak için:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/linux/install-jenkins-agent.sh)
```

Parametre vererek, boru hattıyla:

```bash
curl -fsSL https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/linux/install-jenkins-agent.sh | sudo bash -s -- --url https://jenkins.example.com/ --name build-01
```

Script sorularını `/dev/tty` üzerinden okur, bu yüzden boru hattıyla çalıştırıldığında da soru sorabilir.
Terminal yoksa (ör. cron, CI) script soru sormadan varsayılanlarla çalışır; eksik değer varsa hata verip durur.

### 3.2 İndir, incele, çalıştır

Scripti çalıştırmadan önce incelemek için önerilen yol:

```bash
curl -fsSL -o install-jenkins-agent.sh https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/linux/install-jenkins-agent.sh
less install-jenkins-agent.sh
sudo bash install-jenkins-agent.sh
```

Parametre ile:

```bash
sudo bash install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01
```

Dosya olarak çalıştırıldığında `sudo` gerekiyorsa script aynı dosyayı `sudo` altında yeniden başlatır.

### 3.3 Etkileşimli kurulum, adım adım

Script dokuz adımdan oluşur. Her adımın başında `[n/9]` yazılır. Varsayılanı olan sorularda boş Enter
varsayılanı kabul eder.

| Adım | Ne sorulur | Varsayılan ve notlar |
| --- | --- | --- |
| 1/9 Jenkins adresi | `Jenkins URL` | Yok, zorunlu. `http://` ya da `https://` ile başlamalı; sonundaki `/` yoksa eklenir. `https` ise sertifika bu adımda kontrol edilir, karar 4. adımda verilir. |
| 2/9 Agent adı | `Agent (node) adi` | Makinenin kısa adı (`hostname -s`). Harf, rakam, `.`, `-`, `_`; ilk karakter harf ya da rakam. |
| 3/9 Dizinler | `Kurulum dizini`, `Calisma dizini (workDir)` | `/opt/jenkins-agent` ve `/var/lib/jenkins-agent` |
| 4/9 Sertifika | Sertifika menüsü (sadece güvenilmeyen sertifikada) | Güvenilen sertifikada yalnızca bilgi yazılır. Güvenilmeyende varsayılan `1` (sabitle); sabitlenemeyen durumda varsayılan `2` (iptal). Bkz. [6](#6-https-sertifikası). |
| 5/9 Kullanıcı | `Agent'in calisacagi kullanici` | `jenkins`. Yoksa sistem kullanıcısı olarak oluşturulur (kabuğu nologin, ev dizini çalışma dizini). |
| 6/9 Java | Java seçimi (aşağıda) | Varsayılan `1`: Temurin 25 indir. |
| 7/9 agent.jar | `agent.jar zaten var, guncellensin mi?` (dosya varsa) | Varsayılan Evet. Sabitlenmiş sertifikada indirme o sertifikayla yapılır. |
| 8/9 Secret | `Secret` (ekranda gösterilmez) | Mevcut secret dosyası varsa `Mevcut secret dosyasi kullanilsin mi?` sorulur, varsayılan Evet. |
| 9/9 systemd servisi | Soru yok | Unit yazılır, etkinleştirilir, yeniden başlatılır ve durumu 3 saniye sonra gösterilir. |

6. adımdaki Java seçimi:

```text
1) Temurin 25 indir (onerilen)
2) Java dizin yolunu yaz
```

- **1 (indir):** Adoptium API'den makinenin mimarisine uygun Temurin JRE (yoksa JDK) `tar.gz` olarak indirilir ve
  `<kurulum dizini>/java/` altına açılır.
- **2 (yol yaz):** JAVA_HOME dizini, `bin` dizini ya da `java` dosyasının yolu girilir.

Her iki durumda `java -version` çalıştırılır ve ana sürüm 17 ya da üstü değilse script durur.

Kurulum sonunda şuna benzer bir özet çıkar:

```text
Kurulum tamamlandi.
  Durum : systemctl status jenkins-agent-build-01
  Log   : journalctl -u jenkins-agent-build-01 -f
  Remoting logu: /var/lib/jenkins-agent/remoting/logs
```

Agent Jenkins'e bağlandığında node sayfasında "online" görünür.

## 4. Parametreler

| Parametre | Varsayılan | Açıklama |
| --- | --- | --- |
| `--url URL` | (sorulur) | Jenkins adresi, ör. `https://jenkins.example.com/` |
| `--name AD` | `hostname -s` | Jenkins'teki node adı |
| `--secret-file DOSYA` | (boş) | Secret'ın okunacağı dosya. Alternatif: `JENKINS_SECRET` ortam değişkeni. |
| `--install-dir DIZIN` | `/opt/jenkins-agent` | `agent.jar`, indirilen Java, `truststore.p12` ve unit'in `ExecStart` yolu |
| `--work-dir DIZIN` | `/var/lib/jenkins-agent` | Agent çalışma dizini (`-workDir`) |
| `--user KULLANICI` | `jenkins` | Servisin çalışacağı kullanıcı. Yoksa sistem kullanıcısı olarak oluşturulur. |
| `--java-home DIZIN` | (boş) | Mevcut Java: JAVA_HOME, `bin` dizini ya da `java` yolu. Verilirse indirme yapılmaz. |
| `--java-version N` | `25` | İndirilecek Temurin sürümü (sayı olmalı) |
| `--trusted-cert-sha256 HEX` | (boş) | Sistemin güvenmediği sertifikanın SHA-256 parmak izi. Eşleşirse sormadan sabitlenir. |
| `--skip-certificate-check` | kapalı | Sertifika kontrolü kapatılır. Uyarı yazılır, onay sorulmaz. Güvensiz. |
| `--non-interactive` | kapalı | Soru sormaz; verilmeyenler için varsayılan kullanılır. Gerekli değer yoksa hata verir. |
| `-y`, `--yes` | kapalı | Onay sorularına evet der. Sertifika kararlarına demez. |
| `--uninstall` | kapalı | Kurulumu kaldırır (bkz. [8](#8-kaldırma)) |
| `--self-test` | | Yardımcı fonksiyonların testlerini çalıştırır, root gerekmez |
| `-h`, `--help` | | Yardım metnini gösterir |

Ortam değişkeni: `JENKINS_SECRET`. Secret'ı komut satırına yazmak yerine bunu veya `--secret-file`'ı kullanın.

## 5. Parametreyle ve sormadan kurulum

Aşağıdaki örneklerde script dosyasının bulunduğu dizinde ve `sudo` ile çalıştırıldığı varsayılır. Dosya yoksa
`sudo bash install-jenkins-agent.sh` yerine boru hattı biçimini kullanın.

### 5.1 Secret dosyası hazırlamak

Secret'ı dosyaya yazmanın en güvenli yolu bir düzenleyici kullanmaktır. Komut satırına `printf` ile yazmak
shell geçmişine düşer.

```bash
sudo install -m 600 /dev/null /root/build-01.secret
sudo nano /root/build-01.secret
```

Dosyanın içine yalnızca secret değerini yazın. Script dosyadaki tüm boşluk ve satır sonlarını siler; secret'ta
boşluk olmamalıdır.

Kurulum:

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --secret-file /root/build-01.secret --non-interactive
```

Script secret'ı bu dosyadan okur, `/etc/jenkins-agent/build-01.secret` dosyasına yazar ve kaynak dosyaya
dokunmaz. Kaynak dosyayı kurulumdan sonra silebilirsiniz.

### 5.2 Ortam değişkeni ile secret

`JENKINS_SECRET` ortam değişkeni de desteklenir. Dikkat: `sudo JENKINS_SECRET=... ./script` biçimi, çoğu sudo
yapılandırmasında değişkeni sudo'nun ortamından düşürür ve secret eksik kalır. Bu nedenle bu biçim önerilmez;
değişkeni root kabuğunda ya da sudo'ya girmeden tanımlayın:

```bash
export JENKINS_SECRET='<secret>'
sudo -E ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --non-interactive
```

`-E` sudo yapılandırmanıza bağlı olarak reddedilebilir. Bu durumda `--secret-file` kullanın. Bu biçimde
secret shell geçmişinde kalabilir; geçmişi temizleyin ya da `HISTCONTROL=ignorespace` ile baş boşluk bırakarak
yazın.

### 5.3 Temurin indir ya da mevcut Java

Temurin indirme, farklı sürümle (`--java-version`):

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --java-version 21 --secret-file /root/build-01.secret --non-interactive
```

Mevcut Java kullanmak:

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --java-home /usr/lib/jvm/temurin-21-jdk-amd64 --secret-file /root/build-01.secret --non-interactive
```

`--java-home` verilen Java'nın sürümü 17 ya da üstü olmalıdır. Java yolu bir dizin, `bin` dizini ya da doğrudan
`java` dosyası olabilir. Sabitleme yapılacaksa `keytool` aynı dizinde (`bin`) bulunmalıdır; yalnızca çalışma
zamanı içeren bir kopyada `keytool` olmayabilir.

Java dizini root'un ev dizininde (ör. `/root/.sdkman`) ise servis kullanıcısı bu dizine erişemez ve servis
başlamaz. Java'yı sistem genelinde erişilebilir bir yere kurun.

### 5.4 Servis kullanıcısı

Varsayılan kullanıcı `jenkins`'tir. Farklı bir kullanıcı için:

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --user jenkins-build --secret-file /root/build-01.secret --non-interactive
```

- Kullanıcı yoksa `useradd --system` ile sistem kullanıcısı olarak oluşturulur (kabuk `nologin`, ev dizini
  çalışma dizini).
- Kullanıcı varsa olduğu gibi kullanılır; grubu ya da ev dizini değiştirilmez.
- Secret dosyasının sahibi bu kullanıcı olur ve izni `600`'dür; servis başka bir kullanıcıyla çalışırsa
  secret okunamaz.

### 5.5 Sabitlenmiş sertifika (parmak izi ile)

Sistemin güvenmediği bir Jenkins sertifikasını parmak iziyle sabitlemek için SHA-256 değerini alın
([6.3](#63-parmak-izini-alma)). Eşleşirse script sormadan sabitler:

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --trusted-cert-sha256 <sha256> --secret-file /root/build-01.secret --non-interactive
```

Parmak izi `AB:CD:..`, `ab cd..` ya da düz hex biçiminde verilebilir; `SHA256 Fingerprint=` öneki de kabul
edilir. Geçersiz biçimde script hemen durur. Eşleşmezse de durur; sunucu sertifikası değişmiş ya da yanlış bir
adres kullanılıyor olabilir.

### 5.6 Sertifika kontrolünü kapatmak

Yalnızca başka seçenek kalmadığında kullanın (bkz. [6.6](#66-kontrolü-kapatmak-güvensiz)):

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --skip-certificate-check --secret-file /root/build-01.secret --non-interactive
```

Bu modda agent `-noCertificateCheck` ile başlar. Her başlatmada `ExecStartPre` ile journal'a WARN yazılır.

`--skip-certificate-check` ile `--trusted-cert-sha256` birlikte verilemez; script hata verir.

### 5.7 Özel dizinler

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --install-dir /srv/jenkins-agent --work-dir /srv/jenkins-work --secret-file /root/build-01.secret --non-interactive
```

Dizinler mutlaka yerel disk üzerinde olmalıdır. Servis kullanıcısı çalışma dizinine yazabilmelidir; script
çalışma dizininin sahibini bu kullanıcı yapar ve izinleri `750` olarak ayarlar.

### 5.8 Yeniden çalıştırmada onaylar

Soru sormadan güncelleme yapmak için (`--non-interactive` ile agent.jar güncellenir ve mevcut secret dosyası
kullanılır):

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --non-interactive
```

Etkileşimli ortamda `-y` onay sorularını evet yapar. Sertifika kararlarını yapmaz; bu kararlar için
`--trusted-cert-sha256` ya da `--skip-certificate-check` gerekir.

## 6. HTTPS sertifikası

Jenkins adresi `https://` ile başlıyorsa script önce `curl` ile sistem deposuna göre bağlantıyı dener (1/9
adımı). Sonuç üç durumdan biridir:

| Durum | Ne olur |
| --- | --- |
| Sistem deposuna göre güvenilir | Java sistemin `cacerts` deposunu kullanır (`/etc/ssl/certs/java/cacerts` ya da RHEL yolu). Soru sorulmaz. Java sistem deposu yoksa sertifika otomatik sabitlenir, yine soru sorulmaz. |
| Güvenilmiyor, ama adres ve tarih sorunsuz | Sertifika gösterilir ve 4/9 adımında menü açılır. |
| Güvenilmiyor ve sabitleme olanaksız | Ad uyuşmazlığı, süresi dolmuş ya da henüz geçerli olmayan sertifika. Sertifika gösterilir, menü açılır ama varsayılan iptaldir ve yalnızca kontrolü kapatma seçeneği vardır. |

### 6.1 Modlar

| Mod | Ne zaman | Agent'a etkisi |
| --- | --- | --- |
| `system` | Sistem deposuna göre güvenilir | Unit'te `-Djavax.net.ssl.trustStore=<Java sistem deposu>` ve parola. Dosya oluşturulmaz. |
| `pinned` | Sabitleme seçildi ya da parmak izi verildi | `<kurulum dizini>/truststore.p12` (`jenkins-ca`) kullanılır. Unit'te `trustStoreType=PKCS12`. |
| `bypass` | Kontrol kapatıldı | Unit'e `-noCertificateCheck` eklenir. Her başlatmada journal'a WARN yazılır. |

### 6.2 Menü

Güvenilmeyen ama sabitlenebilen bir sertifikada menü şöyledir:

```text
1) Sertifikayi sabitle (onerilen)
2) Sertifika kontrolunu kapat (guvensiz)
3) Iptal
Secim [1]:
```

- **1 (sabitle):** Sertifika `truststore.p12` dosyasına yazılır. Onay sorusu sorulur
  (`Bu sertifika sabitlensin mi? ... [e/H]`, varsayılan Hayır). Onay vermezseniz kurulum durur.
- **2 (kapat):** Uyarı yazılır ve onay sorulur (varsayılan Hayır).
- **3 (iptal):** Kurulum durur.

Sertifika sorusunda `-y` evet demez. Sertifika kararını soru sormadan vermek için `--trusted-cert-sha256` ya da
`--skip-certificate-check` kullanın.

Sabitlenebilir olmayan bir sorunda (süresi dolmuş, adres uyuşmuyor vb.) menü yalnızca şunları içerir:

```text
1) Sertifika kontrolunu kapat (guvensiz)
2) Iptal
Secim [2]:
```

Varsayılan iptaldir.

Sistemde zaten olan genel bir kök CA sabitlenecekse script bunu belirtir. Böyle bir CA'yı sabitlemek, o CA'nın
imzaladığı her sunucuya güvenmek anlamına gelir.

### 6.3 Parmak izini alma

Parmak izi, Jenkins sunucusunun zincirindeki en üst sertifikanın SHA-256 değeridir. Script aynı değeri
`openssl` ile alır:

```bash
JENKINS_HOST=jenkins.example.com
openssl s_client -connect "$JENKINS_HOST:443" -servername "$JENKINS_HOST" -showcerts </dev/null 2>/dev/null |
    awk '/-BEGIN CERTIFICATE-/{c=""} {c=c $0 "\n"} /-END CERTIFICATE-/{last=c} END{printf "%s", last}' |
    openssl x509 -noout -fingerprint -sha256
```

Çıktı `sha256 Fingerprint=AB:CD:...` biçimindedir. Bu değerin `AB:CD:...` kısmını ya da tamamını
`--trusted-cert-sha256` ile verebilirsiniz. Değeri Jenkins yöneticisiyle karşılaştırın.

Farklı bir port için `443` değerini değiştirin. Sunucu adresi `https://host:port/yol` ise `host` ve `port`
değerlerini buna göre yazın.

Script menüde gösterdiği SHA-256 değerini de aynı yöntemle hesaplar; menüdeki değer esas alınabilir.

Bu komut `openssl` çalıştırdığı makinenin doğrudan ağ bağlantısını kullanır. Proxy zorunluysa bkz.
[6.5](#65-proxy-notu).

### 6.4 Kurumsal kök CA'yı sisteme eklemek (önerilen)

Kurumun kök CA sertifikasını sistem deposuna eklemek en temiz çözümdür. Sonra `curl` de Java da sertifikayı
sistem deposundan doğrular:

Debian/Ubuntu:

```bash
sudo cp kurum-kok-ca.crt /usr/local/share/ca-certificates/kurum-kok-ca.crt
sudo update-ca-certificates
```

RHEL ailesi:

```bash
sudo cp kurum-kok-ca.crt /etc/pki/ca-trust/source/anchors/kurum-kok-ca.crt
sudo update-ca-trust
```

Ardından scripti yeniden çalıştırın. Sertifika artık "sistem deposuna göre güvenilir" olarak görünür.

### 6.5 Proxy notu

Java sistem proxy'sini kullanmaz; `curl` ise `https_proxy` ortam değişkenini kullanır, `openssl s_client`
kullanmaz. Proxy TLS inceleyen bir ürünse agent'ın göreceği sertifika script'in gördüğünden farklı olabilir ve
sabitleme eşleşmez. Script `https_proxy` tanımlıysa ve sertifika güvenilmiyorsa bu konuda uyarı verir. Bu
durumda proxy'nin kök CA'sını sisteme eklemek ya da bir proxy olmadan kurulum yapmak gerekir.

### 6.6 Kontrolü kapatmak (güvensiz)

Kontrol kapatıldığında ağı dinleyen biri Jenkins gibi davranıp agent secret'ını ele geçirebilir ve agent'a iş
gönderebilir. Tercih sırası:

1. Kurum kök CA'sını sisteme eklemek (6.4).
2. Parmak izi ile sabitlemek (`--trusted-cert-sha256`).
3. Kontrolü kapatmak (`--skip-certificate-check`), son çare.

### 6.7 Openssl gereksinimi

Sertifika sistem deposunda güvenilmiyorsa script `openssl` olmadan durur; bu, `--skip-certificate-check`
verilse bile geçerlidir. `openssl` yoksa kurulumdan önce kurun ya da kurumun kök CA'sını sisteme ekleyip
sertifikayı güvenilir hale getirin.

### 6.8 Yeniden çalıştırmada sertifika

- Aynı sertifika zaten sabitliyse (`truststore.p12` içindeki parmak izi eşleşiyorsa) mevcut dosya kullanılır ve
  soru sorulmaz.
- Mod değişirse eski `truststore.p12` silinir. Sabitlemeden kontrol kapatmaya ya da tersine geçişte geçerlidir.
- Kök CA sabitlendiyse yalnızca CA değiştiğinde, sitenin kendi sertifikası sabitlendiyse sertifika
  yenilendiğinde script yeniden çalıştırılmalıdır. Aksi halde agent Jenkins'e bağlanamaz.

## 7. Yeniden çalıştırma ve güncelleme

Script aynı `--name` ile tekrar çalıştırıldığında mevcut kurulumu günceller. Servis dosyası üzerine yazılır ve
servis yeniden başlatılır (9/9 adımı).

### 7.1 Ne yeniden kullanılır, ne değişir

| Öğe | Yeniden çalıştırmada |
| --- | --- |
| `agent.jar` | Sorulur (varsayılan Evet). `--non-interactive` ya da `-y` ile güncellenir. Hayır denirse mevcut dosya kullanılır. |
| Java | Yeniden seçilir. Temurin indirmede aynı sürüm dizini varsa indirme yapılmaz, mevcut dizin kullanılır. |
| Secret dosyası | `--secret-file` ya da `JENKINS_SECRET` verilirse yeni değer yazılır. Verilmezse ve dosya varsa `Mevcut secret dosyasi kullanilsin mi?` sorulur (varsayılan Evet). `--non-interactive` mevcut dosyayı kullanır. |
| `truststore.p12` | Aynı sertifikaysa yeniden kullanılır. Değişmişse ya da mod değişmişse yeniden yazılır ya da silinir. |
| Servis dosyası | Her seferinde yeniden yazılır, `daemon-reload` yapılır. |
| Kullanıcı | Varsa olduğu gibi kalır. |
| Kurulum ve çalışma dizinleri | Varsa üzerinde işlem yapılmaz; dizinlerin izinleri değiştirilmez. |

Önemli: Güncelleme sırasında çalışan servis durdurulmaz. Servis, 9/9 adımında yeniden başlatılana kadar eski
`agent.jar` ile çalışmaya devam eder. Jar'ın güncellenmesi sırasında servisin durdurulması daha güvenlidir:

```bash
sudo systemctl stop jenkins-agent-build-01
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --non-interactive
```

9/9 adımına gelinmeden çıkan hatalar çalışan servisi durdurmaz. Ancak 6/9 adımında `truststore.p12` değişmiş
olabilir; Java sertifika deposunu genellikle yalnızca başlatırken okuduğu için değişiklik servis yeniden
başlatılana kadar uygulanmaz.

### 7.2 Güncelleme komutu

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --non-interactive
```

Secret değişmediyse ek bir şey gerekmez. Secret değiştiyse `--secret-file` ile yeni dosyayı verin.

### 7.3 Java değiştirme

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --java-home /usr/lib/jvm/temurin-21-jdk-amd64 --non-interactive
```

Eski Java dizini otomatik silinmez.

### 7.4 Secret değiştirme

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --secret-file /root/build-01.secret --non-interactive -y
```

### 7.5 Kurulum dizinini değiştirme

`--install-dir` değiştirilirse servis dosyası aynı adla yeniden yazılır ancak eski kurulum dizini silinmez.
Eski dizini elle kaldırın (`sudo rm -rf <eski-dizin>`). `--uninstall` yeni servisi de kaldırdığı için temizlik
amacıyla kullanılmaz.

### 7.6 Sertifika modunu değiştirme

- Sabitlemeden kontrol kapatmaya: `--skip-certificate-check` ile çalıştırın. Eski `truststore.p12` silinir.
- Kontrol kapalıyken sabitlemeye: `--trusted-cert-sha256 <sha256>` ile çalıştırın.
- Kök CA sisteme eklendiyse parametre gerekmez; sertifika `system` modunda kullanılır.

## 8. Kaldırma

```bash
sudo ./install-jenkins-agent.sh --uninstall --name build-01
```

Bu komut şunları yapar:

1. `jenkins-agent-build-01.service` servisini durdurur, devre dışı bırakır ve servis dosyasını siler.
2. `/etc/jenkins-agent/build-01.secret` dosyasını siler.
3. Kurulum dizininin (`/opt/jenkins-agent`) silinip silinmeyeceğini sorar. Varsayılan Hayır.

Kurulum dizini farklıysa `--install-dir` ile verin:

```bash
sudo ./install-jenkins-agent.sh --uninstall --name build-01 --install-dir /srv/jenkins-agent
```

Sormadan kurulum dizinini de silmek için `-y` ekleyin:

```bash
sudo ./install-jenkins-agent.sh --uninstall --name build-01 --install-dir /srv/jenkins-agent -y
```

Çalışma dizini (`/var/lib/jenkins-agent`) ve servis kullanıcısı silinmez. Bunları kendiniz kaldırın:

```bash
sudo rm -rf /var/lib/jenkins-agent
sudo userdel jenkins
```

Kullanıcıyı silmeden önce başka bir servisin o kullanıcıyı kullanmadığından emin olun.

## 9. İşletim: durum, loglar, yeniden başlatma

Servis adı her zaman `jenkins-agent-<AD>` biçimindedir.

### 9.1 Durum

```bash
systemctl status jenkins-agent-build-01 --no-pager
systemctl is-enabled jenkins-agent-build-01
systemctl is-active jenkins-agent-build-01
```

`Active: active (running)` servisin çalıştığını gösterir. `activating (auto-restart)` ise Java çökmüş ve servis
10 saniyede bir yeniden denemektedir; loglara bakın.

Unit dosyasının içeriğini görmek için:

```bash
systemctl cat jenkins-agent-build-01
```

Bu komut secret içermez; yalnızca `@/etc/jenkins-agent/build-01.secret` gibi dosya yolunu gösterir.

### 9.2 Java süreci

```bash
pgrep -af 'agent\.jar'
```

Bir agent için beklenen süreç sayısı 1'dir. Komut satırında secret yoktur; yalnızca dosya yolu görünür.

### 9.3 Loglar

| Log | Konum | İçerik |
| --- | --- | --- |
| Servis logu | journal (`journalctl -u jenkins-agent-build-01`) | Java'nın çıktısı, başlatma, çıkış kodu, bağlantı hataları. Bu script'in ana logudur. |
| Remoting logu | `/var/lib/jenkins-agent/remoting/logs/` | Agent'ın kendi logları: Jenkins'e bağlantı ve WebSocket ayrıntıları. |

Son 200 satır:

```bash
journalctl -u jenkins-agent-build-01 -n 200 --no-pager
```

Canlı izleme:

```bash
journalctl -u jenkins-agent-build-01 -f
```

Belirli bir zamandan sonrası:

```bash
journalctl -u jenkins-agent-build-01 --since "1 hour ago" --no-pager
```

Remoting logunun en yenisi:

```bash
sudo ls -t /var/lib/jenkins-agent/remoting/logs | head -n 3
sudo tail -n 100 "/var/lib/jenkins-agent/remoting/logs/<dosya-adi>"
```

### 9.4 Yeniden başlatma ve durdurma

```bash
sudo systemctl restart jenkins-agent-build-01
sudo systemctl stop jenkins-agent-build-01
sudo systemctl start jenkins-agent-build-01
```

Servis `Restart=always` ile çalışır; Java çıksa da 10 saniye sonra yeniden başlar. Bilerek durdurmak için
`stop` kullanın; `stop` sonrası servis yeniden başlatılmaz.

### 9.5 Açılışta

Servis `multi-user.target` ve `network-online.target` bağımlılıklarıyla etkinleştirilir. Makine yeniden
başladığında servis kendiliğinden çalışır.

### 9.6 Manuel çalıştırma (tanı)

Servis durdurulduktan sonra Java'yı servis kullanıcısı olarak elle çalıştırıp hatayı görebilirsiniz:

```bash
sudo systemctl stop jenkins-agent-build-01
sudo -u jenkins /opt/jenkins-agent/java/<jdk-klasoru>/bin/java -jar /opt/jenkins-agent/agent.jar -url https://jenkins.example.com/ -name build-01 -secret '@/etc/jenkins-agent/build-01.secret' -webSocket -workDir /var/lib/jenkins-agent
```

Sabitlenmiş sertifikada `-Djavax.net.ssl.trustStore=/opt/jenkins-agent/truststore.p12`,
`-Djavax.net.ssl.trustStoreType=PKCS12` ve `-Djavax.net.ssl.trustStorePassword=changeit` argümanlarını
`-jar`'dan önce ekleyin. Sistem deposu kullanılıyorsa `-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts`
ve parola ekleyin (Debian/Ubuntu yolu; RHEL'de `/etc/pki/ca-trust/extracted/java/cacerts`).

Bu komut secret'ı `@dosya` biçimiyle okur; secret'ı argüman olarak yazmayın. Tanı bittiğinde Ctrl+C ile durdurup
servisi yeniden başlatın.

## 10. Sorun giderme

### 10.1 PKIX path building failed

Belirti: Jenkins'te node offline, journal veya remoting logunda şu satır var:

```text
javax.net.ssl.SSLHandshakeException: PKIX path building failed: ...
```

Anlamı: Java, Jenkins sertifikasının zincirini güvenilir bir köke bağlayamıyor. Olası nedenler:

- **Sabitleme modu, sertifika değişmiş.** Jenkins sertifikası yenilendi ya da CA değişti; `truststore.p12` eski
  sertifikayı içeriyor. Scripti yeniden çalıştırın, menü yeni sertifikayı gösterir ve yeniden sorar.
- **Sistem modu, Java deposu eski.** Sistem deposuna kök CA eklendi ama Java'nın `cacerts` dosyası
  güncellenmedi. Debian/Ubuntu'da `sudo update-ca-certificates` (`ca-certificates-java` kuruluysa `cacerts`
  yeniden üretilir), RHEL ailesinde `sudo update-ca-trust` çalıştırın, sonra servisi yeniden başlatın.
- **Java sistem deposu yok ve kurulum sabitlemeyi atladı.** Scripti yeniden çalıştırın ve menüden karar verin.
- **Proxy TLS inceliyor.** Agent proxy'yi kullanmaz; gördüğü sertifika script'inkinden farklı olabilir
  (bkz. [6.5](#65-proxy-notu)).

Yapılacaklar: remoting logunu ve journal'ı inceleyin, scripti yeniden çalıştırın, menüden karar verin. Kurulumun
çıktısındaki modu (`system`, `pinned`, `bypass`) unit dosyasından kontrol edin:

```bash
systemctl cat jenkins-agent-build-01 | grep -E 'trustStore|noCertificateCheck'
```

### 10.2 systemd servisi başlamıyor

`systemctl status` çıktısındaki `status=` alanına bakın:

| Durum | Anlamı ve çözüm |
| --- | --- |
| `status=203/EXEC` | `ExecStart` içindeki Java çalıştırılamıyor. Yol yanlış ya da servis kullanıcısı o dizine erişemiyor. Kontrol: `sudo -u jenkins test -x /opt/jenkins-agent/java/<jdk-klasoru>/bin/java && echo ok`. Java'yı root'un ev dizininde değil sistem genelinde erişilebilir bir yere kurun. |
| `status=200/CHDIR` | Çalışma dizini yok. `sudo mkdir -p /var/lib/jenkins-agent && sudo chown jenkins: /var/lib/jenkins-agent` ya da scripti yeniden çalıştırın. |
| `Permission denied` (journal) | Secret ya da çalışma dizini servis kullanıcısı tarafından okunamıyor. Kontrol: `sudo -u jenkins test -r /etc/jenkins-agent/build-01.secret && echo ok`. |
| `status=1/FAILURE` ve Java hatası | Journal'daki Java hatasına bakın (`journalctl -u ... -n 200`). Çoğu zaman sertifika (10.1) ya da secret (yanlış ya da eski) sorunudur. |
| Sürekli `auto-restart` | Java her seferinde çıkıyor. Journal'daki son hatayı okuyun; Java'yı [9.6](#96-manuel-çalıştırma-tanı) ile elle çalıştırın. |

### 10.3 Secret yanlış ya da değişmiş

Jenkins'te node yeniden oluşturulduysa secret değişir. Secret dosyasını güncelleyin:

```bash
sudo ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --secret-file /root/build-01.secret --non-interactive -y
```

Journal'da kimlik doğrulama (secret) ile ilgili bir hata varsa secret yanlıştır; Jenkins node sayfasındaki değerle
karşılaştırın.

### 10.4 Aynı adla iki agent

Node'un tek bir agent bağlantısı olmalıdır. Servis çalışırken elle başka bir `agent.jar` açıksa Jenkins node'u
offline gösterebilir.

```bash
pgrep -af 'agent\.jar'
```

Servis dışındaki süreci bulun (PID) ve durdurun:

```bash
sudo kill <PID>
```

Servis ayrıca çalışıyorsa `systemctl restart` ile yeniden başlatın.

### 10.5 agent.jar güncellenemedi

Dosya kopyalama (`install`) hata verirse kurulum dizininin izinlerine ve disk alanına bakın:

```bash
ls -ld /opt/jenkins-agent
ls -l /opt/jenkins-agent/agent.jar
df -h /opt
```

Kurulum dizini root'a aittir (`755`), `agent.jar` `644`'tür. Disk doluysa önce yer açın.

### 10.6 Secret dosyasının izinleri

```bash
ls -l /etc/jenkins-agent/build-01.secret
```

Beklenen: sahibi servis kullanıcısı (ör. `jenkins`), izin `-rw-------`. Sahibi farklıysa scripti yeniden
çalıştırın; script sahibi ve izni düzeltir.

### 10.7 Diğer sık hatalar

| Hata | Anlamı ve çözümü |
| --- | --- |
| `curl veya wget gerekli.` | İndirme aracı yok. `apt-get install curl` ya da `dnf install curl`. |
| `https adresi icin curl gerekli.` | Sertifika kontrolü `curl` ile yapılır. Kurun. |
| `openssl gerekli.` | Sertifika güvenilmiyor ve `openssl` yok. Bkz. [6.7](#67-openssl-gereksinimi). |
| `systemd (systemctl) bulunamadi.` | Dağıtım systemd kullanmıyor ya da konteynerde. Script systemd gerektirir. |
| `Gecersiz --trusted-cert-sha256` | Parmak izi 64 haneli hex değil. Değeri kontrol edin. |
| `--trusted-cert-sha256 ve --skip-certificate-check birlikte verilemez.` | İki seçenekten birini kaldırın. |
| `Java surumu 17 veya ustu olmali (bulunan: 11)` | Java eski. Yeni bir Java verin ya da `--java-version` ile Temurin indirin. |
| `Gecerli bir Java bulunamadi.` | `--non-interactive` modunda verilen Java yolu geçersiz. Yolu kontrol edin. |
| `Secret verilmedi (--secret-file veya JENKINS_SECRET).` | Non-interactive kurulumda secret yok ve mevcut dosya da yok. [5.1](#51-secret-dosyası-hazırlamak) bölümüne bakın. |
| `Jenkins'e baglanilamadi (ag, port veya firewall)` | Makineden Jenkins'e ağ yok. `curl -v <JenkinsUrl>` ile kontrol edin. |
| `Jenkins adresi cozulemedi (DNS)` | DNS çözümlemesi başarısız. Ad ve `/etc/hosts` kayıtlarını kontrol edin. |

## 11. Güvenlik notları

- Secret hiçbir zaman servis dosyasının ya da komut satırının içine yazılmaz. Servis `-secret @/etc/jenkins-agent/<ad>.secret`
  ile dosyayı okur.
- Secret dosyası `/etc/jenkins-agent/<ad>.secret` içinde, sahibi servis kullanıcısı ve izni `600`. Dizin
  `/etc/jenkins-agent` `755`'tir; dosyanın içeriğini yalnızca sahibi okuyabilir.
- Kurulum dizini root'a aittir (`755`); servis kullanıcısı kurulum dizinindeki dosyaları değiştiremez. Servis
  kullanıcısı yalnızca çalışma dizinine yazabilir (`750`).
- `truststore.p12` sabitleme modunda sahibi servis kullanıcısı ve izni `600` olarak yazılır.
- `--secret-file` ile verilen kaynak dosyayı kurulumdan sonra silin ya da yalnızca root okuyabilecek şekilde
  tutun.
- Komut satırında `--secret-file` yolu görünür, secret görünmez. Secret'ı komut satırına yazmayın.
- Java ve `agent.jar` HTTPS ile indirilir. İndirilen dosyaların imza kontrolü yapılmaz.
- Sertifika kontrolü kapatılırsa secret, ağı dinleyen biri tarafından ele geçirilebilir. Son çare olarak kullanın.
  Ayrıntı için bkz. [6](#6-https-sertifikası).
- `sudo` ile çalıştırırken `--non-interactive` kullanan otomasyonlarda secret dosyasının izinlerini ve kaynağını
  kontrol edin.
