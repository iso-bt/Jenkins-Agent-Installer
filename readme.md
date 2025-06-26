---

# 🧩 Jenkins Agent Setup Utility

Kurumsal ortamlarda **Jenkins Node Agent** kurulumunu otomatikleştirmek ve standartlaştırmak amacıyla geliştirilmiş bir araçtır. Bu proje, hem Windows hem de Linux sistemleri için kullanılabilir hale getirilecek şekilde tasarlanmıştır.

---

## 🚀 Amaç

Bu yardımcı betik, Jenkins ortamında kullanılacak yeni bir **node (agent)** kurulumunu:

- Tek adımda gerçekleştirir
- Gerekli `agent.jar` dosyasını indirir
- Java yolunu doğrular
- Gerekirse ajanı sistem başlangıcında otomatik başlatacak bir **Scheduled Task** oluşturur (Windows)
- Kurulumu hızlı ve güvenli hale getirir

---

## 📂 Desteklenen Platformlar

| Platform | Durum      | Açıklama                                                  |
|----------|------------|-----------------------------------------------------------|
| Windows  | ✅ Aktif   | PowerShell üzerinden tam otomatik kurulum                |
| Linux    | 🛠 Planlı  | Bash veya Python ile destek gelecek (Güncelleme bekleniyor) |

---

## 🪟 Windows Kurulum Adımları

### 1. PowerShell Script’ini İndirin

```powershell
git clone https://github.com/iso-bt/Jenkins-Agent-Installer.git
cd Jenkins-Agent-Installer
````

### 2. Script’i Başlatın (Yönetici olarak)

```powershell
.\Windows-Jenkins-Agent.ps1
```

> **Not:** Script yönetici haklarıyla çalıştırılmalıdır. Aksi takdirde otomatik olarak yönetici olarak yeniden başlatılır.

---

## ⚙️ Kurulum Sırasında Sorulan Bilgiler

Script çalışırken kullanıcıdan aşağıdaki bilgileri girilmesi istenir:

| Soru                     | Açıklama                                                                 |
| ------------------------ | ------------------------------------------------------------------------ |
| Agent Directory          | Ajanın saklanacağı klasör yolu                                           |
| agent.jar URL            | Jenkins controller üzerinden alınacak `agent.jar` dosyasının adresi      |
| Jenkins Controller URL   | Ana Jenkins sunucusunun adresi                                           |
| Work Directory           | Ajanın çalışacağı çalışma dizini                                         |
| Java Path                | Yerel sistemdeki `java.exe` dosyasının tam yolu                          |
| Jenkins Node Secret      | Node oluşturulurken Jenkins UI tarafından sağlanan gizli anahtar         |
| Node Name                | Ajanın Jenkins üzerindeki adı                                            |
| Scheduled Task kurulumu? | Ajanın sistem başlangıcında ve her gün belirli bir saatte çalıştırılması |
| Şimdi başlatılsın mı?    | Kurulum tamamlandıktan sonra ajanın hemen çalıştırılması                 |

---

## 🔐 Güvenlik Notları

* **Node secret** değeri girilirken gizli karakter olarak alınmalıdır. Mevcut versiyon açık alır, bu durum ilerleyen sürümlerde geliştirilecektir.
* `java.exe` yolu **mutlaka yerel bir diskten** verilmelidir. Ağ (UNC) yolları desteklenmez.
* Kurulan Scheduled Task, SYSTEM kullanıcısı altında çalışır. Bu nedenle sadece yetkili kullanıcılar script’i çalıştırmalıdır.

---

## 📝 Linux Desteği (Yakında)

Bu projenin **Linux sürümü** üzerinde aktif olarak çalışılmaktadır. Hedeflenen özellikler:

* `systemd` servisi olarak ajan kurulum desteği
* `cron` entegrasyonu (günlük kontrol ve yeniden başlatma)
* Java doğrulama ve eksik bağımlılıkların otomatik yüklenmesi

> 📌 **Tahmini Yayın Tarihi:** 2025 Q3

---

## 🧪 Test Edilen Ortamlar

| Sistem Versiyonu    | Test Durumu              |
| ------------------- | ------------------------ |
| Windows 10 / 11     | ✅ Tam uyum               |
| Windows Server 2019 | ✅ Tam uyum               |
| Linux (Ubuntu 22+)  | 🔄 Geliştirme aşamasında |

---
