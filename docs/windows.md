# Windows kurulum kılavuzu

Bu belge `windows/Install-JenkinsAgent.ps1` scriptinin ayrıntılı kullanımını anlatır. Genel bakış ve
dosya listesi için [readme.md](../readme.md), Linux için [Linux kılavuzu](linux.md) dosyasına bakın.

Örneklerdeki `jenkins.example.com`, `build-01`, `CORP\svc-jenkins` gibi değerler yer tutucudur;
kendi değerlerinizle değiştirin. `<secret>`, `<sha256>` gibi işaretleri de gerçek değerlerle değiştirin.

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
| İşletim sistemi | Windows 10, Windows 11, Windows Server 2016 ve üstü |
| PowerShell | Windows PowerShell 5.1 (`powershell.exe`). Script PowerShell 7 ile test edilmedi. |
| Yetki | Yönetici. Pencere yönetici değilse script UAC onayıyla kendini yeni bir pencerede yeniden açar. |
| Java | Sürüm 17 veya üstü. Java 8 ve 11 kabul edilmez. Script Temurin indirebilir ya da mevcut bir JDK/JRE yolu kullanabilir. |
| Ağ (Jenkins) | Makineden Jenkins adresine çıkış (Jenkins'in HTTP/HTTPS portu). Agent WebSocket ile bağlanır. |
| Ağ (indirme) | Temurin indirilecekse `api.adoptium.net` ve `github.com` erişimi. `agent.jar` Jenkins'in kendi sunucusundan iner. |
| Görev hesabı | `SYSTEM` dışında bir kullanıcı seçilecekse hesabın parolası bilinmeli ve hesapta "Log on as a batch job" hakkı olmalı. |

PowerShell sürümünü kontrol etmek için:

```powershell
$PSVersionTable.PSVersion
```

## 2. Jenkins tarafında node hazırlığı

Script kurulumdan önce Jenkins'te bir node oluşturulmuş olmasını bekler. Menü adları Jenkins sürümüne göre
değişebilir.

1. **Manage Jenkins > Nodes** sayfasında **New Node** ile **Permanent Agent** türünde bir node oluşturun.
2. Node adını yazın (ör. `build-01`). Bu ad, script için `-AgentName` (ya da 2. adımdaki "Agent adı") ile
   birebir aynı olmalıdır. Büyük/küçük harf de dahil.
3. **Remote root directory** alanına çalışma klasörünü yazın (ör. `C:\jenkins`). Script varsayılan olarak
   `C:\jenkins` kullanır; iki değerin aynı olması karışıklığı önler.
4. **Launch method** olarak **Launch agent by connecting it to the controller** seçin.
5. Node'u kaydedin. Node sayfasındaki agent komutunda `-secret` ile verilen değer secret'tır. Kurulum sırasında
   yalnızca bu değer istenir; komutun geri kalanı gerekmez.

Jenkins'te **Jenkins URL** ayarının, agent makinesinden erişilebilen bir adres olması gerekir. `agent.jar`
dosyası `<JenkinsUrl>/jnlpJars/agent.jar` adresinden indirilir.

## 3. Hızlı başlangıç

### 3.1 Tek satır

Yönetici olarak açılmış Windows PowerShell 5.1 penceresinde:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/windows/Install-JenkinsAgent.ps1 | iex
```

Bu komut hiçbir parametre almadan çalışır ve her değeri sorar. Başındaki TLS 1.2 satırı, eski Windows
sürümlerinde GitHub bağlantısının kurulabilmesi için gereklidir.

Parametre vermek için `irm | iex` yerine scriptblock biçimi kullanılır (ayrıntı için
[5.9](#59-irm--iex-ile-parametre-vermek)):

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/windows/Install-JenkinsAgent.ps1))) -JenkinsUrl https://jenkins.example.com/ -AgentName build-01
```

İndirilen scripti çalıştırmadan önce incelemek isterseniz:

```powershell
irm https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/windows/Install-JenkinsAgent.ps1 -OutFile Install-JenkinsAgent.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Install-JenkinsAgent.ps1
```

Pencere yönetici değilse script kendini UAC ile yönetici olarak yeni bir pencerede açar. `irm | iex`
modunda scriptin bir dosyası olmadığı için script önce kendini `%TEMP%` altında rastgele adlı bir klasöre
indirir. Yeni pencereye `-Secret` ve `-RunAsCredential` taşınmaz; bunlar orada yeniden sorulur. `-NonInteractive`
yalnızca `-Secret` de verilmişse taşınmaz. Yeni pencere `-NoExit` ile açılır, iş bitince pencere kapanmaz.

### 3.2 Etkileşimli kurulum, adım adım

Script sekiz adımdan oluşur. Her adımın başında `[n/8]` ile numarası yazılır. Varsayılan değeri olan
sorularda boş Enter varsayılanı kabul eder.

| Adım | Ne sorulur | Varsayılan ve notlar |
| --- | --- | --- |
| 1/8 Jenkins adresi | `Jenkins URL` | Yok, zorunlu. `http://` ya da `https://` ile başlamalı; sonuna `/` eklenir. `https` ise sertifika bu adımda kontrol edilir, karar 3. adımda verilir. |
| 2/8 Agent adı | `Agent (node) adi` | Bilgisayar adı. Yalnızca harf, rakam, `.`, `-`, `_` kullanılır; ilk karakter harf ya da rakam olmalı. |
| 3/8 Klasörler | `Kurulum klasoru`, `Calisma klasoru (workDir)` | `C:\jenkins-agent` ve `C:\jenkins`. Klasör yoksa oluşturulur. Sertifika güvenilmiyorsa sertifika menüsü bu adımda açılır. |
| 4/8 Görev hesabı | `Gorevin calisacagi hesap` | `SYSTEM`. Başka bir hesap yazılırsa parola için bir kimlik bilgisi penceresi açılır. |
| 5/8 Java | Java seçimi (aşağıda) | Varsayılan `1`: Temurin 25 indir. |
| 6/8 agent.jar | `agent.jar zaten var, guncellensin mi?` (dosya varsa) | Varsayılan Evet. Sabitleme seçildiyse `truststore.p12` bu adımda yazılır. |
| 7/8 Secret | `Secret` (ekranda gösterilmez) | Mevcut `secret.txt` varsa `Mevcut secret dosyasi kullanilsin mi?` sorulur, varsayılan Evet. |
| 8/8 Zamanlanmış görev | Soru yok | Görev oluşturulur, başlatılır ve durumu 5 saniye sonra gösterilir. |

5. adımdaki Java seçimi:

```text
1) Temurin 25 indir (onerilen)
2) Java klasor yolunu yaz
3) Java klasorunu pencereden sec
```

- **1 (indir):** Adoptium API'den Temurin JRE indirilir (JRE yoksa JDK) ve `<kurulum klasoru>\java` altına açılır.
- **2 (yol yaz):** JAVA_HOME klasörü, `bin` klasörü ya da doğrudan `java.exe` yolu girilir.
- **3 (pencereden seç):** Klasör seçme penceresi açılır. Pencere açılamazsa (ör. Server Core) yol elle sorulur.

Her seçenekte `java -version` çalıştırılır ve ana sürüm 17 ya da üstü değilse kurulum durur. Ağ (UNC) yolları
kabul edilmez.

Kurulum sonunda şuna benzer bir özet çıkar:

```text
[8/8] Zamanlanmis gorev
  Gorev: JenkinsAgent-build-01  Durum: Running  Son sonuc: 0x41301
  Agent java sureci calisiyor.

Kurulum tamamlandi.
  Wrapper logu : C:\jenkins-agent\agent.log
  Remoting logu: C:\jenkins\remoting\logs
```

`Son sonuc: 0x41301` değeri görev hâlâ çalışıyor demektir. Agent Jenkins'e bağlandığında node sayfasında
"online" görünür.

## 4. Parametreler

| Parametre | Varsayılan | Açıklama |
| --- | --- | --- |
| `-JenkinsUrl` | (sorulur) | Jenkins adresi, ör. `https://jenkins.example.com/` |
| `-AgentName` | bilgisayar adı (`$env:COMPUTERNAME`) | Jenkins'teki node adı. Harf, rakam, `.`, `-`, `_` |
| `-Secret` | (gizli olarak sorulur) | Node secret değeri |
| `-InstallDir` | `C:\jenkins-agent` | `agent.jar`, Java, secret, wrapper ve `agent.log` dosyalarının klasörü |
| `-WorkDir` | `C:\jenkins` | Agent çalışma klasörü (agent'a `-workDir` olarak verilir) |
| `-JavaMode` | `Download` | `Download`, `Path` veya `Browse` |
| `-JavaHome` | (boş) | Mevcut Java yolu (JAVA_HOME, `bin` klasörü ya da `java.exe`). Verilirse mod `Path` olur. |
| `-JavaVersion` | `25` | `Download` modunda indirilecek Temurin sürümü |
| `-RunAs` | `SYSTEM` | Görevin çalışacağı hesap, ör. `CORP\svc-jenkins` |
| `-RunAsCredential` | (boş) | `-RunAs` bir kullanıcıysa parolası (`Get-Credential` ile alınır). Verilirse hesap adı oradan alınır. |
| `-NonInteractive` | kapalı | Soru sormaz; verilmeyen değerler için varsayılan kullanılır |
| `-Force` | kapalı | Onay sorularına (agent.jar güncelleme, mevcut secret kullanımı, klasör silme) evet der. Sertifika sorularına demez. |
| `-TrustedCertThumbprint` | (boş) | Windows'un doğrulayamadığı Jenkins sertifikasının SHA-256 parmak izi. Eşleşirse sormadan sabitlenir. |
| `-SkipCertificateCheck` | kapalı | Jenkins sertifikası hiç doğrulanmaz. Uyarı yazılır, onay sorulmaz. Güvensiz. |
| `-Uninstall` | kapalı | Kurulumu kaldırır (bkz. [8](#8-kaldırma)) |

Parametre adları büyük/küçük harf duyarsızdır.

## 5. Parametreyle ve sormadan kurulum

Aşağıdaki örneklerde tüm komutlar yönetici PowerShell penceresinde, scriptin bulunduğu klasörde çalıştırılır.
Script dosyası yoksa [5.9](#59-irm--iex-ile-parametre-vermek) bölümündeki biçimi kullanın.

### 5.1 Secret'ı dosyadan vermek

`-Secret` değerini düz metin olarak yazmak yerine, secret'ı dosyadan okuyun. Komut geçmişinde yalnızca dosya
yolu kalır.

Secret dosyasını bir kez oluşturun:

```powershell
New-Item -ItemType Directory -Path C:\secure -Force | Out-Null
Set-Content -Path C:\secure\build-01.secret -Value '<secret>' -NoNewline
```

Bu dosyanın yetkilerini de kısıtlayın (ör. yalnızca Administrators ve kendi hesabınız okuyabilsin). Kurulum
sonrasında bu dosyayı silebilirsiniz; agent'ın secret'ı kendi `secret.txt` dosyasından okur.

Kurulum:

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -Secret (Get-Content -Raw 'C:\secure\build-01.secret') -NonInteractive
```

### 5.2 Domain makinesi, sertifika Windows'ta güvenilir, SYSTEM

Jenkins sertifikası kurumun kök CA'sıyla imzalıysa ve bu CA Windows sertifika deposunda ise sertifika sorusu
çıkmaz. Varsayılanlar: Temurin 25 indirilir, görev `SYSTEM` ile çalışır.

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -JavaMode Download -NonInteractive -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

### 5.3 Temurin indir ya da mevcut Java

Temurin indirme (varsayılan sürüm 25, farklı sürüm için `-JavaVersion`):

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -JavaMode Download -JavaVersion 21 -NonInteractive -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

Mevcut bir JDK kullanmak (`-JavaHome` verildiğinde `-JavaMode` gerekmez):

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -JavaHome 'C:\Program Files\Eclipse Adoptium\jdk-21.0.5.11-hotspot' -NonInteractive -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

Java yolu verilip `-NonInteractive` kullanılmazsa ve yol geçersizse script yeni yol sorar. `-NonInteractive`
ile geçersiz yol verilirse kurulum hata verip durur.

`keytool.exe` yolun `bin` klasöründe olmalıdır. Sabitleme kullanılacaksa, JDK'nın yerine yalnızca çalışma
zamanı içeren bir kopya verilirse `keytool bulunamadi` hatası alınabilir.

### 5.4 Domain servis hesabı ile çalıştırma

Görev `SYSTEM` yerine bir domain hesabıyla çalışacaksa parola gerekir. Parola komut satırına yazılmaz;
`Get-Credential` ile alınır:

```powershell
$cred = Get-Credential -UserName 'CORP\svc-jenkins' -Message 'Zamanlanmis gorev parolasi'
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -RunAs 'CORP\svc-jenkins' -RunAsCredential $cred -NonInteractive -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

Notlar:

- `-RunAsCredential` verilirse hesap adı oradan alınır, `-RunAs` değeri yok sayılır.
- `-RunAs` verilip `-RunAsCredential` verilmezse ve `-NonInteractive` kullanılmıyorsa parola penceresi açılır.
  `-NonInteractive` ile bu durumda kurulum hata verir.
- Hesabın "Log on as a batch job" hakkı olmalıdır (Yerel İlke / Group Policy).
- Hesap, kurulum ve çalışma klasörlerine okuma/yazma erişimine sahip olmalıdır. Bunun neden önemli olduğu için
  [7.3](#73-hesap-değiştirme) bölümüne bakın.
- Otomasyon için scripti yönetici olarak açılmış bir oturumda çalıştırın. Yönetici olmayan bir oturumda
  script yeni pencere açar ve `-RunAsCredential` taşınmadığı için parola yeniden sorulur.

### 5.5 Sabitlenmiş sertifika (parmak izi ile)

Windows'un güvenmediği bir Jenkins sertifikasını parmak iziyle sabitlemek için SHA-256 değerini alın
([6.3](#63-parmak-izini-alma)). Eşleşirse script sormadan sabitler:

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -TrustedCertThumbprint <sha256> -NonInteractive -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

Parmak izi iki nokta, boşluk ya da tire ile ayrılmış biçimde de verilebilir; `AB:CD:..` ve `abcd..` aynı kabul edilir.
64 hane hex değilse kurulum hata verir. Eşleşmezse de hata verir; bu durumda sunucunun sertifikası değişmiş
ya da yanlış bir adres kullanılıyordur.

### 5.6 Sertifika kontrolünü kapatmak

Yalnızca başka seçenek kalmadığında kullanın (bkz. [6.5](#65-kontrolü-kapatmak-güvensiz)):

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -SkipCertificateCheck -NonInteractive -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

Bu modda agent `-noCertificateCheck` ile başlar ve her başlatmada `agent.log` dosyasına WARN yazılır.

### 5.7 Özel kurulum ve çalışma klasörü

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -InstallDir 'D:\jenkins\agent' -WorkDir 'D:\jenkins\work' -NonInteractive -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

- Ağ (UNC, `\\sunucu\paylasim`) yolları kabul edilmez.
- Yollarda boşluk varsa tırnak kullanın.
- Mevcut bir klasör verilirse onun izinlerine dokunulmaz (bkz. [7.3](#73-hesap-değiştirme)).

### 5.8 Tüm adımları atlayıp yalnızca onaylamak

Yeniden çalıştırırken agent.jar ve secret sorularını kendiliğinden evet yanıtlamak için `-Force` kullanılır:

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -NonInteractive -Force
```

`-Force` mevcut secret dosyasını da yeniden kullanır. Yeni bir secret yazmak için `-Secret` verin.
`-Force` sertifika sorularında evet demez; sertifika için `-TrustedCertThumbprint` ya da
`-SkipCertificateCheck` gerekir.

### 5.9 irm | iex ile parametre vermek

`irm ... | iex` ile parametre geçirilemez. Parametreler için scriptblock biçimi kullanılır:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/windows/Install-JenkinsAgent.ps1))) -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -NonInteractive -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

Aynı biçim sertifika parametreleri için de geçerlidir:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/windows/Install-JenkinsAgent.ps1))) -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -TrustedCertThumbprint <sha256> -NonInteractive -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

Parametresiz `irm | iex` çalıştırılırsa, sertifika kararı da dahil olmak üzere her şey etkileşimli sorulur.

## 6. HTTPS sertifikası

Jenkins adresi `https://` ile başlıyorsa script sunucu sertifikasını, makinenin Windows sertifika deposuna göre
kontrol eder. Sertifika güvenilirse hiçbir soru sorulmaz ve Java `Windows-ROOT` deposunu kullanır.

### 6.1 Modlar

| Mod | Ne zaman | Agent'a etkisi |
| --- | --- | --- |
| `Windows` | Sertifika Windows tarafından doğrulandı | Java `-Djavax.net.ssl.trustStoreType=Windows-ROOT` ile başlar. Ek parametre yok. |
| `Pinned` | Sertifika doğrulanamadı, kullanıcı sabitlemeyi seçti (ya da parmak izi verildi) | Kurulum klasöründeki `truststore.p12` (`jenkins-ca` takma adıyla) kullanılır. Sistem deposuna dokunulmaz. |
| `Insecure` | Kullanıcı kontrolü kapattı (ya da `-SkipCertificateCheck`) | `-noCertificateCheck` ile başlar, her başlatmada WARN yazılır. |

### 6.2 Sertifika menüsü

Sertifika doğrulanamazsa script önce sertifikayı gösterir, sonra menüyü açar (Windows'ta 3/8 adımında):

```text
  Jenkins sertifikasi Windows tarafindan dogrulanamadi (...).
  Konu       : CN=jenkins.example.com, ...
  Veren      : CN=Kurum Ara CA, ...
  Gecerlilik : 2025-01-01 - 2027-01-01
  SHA-256    : 0123...ABCD
  1) Sertifikayi sabitle (onerilen)
  2) Sertifika kontrolunu kapat (guvensiz)
  3) Iptal
  Secim [1]:
```

- **1 (sabitle):** Onay sorulur (`Bu sertifikaya guvenilsin mi? [e/H]`). Onaylanırsa sertifika `truststore.p12`
  dosyasına yazılır. Onay vermezseniz kurulum iptal edilir.
- **2 (kapat):** Uyarı yazılır ve ayrıca onay sorulur. Onay vermezseniz kurulum iptal edilir.
- **3 (iptal):** Kurulum durur.

Sertifika zinciri süresi geçmiş, henüz geçerli değil veya bozuksa sabitleme sunulmaz; menüde yalnızca 2 ve 3
kalır (varsayılan 3). Sertifikayı Jenkins tarafında yenileyin. Bu durumda `-TrustedCertThumbprint` de kabul
edilmez; kurulum hata verip durur.

Adres ile sertifikadaki ad eşleşmiyorsa (`NameMismatch`) menü hiç açılmaz, kurulum bir hata mesajıyla durur.
Sabitleme bunu çözmez; doğru adresi kullanın. Kontrol kapatılacaksa `-SkipCertificateCheck` gerekir.

### 6.3 Parmak izini alma

Parmak izi menüdeki `SHA-256` satırında görünür. Menüde görünen değer, sunucunun o anda sunduğu sertifikanın
parmak izidir. Sabitlemeden önce Jenkins yöneticisiyle karşılaştırın; aksi halde araya girmiş birinin
sertifikasını sabitlemiş olabilirsiniz.

Menüden bağımsız olarak, aynı değeri PowerShell ile almak için:

```powershell
$HostName = 'jenkins.example.com'
$tcp = New-Object System.Net.Sockets.TcpClient($HostName, 443)
try {
    $accept = [System.Net.Security.RemoteCertificateValidationCallback] { param($s, $c, $ch, $e) $true }
    $ssl = New-Object System.Net.Security.SslStream($tcp.GetStream(), $false, $accept)
    $ssl.AuthenticateAsClient($HostName)
    $leaf = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList $ssl.RemoteCertificate
    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chain.Build($leaf) | Out-Null
    $top = $chain.ChainElements[$chain.ChainElements.Count - 1].Certificate
    $hash = [Security.Cryptography.SHA256]::Create().ComputeHash($top.RawData)
    'SHA-256: ' + ([BitConverter]::ToString($hash) -replace '-', '')
    'Konu   : ' + $top.Subject
} finally {
    $tcp.Close()
}
```

Script, zincirin en üstündeki sertifikanın parmak izini sabitler (kök CA, zincirde yoksa sitenin kendi
sertifikası). Yukarıdaki kod da aynı sertifikayı seçer. Sonuç menüdeki değerle aynı olmalıdır; farklıysa menüdeki
değeri esas alın.

Bu snippet doğrudan TCP bağlantısı açar ve sistem proxy'sini kullanmaz. Proxy zorunluysa menüdeki
SHA-256 değerini esas alın (bkz. [6.6](#66-proxy-notu)).

### 6.4 Kurumsal kök CA'yı Windows'a yüklemek (önerilen)

En temiz çözüm, kurumun kök CA sertifikasını makinenin güvenilen kök deposuna eklemektir. Bundan sonra Windows
sertifikayı doğrular, Java da `Windows-ROOT` üzerinden aynı kararı verir:

```powershell
Import-Certificate -FilePath C:\certs\kurum-kok-ca.cer -CertStoreLocation Cert:\LocalMachine\Root
```

Ardından scripti yeniden çalıştırın; sertifika artık "Windows tarafından doğrulandı" olarak görünür.
Dağıtımı domain GPO ile yapmak da mümkündür.

### 6.5 Kontrolü kapatmak (güvensiz)

Kontrol kapatıldığında ağı dinleyen biri Jenkins gibi davranıp agent secret'ını ele geçirebilir ve agent'a
iş (kod) gönderebilir. Tercih sırası şöyledir:

1. Kurum kök CA'sını Windows deposuna yüklemek (6.4).
2. Parmak izi ile sabitlemek (`-TrustedCertThumbprint`).
3. Kontrolü kapatmak (`-SkipCertificateCheck`) son çaredir.

Kapatılırsa agent `-noCertificateCheck` ile çalışır ve `agent.log` dosyasına her başlatmada uyarı yazılır.

### 6.6 Proxy notu

Java sistem proxy'sini kullanmaz; script ise `DefaultWebProxy` üzerinden kontrol yapar. Araya TLS inceleyen
bir proxy varsa script'in gördüğü sertifika ile agent'in göreceği sertifika farklı olabilir ve sabitleme
eşleşmez. Script, sistem proxy'si tanımlıysa ve sertifika doğrulanamadıysa bu konuda uyarır. Bu durumda
proxy'nin kök CA'sını kurulum öncesi Windows deposuna yüklemek gerekir.

### 6.7 Yeniden çalıştırmada sertifika

- Aynı sertifika zaten sabitliyse (truststore içindeki parmak izi eşleşiyorsa) mevcut `truststore.p12` kullanılır
  ve soru sorulmaz.
- Sabitleme modu değişirse eski `truststore.p12` silinir. Sabitlemeden kontrol kapatmaya ya da tersine
  geçişte geçerlidir.
- Kök CA sabitlendiyse yalnızca CA değiştiğinde, sitenin kendi sertifikası sabitlendiyse sertifika
  yenilendiğinde script yeniden çalıştırılmalıdır. Aksi halde agent Jenkins'e bağlanamaz.

## 7. Yeniden çalıştırma ve güncelleme

Script aynı `-AgentName` ile tekrar çalıştırıldığında mevcut kurulumu günceller. Aynı isimdeki görev silinip
yeniden oluşturulur.

### 7.1 Ne yeniden kullanılır, ne değişir

| Öğe | Yeniden çalıştırmada |
| --- | --- |
| `agent.jar` | Sorulur (varsayılan Evet). `-NonInteractive` ya da `-Force` ile güncellenir. Hayır denirse mevcut dosya kullanılır. |
| Java | Yeniden seçilir. `Download` modunda aynı sürüm klasörü zaten varsa yeniden indirilmez, mevcut klasör kullanılır. |
| Secret (`secret.txt`) | `-Secret` verilirse yeni değer yazılır. Verilmezse ve dosya varsa `Mevcut secret dosyasi kullanilsin mi?` sorulur (varsayılan Evet). `-NonInteractive` ve `-Force` mevcut dosyayı kullanır. |
| `truststore.p12` | Aynı sertifika ise yeniden kullanılır. Değişmişse ya da mod değişmişse yeniden yazılır ya da silinir. |
| `start-agent.ps1` | Her seferinde yeniden üretilir. |
| Zamanlanmış görev | Silinip yeniden oluşturulur. |
| Kurulum ve çalışma klasörü | Varsa olduğu gibi kalır; izinleri değiştirilmez. |

Güncelleme sırasında çalışan agent durdurulur. Script önce görevi siler, sonra bu agent'a ait `java.exe`
süreçlerini sonlandırır, sonra `agent.jar`'ı indirir ve görevi yeniden kaydeder.

### 7.2 Güncelleme komutu

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -NonInteractive -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

Secret değişmediyse `-Secret` vermeden `-NonInteractive -Force` yeterlidir.

Önemli: Script, mevcut agent'ı 5/8 adımının sonunda durdurur ve görevi siler. Bundan sonra (6/8, 7/8, 8/8)
bir hata çıkarsa agent kapalı ve görev silinmiş kalır. Hatayı düzeltip aynı komutu tekrar çalıştırmak yeterlidir.
5/8'e kadar olan hatalar (hesap, klasör, sertifika, Java) mevcut agent'a dokunmaz.

### 7.3 Hesap değiştirme

Görev hesabı değiştirilirken (ör. `SYSTEM` yerine `CORP\svc-jenkins`) mevcut klasörlerin izinleri
**değiştirilmez**: script bu klasörleri yalnızca kendisi oluşturduysa kısıtlar. Mevcut `agent.jar`,
`start-agent.ps1` ve `secret.txt` ise her çalıştırmada yeni hesap için yeniden yetkilendirilir.

Hesap değişiminden sonra şunları kontrol edin:

- Kurulum klasörü ve çalışma klasörü (`C:\jenkins`) yeni hesap tarafından yazılabilmeli (`agent.log` ve remoting
  logu için).
- `Download` modunda kullanılan `<kurulum klasörü>\java` klasörü yeni hesap tarafından okunup çalıştırılabilmeli.
  Bu klasör ilk kurulumda `SYSTEM` için oluşturulduysa izinleri otomatik değişmez.

Bu kontrol yapılmadan gelen "Access denied" hatalarında klasör izinlerini ayarlayın ya da klasörleri silip
kurulumu yeniden çalıştırın.

### 7.4 Java değiştirme

Yeni bir Java'ya geçmek için kurulumu yeniden çalıştırıp 5/8 adımında yeni yolu verin:

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -JavaHome 'C:\Program Files\Eclipse Adoptium\jdk-21.0.5.11-hotspot' -NonInteractive -Force
```

Eski Java klasörü otomatik silinmez.

### 7.5 Secret değiştirme

Jenkins'te secret yenilenmişse (ör. node silinip yeniden oluşturulduysa):

```powershell
.\Install-JenkinsAgent.ps1 -JenkinsUrl https://jenkins.example.com/ -AgentName build-01 -NonInteractive -Force -Secret (Get-Content -Raw 'C:\secure\build-01.secret')
```

### 7.6 Sertifika modunu değiştirme

Modlar arasında geçiş için yeniden çalıştırın ve yeni kararı verin. Örnekler:

- Sabitlemeden kontrol kapatmaya: `-SkipCertificateCheck` ile çalıştırın. Eski `truststore.p12` silinir.
- Kontrol kapalıyken sabitlemeye: `-TrustedCertThumbprint <sha256>` ile çalıştırın.
- Kök CA Windows deposuna eklendiyse hiçbir parametre gerekmez; sertifika `Windows` modunda doğrulanır.

## 8. Kaldırma

```powershell
.\Install-JenkinsAgent.ps1 -Uninstall -AgentName build-01
```

Bu komut şunları yapar:

1. `JenkinsAgent-build-01` görevini durdurur ve siler.
2. Bu agent'a ait `java.exe` süreçlerini sonlandırır (komut satırında `agent.jar` ve `-name build-01` geçenler).
3. Kurulum klasörünün (`C:\jenkins-agent`) silinip silinmeyeceğini sorar. Varsayılan Hayır.

Sormadan silmek için:

```powershell
.\Install-JenkinsAgent.ps1 -Uninstall -AgentName build-01 -InstallDir 'C:\jenkins-agent' -NonInteractive -Force
```

Silinen klasör, Java klasörünü de içerir. Kurulum klasörü `-InstallDir` ile verilmemişse varsayılan
`C:\jenkins-agent` kullanılır; farklı bir klasör kullandıysanız aynı değeri verin.

Çalışma klasörü (`C:\jenkins`) silinmez. İçindeki remoting logları ve workspace'ler kendiniz temizleyin.

Uninstall için de yönetici yetkisi gerekir; pencere yönetici değilse script yeniden açılır.

`irm | iex` ile kaldırmak için:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/windows/Install-JenkinsAgent.ps1))) -Uninstall -AgentName build-01 -NonInteractive -Force
```

## 9. İşletim: durum, loglar, yeniden başlatma

### 9.1 Görev durumu

```powershell
Get-ScheduledTask -TaskName 'JenkinsAgent-build-01' | Select-Object TaskName, State
Get-ScheduledTask -TaskName 'JenkinsAgent-build-01' | Get-ScheduledTaskInfo | Select-Object LastRunTime, LastTaskResult, NextRunTime
```

- `State` görev o an çalışıyorsa `Running` gösterir. Wrapper agent'ı ön planda çalıştırdığı için agent
  yaşadığı sürece görev `Running` kalır.
- `LastTaskResult` son çalıştırmanın çıkış kodudur. `0` başarılıdır. Agent kapandıktan sonra görev bitince
  bu değer agent'ın son çıkış kodunu tutar.

### 9.2 Java süreçleri

Bu agent'a ait java süreçlerini görmek için:

```powershell
Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
    Where-Object { $_.CommandLine -match 'agent\.jar' } |
    Select-Object ProcessId, CommandLine | Format-List
```

Bir agent için beklenen süreç sayısı 1'dir. Birden fazlaysa bkz. [10.6](#106-aynı-adla-iki-agent).

### 9.3 Loglar

| Log | Konum | İçerik |
| --- | --- | --- |
| Wrapper logu | `C:\jenkins-agent\agent.log` | Başlatma (`START`), çıkış kodu (`EXIT`), uyarılar (`WARN`), hatalar (`ERROR`). 1 MB'ı geçince son 200 satır tutulur. |
| Remoting logu | `C:\jenkins\remoting\logs\` | Agent'ın kendi logları: Jenkins'e bağlantı, WebSocket, TLS (PKIX) hataları. |

Son wrapper kayıtlarını görmek için:

```powershell
Get-Content -LiteralPath 'C:\jenkins-agent\agent.log' -Tail 50
```

Remoting logunun en yenisini görmek için:

```powershell
$log = Get-ChildItem -LiteralPath 'C:\jenkins\remoting\logs' -File | Sort-Object LastWriteTime | Select-Object -Last 1
Get-Content -LiteralPath $log.FullName -Tail 100
```

Java'nın konsol çıktısı (`System.err` dahil) `agent.log`'a yazılmaz; görev bu çıktıyı yakalamaz. Bağlantı
hataları için remoting loguna bakın.

### 9.4 Yeniden başlatma

Agent'ı yeniden başlatmak için yalnızca görevi durdurmak yetmez; görevin başlattığı `java.exe` süreci ayrıca
sonlandırılmalıdır. Aksi halde agent çalışmaya devam eder.

```powershell
Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
    Where-Object { $_.CommandLine -match 'agent\.jar' -and $_.CommandLine -match '-name\s+build-01(\s|$)' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

Java süreci kapandığında wrapper çıkar, görev bir dakika içinde (tetikleyici dakikada bir çalıştığı için)
yeniden başlar. Hemen başlatmak için:

```powershell
Start-ScheduledTask -TaskName 'JenkinsAgent-build-01'
```

Görev yalnızca çalışmıyorsa başlar; agent zaten çalışıyorsa wrapper yeni bir süreç açmaz.

### 9.5 Sistem yeniden başlatıldığında

Görev **AtStartup** tetikleyicisiyle çalışır. Bilgisayar yeniden başladığında agent, kullanıcı oturum açmadan
başlar.

## 10. Sorun giderme

### 10.1 `irm | iex` sözdizimi hatası (UTF-8 BOM)

Belirti: `irm | iex` ayrıştırma (parse) hatası verir ve script hiç çalışmaz. Sebep, eski sürümün başındaki
UTF-8 BOM işaretidir. BOM kaldırıldı; hata görüyorsanız GitHub önbelleğinde ya da makinenizdeki bir kopyada
eski sürüm olabilir.

Çözüm: scripti commit sabit adresinden alın. Ya da bir süre bekleyip tekrar deneyin:

```powershell
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; irm https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/<commit>/windows/Install-JenkinsAgent.ps1 | iex
```

`<commit>` yerine güncel commit'in kısa ya da tam karmasını yazın.

### 10.2 Agent adında büyük `I` harfi

Eski sürümde Türkçe Windows ayarında (tr-TR kültürü) büyük `I` içeren adlar (ör. `BuildIst`) "Gecersiz agent adi"
hatası veriyordu. Düzeltildi; eski sürümle hata alıyorsanız scripti güncelleyin.

### 10.3 agent.jar kullanımda, güncellenemedi

Belirti:

```text
agent.jar kullanimda, guncellenemedi. agent.jar calistiran java surecleri: PID 4312. Bunlari durdurup (Stop-Process -Id <PID>) tekrar deneyin.
```

Script, bu agent'a ait süreçleri zaten durdurur. Bu hata genellikle farklı bir adla ya da eski yöntemle
(`-jnlpUrl`) başlatılmış bir agent `agent.jar`'ı kilitlediğinde çıkar.

Süreçleri bulun ve durdurun:

```powershell
Get-CimInstance Win32_Process -Filter "Name='java.exe'" |
    Where-Object { $_.CommandLine -match 'agent\.jar' } |
    Select-Object ProcessId, CommandLine | Format-List

Stop-Process -Id 4312 -Force
```

`4312` yerine listedeki PID'yi yazın. Hangi agent'a ait olduğunu komut satırındaki `-name` değerinden anlayın.
Sonra scripti tekrar çalıştırın.

### 10.4 Node offline, `PKIX path building failed`

Belirti: Jenkins'te node offline, remoting logunda şuna benzer bir satır var:

```text
javax.net.ssl.SSLHandshakeException: PKIX path building failed: sun.security.provider.certpath.SunCertPathBuilderException: unable to find valid certification path to requested target
```

Anlamı: Agent'ın Java'sı Jenkins sertifikasının zincirini doğrulayamıyor. Script'in sertifikayı Windows
tarafında güvenilir bulması ile Java'nın güvenmesi aynı şey değildir. Olası nedenler:

- **Sertifika değişti (sabitleme modu).** Jenkins sertifikası yenilendi ya da CA değişti. `truststore.p12`
  eski sertifikayı içerir. Scripti yeniden çalıştırın; script yeni sertifikayı gösterir ve yeniden sorar.
- **Kök CA Windows deposunda yok, ama sabitleme de yapılmadı.** Eski bir kurulumda kontrol kapatılmış ya da
  hiç yapılmamış olabilir. Scripti tekrar çalıştırın ve 6.2 menüsünden karar verin.
- **Ara CA yalnızca Windows deposunda.** Windows zinciri ara CA'yı "Ara Sertifika Yetkilileri" deposundan
  tamamlayabilir, ancak Java'nın `Windows-ROOT` deposu yalnızca kök deposuna bakar. Sunucu ara CA'yı
  göndermiyorsa Java doğrulayamaz. Bu durumda sabitleme (`-TrustedCertThumbprint`) ya da kök CA'yı kök
  deposuna eklemek gerekir. Bu kesin bir teşhis değil, belirtiyle uyuşan bir olasılıktır.
- **Proxy TLS inceliyor.** Agent proxy'yi kullanmaz; gördüğü sertifika script'inkinden farklı olabilir
  (bkz. [6.6](#66-proxy-notu)).

Yapılacaklar sırasıyla: `agent.log` ve remoting logunu kontrol edin, scripti yeniden çalıştırın, menüden
karar verin. Hata sürüyorsa remoting logundaki `Caused by` satırlarının tamamına bakın.

### 10.5 Java'yı elle çalıştırmak

Agent'ın hata ayıklaması için wrapper'ın yaptığı komutu elle çalıştırabilirsiniz. Önce agent'ı durdurun
([9.4](#94-yeniden-başlatma)); aksi halde çakışır.

Sertifika Windows deposuna göre doğrulanıyorsa (`Windows` modu):

```powershell
& 'C:\jenkins-agent\java\<java-klasoru>\bin\java.exe' '-Djavax.net.ssl.trustStoreType=Windows-ROOT' -jar 'C:\jenkins-agent\agent.jar' -url https://jenkins.example.com/ -secret '@C:\jenkins-agent\secret.txt' -name build-01 -webSocket -workDir 'C:\jenkins'
```

Sabitlenmiş sertifikada (`Pinned` modu) `-Djavax.net...` argümanları farklıdır:

```powershell
& 'C:\jenkins-agent\java\<java-klasoru>\bin\java.exe' '-Djavax.net.ssl.trustStore=C:\jenkins-agent\truststore.p12' '-Djavax.net.ssl.trustStoreType=PKCS12' '-Djavax.net.ssl.trustStorePassword=changeit' -jar 'C:\jenkins-agent\agent.jar' -url https://jenkins.example.com/ -secret '@C:\jenkins-agent\secret.txt' -name build-01 -webSocket -workDir 'C:\jenkins'
```

Kontrolü kapalıysa (`Insecure`) komuta `-noCertificateCheck` eklenir. `start-agent.ps1` dosyasındaki `$JavaExe`,
`$TrustMode` gibi değerler, hangi modun kullanıldığını gösterir.

Kurallar:

- `-Djavax.net...` argümanlarını tırnak içine alın. PowerShell tırnaksız noktalı argümanı bozabilir (kodda da
  bu nedenle tek parça string kullanılıyor).
- `@` ile başlayan `-secret` değerini tek tırnak içine alın. Tırnaksız `@` PowerShell'de splatting olarak
  yorumlanabilir.
- `<java-klasoru>` yerine kurulumdaki gerçek klasör adını yazın (ör. `jdk-25.0.1+8-jre`).
- Komut secret'ı dosya yolu olarak alır; secret değerini komut satırına yazmayın.

Ctrl+C ile durdurun. Doğru çalıştığı görülürse agent'ı görev üzerinden tekrar başlatın.

### 10.6 Aynı adla iki agent

Aynı `-name` ile iki `java.exe` çalışırsa Jenkins'te node offline görünebilir. Wrapper bu durumu `agent.log`
dosyasına `WARN` olarak yazar ve yeni süreç başlatmaz.

Süreçlerin tümünü durdurun ([9.4](#94-yeniden-başlatma) komutu ya da 10.3'teki liste), sonra görevi
başlatın. Birini manuel çalıştırdıysanız o süreci sonlandırmanız yeterlidir. İki bağlantı açık kalırsa node
offline görünebilir ya da bağlantı sürekli kopabilir.

### 10.7 GitHub önbelleği

`raw.githubusercontent.com` adresi değişikliği birkaç dakika geç yansıtabilir. Güncel değişikliği görmek için
commit sabit adresini kullanın (bkz. [10.1](#101-irm--iex-sözdizimi-hatası-utf-8-bom)).

### 10.8 Diğer sık hatalar

| Hata | Anlamı ve çözümü |
| --- | --- |
| `Yonetici yetkisi gerekiyor...` | Pencere yönetici değil ve script yeniden açılamadı. PowerShell'i "Yönetici olarak çalıştır" ile açıp tekrar deneyin. |
| `Java surumu 17 veya ustu olmali (bulunan: 11)` | Bulunan Java eski. `-JavaHome` ile daha yeni bir JDK verin ya da `-JavaMode Download` kullanın. |
| `java.exe bulunamadi` | Verilen yol JAVA_HOME, `bin` ya da `java.exe` değil. Yolu kontrol edin. |
| `Ag (UNC) yolu desteklenmiyor` | Kurulum, çalışma ya da Java yolu ağ paylaşımında. Yerel diske taşıyın. |
| `Gecersiz agent adi` | Ad harf, rakam, `.`, `-`, `_` dışında karakter içeriyor ya da boşlukla başlıyor. |
| `Sertifika -TrustedCertThumbprint ile eslesmiyor` | Verilen parmak izi sunucudakiyle farklı. Değeri Jenkins yöneticisiyle doğrulayın. |
| `Sertifikadaki ad Jenkins adresiyle eslesmiyor` | Adres ile sertifikadaki ad uyuşmuyor. Doğru adresi kullanın. Sabitleme ya da kontrol kapatma bu durumu çözmez. |
| `keytool.exe bulunamadi` | Seçilen Java'da `bin\keytool.exe` yok (ör. yalnızca çalışma zamanı kopyası). Tam JDK ya da Temurin JRE kullanın. |
| `Jenkins'e baglanilamadi` | Jenkins adresine ağ, DNS ya da güvenlik duvarı sorunu var. Tarayıcıdan ya da `Test-NetConnection jenkins.example.com -Port 443` ile kontrol edin. |
| `... verilmedi (-NonInteractive modunda parametre olarak verin).` | `-NonInteractive` ile eksik bir değer var. Parametreyi ekleyin. |
| `-Secret verilmedi ve mevcut secret dosyasi yok.` | `-NonInteractive` ile ilk kurulum secret olmadan yapılamaz. |

## 11. Güvenlik notları

- Secret, zamanlanmış görevin komut satırına yazılmaz. Wrapper, agent'a `-secret @C:\jenkins-agent\secret.txt`
  biçiminde dosya yolu verir.
- `secret.txt` dosyasında kalıtım kapatılır; yalnızca `SYSTEM`, `Administrators` ve görev hesabı erişebilir.
- `start-agent.ps1`, `agent.jar` ve Temurin klasörü de kısıtlanır. Görev hesabı yalnızca okuyup çalıştırabilir.
  Standart kullanıcılar `SYSTEM` olarak çalışan dosyaları değiştiremez.
- `-Secret` ile verilen değer PowerShell geçmişinde (PSReadLine geçmiş dosyası dahil) kalır. Komut satırına
  yazmak yerine `Get-Content` ile dosyadan verin ya da etkileşimli soruya cevap verin.
- Sertifika kontrolünü kapatmak, agent'ı ağdaki herhangi bir sahte Jenkins'e açar. Son çare olarak kullanın.
- Java ve `agent.jar` HTTPS ile indirilir. İndirilen dosyaların imza kontrolü yapılmaz.
- Görev hesabının parolası Görev Zamanlayıcı tarafından saklanır ve düz metin dosyaya yazılmaz. Yine de bu
  hesabın yetkilerini en aza indirin.
