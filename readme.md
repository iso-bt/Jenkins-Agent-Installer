# Jenkins Agent Installer

Windows ve Linux makinelere Jenkins inbound agent (webSocket) kurulumu yapan scriptler.

Script şunları yapar:

- Java'yı hazırlar: Eclipse Temurin indirir ya da mevcut bir Java'yı kullanır (sürüm 17 ve üstü zorunlu)
- Jenkins sunucusundan `agent.jar` dosyasını indirir
- Node secret'ını erişimi kısıtlanmış bir dosyaya yazar
- Agent'ı sistem açılışında başlayacak ve düşerse tekrar ayağa kalkacak şekilde kaydeder
  (Windows: zamanlanmış görev, Linux: systemd servisi)
- Jenkins sertifikası makinede doğrulanamazsa parmak izi ile sabitleme ya da kontrolü kapatma seçeneği sunar
  (bkz. [HTTPS sertifikası](#https-sertifikası))

Verilmeyen her değer adım adım sorulur. Tüm değerler parametre olarak verilirse hiç soru sormadan çalışır.

## Dosyalar

| Dosya | Açıklama |
| --- | --- |
| `windows/Install-JenkinsAgent.ps1` | Windows kurulum scripti (Windows PowerShell 5.1) |
| `windows/tests/Install-JenkinsAgent.Tests.ps1` | Yardımcı fonksiyonların testleri |
| `linux/install-jenkins-agent.sh` | Linux kurulum scripti (bash, systemd) |

## Gereksinimler

- Jenkins tarafında node önceden oluşturulmuş olmalı (Launch method: "Launch agent by connecting it to the controller").
  Secret değeri node sayfasındaki komutta yer alır.
- Jenkins sunucusunda WebSocket desteği açık olmalı (agent `-webSocket` ile bağlanır).
- Windows: Windows 10 / Server 2016 ve üstü, Windows PowerShell 5.1, yönetici yetkisi.
- Linux: systemd, bash, `curl` veya `wget`, `tar`, root yetkisi (veya sudo). `https` adresi için `curl` gerekir;
  sertifika sabitlenecekse ayrıca `openssl` gerekir.
- Java'yı script indirecekse `api.adoptium.net` ve `github.com` adreslerine erişim.

## HTTPS sertifikası

Jenkins adresi `https://` ile başlıyorsa script, adresi aldıktan hemen sonra (her iki platformda da 1. adım)
sunucu sertifikasını makinedeki sertifika deposuna göre kontrol eder.

| Durum | Windows | Linux |
| --- | --- | --- |
| Sertifika güvenilir | Windows sertifika deposuna göre doğrulanır. Java, `Windows-ROOT` deposunu kullanır. | Sistem sertifika deposuna göre doğrulanır. Java, sistemin `cacerts` deposunu kullanır. Java sistem deposu yoksa (ör. `ca-certificates-java` kurulu değilse) sertifika otomatik sabitlenir ve soru sorulmaz. |
| Sertifika güvenilmiyor | Aşağıdaki menü açılır. | Aşağıdaki menü açılır (4. adım). |

Güvenilmeyen sertifikada önce konu, yayıncı, geçerlilik tarihleri ve SHA-256 parmak izi gösterilir, sonra menü çıkar:

1. **Sertifikayı sabitle (önerilen):** Onaylanırsa sertifika kurulum klasöründeki `truststore.p12` dosyasına
   `jenkins-ca` takma adıyla yazılır. Sistem sertifika deposuna dokunulmaz. Adres ile sertifikadaki ad
   eşleşmiyorsa ya da zincir süresi geçmiş, henüz geçerli değil veya hatalıysa bu seçenek sunulmaz (sabitleme
   bunu çözmez); nedeni gösterilir ve sadece kontrolü kapatma ve iptal kalır. Linux'ta bu durumda menünün
   varsayılanı iptaldir. Sabitlenecek sertifika sistem deposunda zaten olan genel bir kök CA ise Linux onay
   sorusundan önce bunu belirtir.
2. **Sertifika kontrolünü kapat (güvensiz):** Uyarı gösterilir ve ayrıca onay istenir. Agent
   `-noCertificateCheck` ile başlatılır; her başlatmada log'a WARN yazılır.
3. **İptal:** Kurulum durur.

Sertifika sorularında `-Force` (Windows) ve `-y` (Linux) evet demez. Soru sorulmadan karar vermek için:

- Parmak izini bilip sabitlemek: Windows `-TrustedCertThumbprint <sha256>`, Linux `--trusted-cert-sha256 <hex>`.
  Parmak izi eşleşirse sormadan sabitlenir, eşleşmezse ya da sertifika yukarıdaki nedenlerle sabitlenemiyorsa
  kurulum durur.
- Kontrolü sormadan kapatmak: Windows `-SkipCertificateCheck`, Linux `--skip-certificate-check`.
  Uyarı yine yazılır, onay sorulmaz.
- Linux'ta `--trusted-cert-sha256` ve `--skip-certificate-check` birlikte verilirse kurulum hata verip durur.
- Sistemce güvenilen sertifikada bu seçenekler yok sayılır.

Parmak izi menüdeki "SHA-256" satırında görünür; değerini Jenkins yöneticisinden doğrulayın.

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -Secret <secret> -TrustedCertThumbprint <sha256> -NonInteractive
```

```bash
sudo JENKINS_SECRET=<secret> ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --trusted-cert-sha256 <sha256> --non-interactive
```

Yeniden çalıştırma:

- Aynı sertifika zaten sabitliyse (truststore içindeki parmak izi eşleşiyorsa) mevcut `truststore.p12` kullanılır, soru sorulmaz.
- Mod değişirse eski `truststore.p12` silinir (sabitlemeden kontrol kapatmaya ya da tam tersine geçişte).
- Kök CA sabitlendiyse yalnızca CA değişince, sitenin kendi sertifikası sabitlendiyse yenilenince de script
  tekrar çalıştırılmalı; aksi halde agent Jenkins'e bağlanamaz. Windows'ta agent sabitlenmiş sertifikayla
  hata verip çıkarsa wrapper `agent.log` dosyasına WARN yazar.

Güvenlik ve proxy:

- Sertifika kontrolünü kapatmak, ağı dinleyen birinin Jenkins gibi davranıp secret'ı almasına ve agent'a iş
  göndermesine izin verir. Tercih sırası: kurum kök CA'sını sisteme yüklemek, olmazsa parmak izi ile sabitlemek.
  Kontrolü kapatmak son çaredir.
- Java sistem proxy'sini kullanmaz. Araya TLS inceleyen bir proxy varsa script'in gördüğü sertifika ile agent'in
  göreceği sertifika farklı olabilir ve sabitlenen sertifika eşleşmeyebilir. Linux'ta sertifika `openssl s_client`
  ile doğrudan alınır; bu araç proxy ortam değişkenlerini kullanmaz. Proxy tanımlıysa (Windows: sistem proxy'si,
  Linux: `https_proxy`/`HTTPS_PROXY`) ve sertifika doğrulanamıyorsa script bu konuda uyarı verir.

## Windows

### Hızlı başlangıç

Yönetici olarak açılmış bir PowerShell penceresinde:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/windows/Install-JenkinsAgent.ps1 | iex
```

Parametre vererek:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/windows/Install-JenkinsAgent.ps1))) -JenkinsUrl https://jenkins.example.com/ -AgentName build-01
```

Sertifika seçenekleri de aynı şekilde verilir (bkz. [HTTPS sertifikası](#https-sertifikası)). `irm | iex` ile
parametresiz çalıştırılırsa sertifika kararı etkileşimli sorulur.

İnternetten indirilen bir scripti çalıştırmadan önce içeriğini okuyun. Tercih ederseniz önce dosyayı
indirip inceleyin, sonra çalıştırın:

```powershell
irm https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/windows/Install-JenkinsAgent.ps1 -OutFile Install-JenkinsAgent.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-JenkinsAgent.ps1
```

Pencere yönetici olarak açılmamışsa script kendini yönetici olarak yeni bir pencerede tekrar başlatır
(UAC onayı istenir). `irm | iex` ile çalıştırıldığında bunun için scriptin kendisini `%TEMP%` altında rastgele
isimli yeni bir klasöre indirir. `-Secret` yeni pencereye taşınmaz, orada tekrar sorulur.

### Parametreler

| Parametre | Varsayılan | Açıklama |
| --- | --- | --- |
| `-JenkinsUrl` | (sorulur) | Jenkins adresi, ör. `https://jenkins.example.com/` |
| `-AgentName` | bilgisayar adı | Jenkins'teki node adı (harf, rakam, `.`, `-`, `_`) |
| `-Secret` | (gizli olarak sorulur) | Node secret değeri |
| `-InstallDir` | `C:\jenkins-agent` | `agent.jar`, Java, secret, wrapper ve log dosyasının yeri |
| `-WorkDir` | `C:\jenkins` | Agent çalışma dizini (`-workDir`) |
| `-JavaMode` | `Download` | `Download`, `Path` veya `Browse` |
| `-JavaHome` | | Mevcut Java yolu (JAVA_HOME, `bin` klasörü veya `java.exe`) |
| `-JavaVersion` | `25` | İndirilecek Temurin sürümü |
| `-RunAs` | `SYSTEM` | Görevin çalışacağı hesap, ör. `DOMAIN\kullanici` |
| `-RunAsCredential` | | `-RunAs` bir kullanıcı ise parolası (`Get-Credential`) |
| `-NonInteractive` | | Soru sormaz, verilmeyenler için varsayılanları kullanır |
| `-Force` | | Onay sorularına evet der (sertifika sorularına demez) |
| `-TrustedCertThumbprint` | | Windows'un doğrulayamadığı Jenkins sertifikasının SHA-256 parmak izi; eşleşirse sormadan sabitlenir |
| `-SkipCertificateCheck` | | Jenkins sertifikası hiç doğrulanmaz (güvensiz); sormaz |
| `-Uninstall` | | Kurulumu kaldırır |

Örnek, soru sormadan kurulum:

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -Secret <secret> -NonInteractive
```

`-Secret` ile verilen değer PowerShell geçmişinde (`PSReadLine` geçmiş dosyası dahil) kalır. Mümkünse
`-Secret` vermeyin; secret ekranda gösterilmeden sorulur. Makinede daha önce oluşturulmuş bir secret
dosyası varsa `-NonInteractive` ile mevcut dosya kullanılır.

### Kurulum adımları

| Adım | Sorulan | Not |
| --- | --- | --- |
| 1/8 | Jenkins URL | `http://` veya `https://` ile başlamalı, sonuna `/` eklenir; `https` ise sertifika kontrol edilir |
| 2/8 | Agent adı | Varsayılan bilgisayar adı |
| 3/8 | Kurulum ve çalışma klasörü | Yoksa oluşturulur. Sertifika güvenilmiyorsa menü bu adımda açılır |
| 4/8 | Görev hesabı | `SYSTEM` veya kullanıcı hesabı (parola sorulur) |
| 5/8 | Java | Aşağıya bakın |
| 6/8 | `agent.jar` | `<JenkinsUrl>/jnlpJars/agent.jar` adresinden indirilir; dosya varsa güncelleme sorulur. Sabitleme seçildiyse `truststore.p12` bu adımda yazılır |
| 7/8 | Secret | Ekranda gösterilmeden sorulur; dosya zaten varsa mevcut dosya kullanılabilir |
| 8/8 | Zamanlanmış görev | Görev oluşturulur, başlatılır ve durumu gösterilir |

### Java seçenekleri

1. **İndir:** Adoptium API'den Temurin JRE (yoksa JDK) zip dosyası indirilir ve `<InstallDir>\java` altına açılır.
2. **Yol yaz:** JAVA_HOME klasörü, `bin` klasörü veya `java.exe` yolu girilir.
3. **Klasör seç:** Klasör seçme penceresi açılır. Pencere açılamazsa (ör. Server Core) yol elle sorulur.

Her durumda `java -version` çalıştırılır ve ana sürümün 17 veya üstü olduğu kontrol edilir.
Ağ (UNC) yolları kabul edilmez; zamanlanmış görev bu yollara erişemeyebilir. Aynı kural kurulum ve
çalışma klasörü için de geçerlidir.

### Zamanlanmış görev

- Adı: `JenkinsAgent-<AgentName>`. Aynı isimde görev varsa önce kaldırılır.
- Çalıştırdığı komut: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File "<InstallDir>\start-agent.ps1"`
- Tetikleyiciler: sistem açılışı ve kurulum anından itibaren süresiz olarak dakikada bir.
- Ayarlar: süre sınırı yok, yeni örnek başlatılmaz (`IgnoreNew`), kaçırılan çalıştırma hemen yapılır,
  pilde de çalışır, hata olursa 1 dakika arayla 3 kez tekrar dener.
- `SYSTEM` için en yüksek yetkiyle, kullanıcı hesabı için parola ile kaydedilir.
  Kullanıcı hesabının "Log on as a batch job" hakkı olmalıdır.

`start-agent.ps1` kurulum sırasında üretilir. Bu agent için çalışan bir `java.exe` varsa (komut satırında
`agent.jar` ve `-name <AgentName>` geçen süreç) hiçbir şey yapmadan çıkar. Yoksa Java'yı ön planda
başlatır; görev agent çalıştığı sürece "çalışıyor" durumunda kalır. Böylece aynı isimle ikinci bir agent
başlamaz ve agent kapanırsa en geç bir dakika içinde tekrar başlar.

Loglar:

- `<InstallDir>\agent.log`: wrapper'ın başlatma/çıkış kayıtları. 1 MB'ı geçince son 200 satır tutulur.
- `<WorkDir>\remoting\logs`: agent'ın kendi logları.

### Kaldırma

```powershell
.\Install-JenkinsAgent.ps1 -Uninstall -AgentName build-01
```

Görevi durdurup siler, bu agent'a ait `java.exe` süreçlerini sonlandırır ve kurulum klasörünün silinip
silinmeyeceğini sorar (`-Force` ile sormadan siler). Çalışma klasörü silinmez.

### Testler

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\windows\tests\Install-JenkinsAgent.Tests.ps1
```

Pester gerektirmez. Java sürümü ayrıştırma, Java yolu çözümleme, URL düzeltme, süreç eşleştirme ve
üretilen wrapper scriptin söz dizimi test edilir.

## Linux

### Hızlı başlangıç

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/linux/install-jenkins-agent.sh)
```

Parametre vererek:

```bash
curl -fsSL https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/linux/install-jenkins-agent.sh | sudo bash -s -- --url https://jenkins.example.com/ --name build-01
```

Sorular `/dev/tty` üzerinden okunduğu için iki kullanım şeklinde de script soru sorabilir. Terminal yoksa
(ör. otomasyon) soru sormadan varsayılanlarla çalışır. Root değilse `sudo` ile kendini tekrar başlatır.
Burada da çalıştırmadan önce scripti indirip incelemeniz önerilir.

### Parametreler

| Parametre | Varsayılan | Açıklama |
| --- | --- | --- |
| `--url` | (sorulur) | Jenkins adresi |
| `--name` | hostname | Jenkins'teki node adı |
| `--secret-file` | | Secret'ın okunacağı dosya. Alternatif: `JENKINS_SECRET` ortam değişkeni |
| `--install-dir` | `/opt/jenkins-agent` | `agent.jar` ve indirilen Java'nın yeri |
| `--work-dir` | `/var/lib/jenkins-agent` | Agent çalışma dizini |
| `--user` | `jenkins` | Servisin çalışacağı kullanıcı; yoksa sistem kullanıcısı olarak oluşturulur |
| `--java-home` | | Mevcut Java (JAVA_HOME, `bin` dizini veya `java` yolu) |
| `--java-version` | `25` | İndirilecek Temurin sürümü |
| `--trusted-cert-sha256` | | Sistemin güvenmediği sertifikanın SHA-256 parmak izi; eşleşirse sormadan sabitlenir (`truststore.p12`) |
| `--skip-certificate-check` | | Sertifika kontrolünü kapatır (güvensiz); sormaz |
| `--non-interactive` | | Soru sormaz |
| `-y`, `--yes` | | Onay sorularına evet der |
| `--uninstall` | | Kurulumu kaldırır |

Soru sormadan kurulum:

```bash
sudo JENKINS_SECRET=<secret> ./install-jenkins-agent.sh --url https://jenkins.example.com/ --name build-01 --non-interactive
```

Secret'ı komut satırında vermek yerine `--secret-file` kullanmak daha güvenlidir; komut satırı ve shell
geçmişi başka kullanıcılar tarafından görülebilir.

### Java

Java verilmezse Adoptium API'den makinenin mimarisine (x64 veya aarch64) uygun Temurin JRE (yoksa JDK)
`tar.gz` olarak indirilir ve `<install-dir>/java` altına açılır. İsterseniz mevcut bir Java yolu da
girebilirsiniz. Her durumda sürümün 17 veya üstü olduğu kontrol edilir.

### Kurulum adımları

| Adım | Not |
| --- | --- |
| 1/9 Jenkins adresi | `https` ise sertifika sistem deposuna göre kontrol edilir |
| 2/9 Agent adı | Varsayılan: hostname |
| 3/9 Dizinler | Kurulum ve çalışma dizinleri |
| 4/9 Sertifika | Güvenilmiyorsa menü açılır (bkz. [HTTPS sertifikası](#https-sertifikası)); güvenilirse sadece bilgi verilir |
| 5/9 Kullanıcı | Yoksa sistem kullanıcısı olarak oluşturulur |
| 6/9 Java | Java seçilir ve kontrol edilir; sabitleme seçildiyse `truststore.p12` bu adımda yazılır |
| 7/9 agent.jar | İndirilir (sabitlenmiş sertifika ile ya da kontrol kapalıysa `-k` ile); dosya varsa güncelleme sorulur |
| 8/9 Secret | Ekranda gösterilmeden okunur ve `/etc/jenkins-agent/<name>.secret` dosyasına yazılır |
| 9/9 systemd servisi | Unit yazılır, etkinleştirilir ve başlatılır |

### systemd servisi

- Unit dosyası: `/etc/systemd/system/jenkins-agent-<name>.service`
- `User=<user>`, `WorkingDirectory=<work-dir>`, `Restart=always`, `RestartSec=10`
- Komut: `java -jar agent.jar -url ... -name ... -secret @/etc/jenkins-agent/<name>.secret -webSocket -workDir ...`
  Sertifika sabitlendiyse komuta truststore parametreleri, kontrol kapatıldıysa `-noCertificateCheck` eklenir
  (bu durumda her başlatmada WARN yazılır).
- Servis etkinleştirilir ve başlatılır.

```bash
systemctl status jenkins-agent-build-01
journalctl -u jenkins-agent-build-01 -f
```

### Kaldırma

```bash
sudo ./install-jenkins-agent.sh --uninstall --name build-01
```

Servisi durdurur, unit ve secret dosyasını siler, kurulum dizininin silinip silinmeyeceğini sorar.
Çalışma dizini ve kullanıcı silinmez.

### Test

```bash
bash linux/install-jenkins-agent.sh --self-test
```

## Güvenlik notları

- Secret hiçbir zaman zamanlanmış görevin ya da systemd servisinin komut satırına yazılmaz. Agent'a
  `-secret @<dosya>` ile dosya yolu verilir.
- Windows: `secret.txt` dosyasında yetki mirası kapatılır; sadece `SYSTEM`, `Administrators` ve görev hesabı
  erişebilir. `start-agent.ps1`, `agent.jar` ve indirilen Java klasörü de aynı şekilde kısıtlanır (görev
  hesabı sadece okuyup çalıştırabilir); böylece standart kullanıcılar SYSTEM olarak çalışan dosyaları
  değiştiremez. Kurulum ve çalışma klasörünün kendisi sadece script tarafından oluşturulduysa kısıtlanır;
  var olan bir klasörün yetkilerine dokunulmaz.
- Linux: secret `/etc/jenkins-agent/<name>.secret` dosyasında, sahibi servis kullanıcısı ve izni `600`.
  Kurulum dizini root'a aittir; servis kullanıcısı sadece çalışma dizinine yazabilir.
- Secret etkileşimli modda ekranda gösterilmeden okunur.
- Java ve `agent.jar` HTTPS üzerinden indirilir. İndirilen dosyaların imza kontrolü yapılmaz.
- Sertifika kontrolü kapatılırsa secret, ağı dinleyen biri tarafından ele geçirilebilir. Ayrıntı için bkz.
  [HTTPS sertifikası](#https-sertifikası).

## Yapılan kontroller

Gerçek bir makineye uçtan uca kurulum (görev/servis kaydı ve Jenkins bağlantısı) henüz test edilmedi.
Şu ana kadar yapılanlar:

| Script | Kontrol |
| --- | --- |
| `windows/Install-JenkinsAgent.ps1` | Windows PowerShell 5.1 söz dizimi kontrolü, `windows/tests` altındaki testler |
| `linux/install-jenkins-agent.sh` | `bash -n`, shellcheck, `--self-test` |
