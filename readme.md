# Jenkins Agent Installer

Windows ve Linux makinelere Jenkins inbound agent (webSocket) kurulumu yapan scriptler.

Script şunları yapar:

- Java'yı hazırlar: Eclipse Temurin indirir ya da mevcut bir Java'yı kullanır (sürüm 17 ve üstü zorunlu)
- Jenkins sunucusundan `agent.jar` dosyasını indirir
- Node secret'ını erişimi kısıtlanmış bir dosyaya yazar
- Agent'ı sistem açılışında başlayacak ve düşerse tekrar ayağa kalkacak şekilde kaydeder
  (Windows: zamanlanmış görev, Linux: systemd servisi)

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
- Linux: systemd, bash, `curl` veya `wget`, `tar`, root yetkisi (veya sudo).
- Java'yı script indirecekse `api.adoptium.net` ve `github.com` adreslerine erişim.

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
| `-Force` | | Onay sorularına evet der |
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
| 1/8 | Jenkins URL | `http://` veya `https://` ile başlamalı, sonuna `/` eklenir |
| 2/8 | Agent adı | Varsayılan bilgisayar adı |
| 3/8 | Kurulum ve çalışma klasörü | Yoksa oluşturulur |
| 4/8 | Görev hesabı | `SYSTEM` veya kullanıcı hesabı (parola sorulur) |
| 5/8 | Java | Aşağıya bakın |
| 6/8 | `agent.jar` | `<JenkinsUrl>/jnlpJars/agent.jar` adresinden indirilir; dosya varsa güncelleme sorulur |
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

### systemd servisi

- Unit dosyası: `/etc/systemd/system/jenkins-agent-<name>.service`
- `User=<user>`, `WorkingDirectory=<work-dir>`, `Restart=always`, `RestartSec=10`
- Komut: `java -jar agent.jar -url ... -name ... -secret @/etc/jenkins-agent/<name>.secret -webSocket -workDir ...`
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

## Yapılan kontroller

Gerçek bir makineye uçtan uca kurulum (görev/servis kaydı ve Jenkins bağlantısı) henüz test edilmedi.
Şu ana kadar yapılanlar:

| Script | Kontrol |
| --- | --- |
| `windows/Install-JenkinsAgent.ps1` | Windows PowerShell 5.1 söz dizimi kontrolü, `windows/tests` altındaki testler |
| `linux/install-jenkins-agent.sh` | `bash -n`, shellcheck, `--self-test` |
