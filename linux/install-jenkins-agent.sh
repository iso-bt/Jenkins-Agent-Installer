#!/usr/bin/env bash
# Jenkins inbound (webSocket) agent kurulumu - Linux (systemd).
#
# Kullanim:
#   bash <(curl -fsSL <raw-url>/linux/install-jenkins-agent.sh)
#   curl -fsSL <raw-url>/linux/install-jenkins-agent.sh | sudo bash -s -- --url https://jenkins.example.com/ --name build-01
#
# Verilmeyen degerler adim adim sorulur. Sorular /dev/tty uzerinden okunur, bu sayede
# script stdin'den (curl | bash) calistirildiginda da soru sorabilir.
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/iso-bt/Jenkins-Agent-Installer/master/linux/install-jenkins-agent.sh"
MIN_JAVA_MAJOR=17
TOTAL_STEPS=9
# Truststore parolasi gizli degildir; PKCS12 icin bir deger gerekir (Java/keytool varsayilani).
TRUSTSTORE_PASS="changeit"

JENKINS_URL=""
AGENT_NAME=""
SECRET_FILE_IN=""
INSTALL_DIR=""
WORK_DIR=""
AGENT_USER=""
JAVA_HOME_IN=""
JAVA_VERSION="25"
UNINSTALL=0
NON_INTERACTIVE=0
ASSUME_YES=0
SECRET_DIR="/etc/jenkins-agent"
TMP_DIR=""
JAVA_BIN=""
SECRET=""
TRUSTED_SHA256=""
SKIP_CERT_CHECK=0
TLS_MODE=""           # "" (http), system, untrusted (gecici), pinned, bypass
JAVA_TRUSTSTORE=""    # system modunda kullanilan sistem Java truststore'u
PIN_PEM=""            # pinned modunda sabitlenen sertifika (agent.jar indirmesi icin)
TRUSTSTORE_REUSED=0

usage() {
    cat <<'EOF'
Kullanim: install-jenkins-agent.sh [secenekler]

  --url URL            Jenkins adresi (ornek: https://jenkins.example.com/)
  --name AD            Agent (node) adi (varsayilan: hostname)
  --secret-file DOSYA  Secret'i bu dosyadan oku (veya JENKINS_SECRET ortam degiskeni)
  --install-dir DIZIN  Kurulum dizini (varsayilan: /opt/jenkins-agent)
  --work-dir DIZIN     Calisma dizini (varsayilan: /var/lib/jenkins-agent)
  --user KULLANICI     Agent'in calisacagi kullanici (varsayilan: jenkins)
  --java-home DIZIN    Mevcut Java (JAVA_HOME, bin dizini veya java yolu)
  --java-version N     Indirilecek Temurin surumu (varsayilan: 25)
  --trusted-cert-sha256 HEX
                       Sistemin guvenmedigi sertifikayi, SHA-256 parmak izi bununla
                       eslesirse sabitle (truststore.p12)
  --skip-certificate-check
                       Sertifika kontrolunu kapat (guvensiz, son care)
  --non-interactive    Soru sorma, verilmeyenler icin varsayilanlari kullan
  -y, --yes            Onay sorularina evet de
  --uninstall          Servisi ve secret dosyasini kaldir
  --self-test          Yardimci fonksiyonlarin testlerini calistir
  -h, --help           Bu yardim
EOF
}

die() { printf '\nHATA: %s\n' "$*" >&2; exit 1; }
info() { printf '  %s\n' "$*"; }
step() { printf '\n[%s/%s] %s\n' "$1" "$TOTAL_STEPS" "$2"; }

# ---------------------------------------------------------------------------
# Yardimci fonksiyonlar
# ---------------------------------------------------------------------------

# "openjdk version "25" 2025-09-16" / "17.0.12" / "1.8.0_421" -> 25 / 17 / 8, bulunamazsa 0
parse_java_major() {
    local line major minor
    line=$(grep -m1 -o 'version "[0-9][^"]*"' || true)
    major=$(printf '%s' "$line" | sed -n 's/^version "\([0-9]*\).*/\1/p')
    minor=$(printf '%s' "$line" | sed -n 's/^version "[0-9]*\.\([0-9]*\).*/\1/p')
    if [ -z "$major" ]; then echo 0; return; fi
    if [ "$major" = "1" ] && [ -n "$minor" ]; then major=$minor; fi
    echo "$major"
}

normalize_url() {
    local url
    url=$(printf '%s' "$1" | tr -d '[:space:]')
    [[ "$url" =~ ^https?://[^/]+ ]] || return 1
    while [ "${url%/}" != "$url" ]; do url=${url%/}; done
    printf '%s/\n' "$url"
}

valid_agent_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# JAVA_HOME, bin dizini veya java yolunu kabul eder; java calistirilabilir yolunu basar.
resolve_java() {
    local path=$1 candidate
    [ -n "$path" ] || return 1
    for candidate in "$path" "$path/bin/java" "$path/java"; do
        if [ -f "$candidate" ] && [ -x "$candidate" ] && [ "$(basename "$candidate")" = "java" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

temurin_arch() {
    case "$(uname -m)" in
        x86_64 | amd64) echo x64 ;;
        aarch64 | arm64) echo aarch64 ;;
        *) return 1 ;;
    esac
}

has_tty() { { : </dev/tty; } 2>/dev/null; }

ask() {
    # ask DEGISKEN "soru" "varsayilan"
    local var=$1 prompt=$2 default=${3:-} value=""
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
        value=$default
    else
        [ -n "$default" ] && prompt="$prompt [$default]"
        read -r -p "  $prompt: " value </dev/tty || true
        value=${value:-$default}
    fi
    printf -v "$var" '%s' "$value"
}

ask_required() {
    local var=$1
    ask "$@"
    while [ -z "${!var}" ]; do
        [ "$NON_INTERACTIVE" -eq 1 ] && die "$2 verilmedi (parametre olarak verin)."
        ask "$@"
    done
}

confirm() {
    # confirm "soru" y|n  (ikinci arguman varsayilan cevap)
    local answer default=$2 hint="e/H"
    [ "$ASSUME_YES" -eq 1 ] && return 0
    if [ "$NON_INTERACTIVE" -eq 1 ]; then [ "$default" = "y" ]; return; fi
    [ "$default" = "y" ] && hint="E/h"
    read -r -p "  $1 [$hint]: " answer </dev/tty || true
    answer=${answer:-$default}
    [[ "$answer" =~ ^([eEyY]|evet|yes)$ ]]
}

download() {
    # download URL DOSYA [ek curl argumanlari...]  (https icin curl zorunlu, bkz. check_tls)
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 "${@:3}" -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "curl veya wget gerekli."
    fi
}

# "SHA256 Fingerprint=AB:CD:.." / "ab cd .." / "abcd.." -> 64 haneli kucuk harf hex
normalize_sha256() {
    local hex
    hex=$(printf '%s' "${1##*=}" | tr -d ': \t\r\n' | tr 'A-F' 'a-f')
    [[ "$hex" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$hex"
}

# https://host:port/yol -> "host port"
# shortcut: IPv6 adres ([::1]) desteklenmez; gerekirse host adi kullanin.
url_host_port() {
    local hp=${1#*://}
    hp=${hp%%/*}
    hp=${hp##*@}
    case "$hp" in
        *:*) printf '%s %s\n' "${hp%:*}" "${hp##*:}" ;;
        *) printf '%s 443\n' "$hp" ;;
    esac
}

# stdin'deki PEM zincirinden son (en ust) sertifikayi basar.
last_pem_cert() {
    awk '/-BEGIN CERTIFICATE-/ { c = ""; on = 1 } on { c = c $0 "\n" } /-END CERTIFICATE-/ { on = 0; last = c } END { printf "%s", last }'
}

# stdin'deki PEM zincirinden ilk (sitenin kendi) sertifikasini basar.
first_pem_cert() {
    awk '/-BEGIN CERTIFICATE-/ { on = 1 } on { print } /-END CERTIFICATE-/ { exit }'
}

is_ip() { [[ "$1" =~ ^[0-9]+(\.[0-9]+){3}$ ]]; }
verify_host_opt() { if is_ip "$1"; then echo -verify_ip; else echo -verify_hostname; fi; }

# "May 29 10:43:45 2125 GMT" gibi bir tarih gelecekteyse basarili doner.
date_in_future() { [ "$(date -d "$1" +%s)" -gt "$(date +%s)" ]; }

# cert_problem SITE_PEM PIN_PEM HOST: sabitlemenin cozemeyecegi sorunu basar; sorun yoksa 1 doner.
cert_problem() {
    local leaf=$1 pin=$2 host=$3 c check=-checkhost
    is_ip "$host" && check=-checkip
    # Uyusmazlikta openssl 1 ile cikar (surume gore degisir), bu yuzden cikti kontrol edilir.
    if [[ "$(openssl x509 -noout "$check" "$host" -in "$leaf" 2>&1)" == *"NOT match"* ]]; then
        echo "Sertifika bu adres ($host) icin verilmemis."
        return 0
    fi
    for c in "$leaf" "$pin"; do
        if ! openssl x509 -noout -checkend 0 -in "$c" >/dev/null; then
            echo "Sertifikanin suresi dolmus: $(cert_name subject "$c")"
            return 0
        fi
        if date_in_future "$(openssl x509 -noout -startdate -in "$c" | cut -d= -f2)"; then
            echo "Sertifika henuz gecerli degil: $(cert_name subject "$c")"
            return 0
        fi
    done
    return 1
}

# in_cert_dir PEM [DIZIN...]: sertifika (parmak iziyle) hash dizinli bir sistem deposunda var mi?
in_cert_dir() {
    local fp dir f hash
    fp=$(cert_sha256 "$1")
    hash=$(openssl x509 -noout -subject_hash -in "$1")
    shift
    for dir in "${@:-/etc/ssl/certs}"; do
        for f in "$dir/$hash".[0-9]; do
            [ -f "$f" ] && [ "$(cert_sha256 "$f")" = "$fp" ] && return 0
        done
    done
    return 1
}

cert_name() { openssl x509 -noout "-$1" -nameopt RFC2253 -in "$2" | sed "s/^$1= *//"; }
cert_sha256() { normalize_sha256 "$(openssl x509 -noout -fingerprint -sha256 -in "$1")"; }
is_self_signed() { [ "$(cert_name subject "$1")" = "$(cert_name issuer "$1")" ]; }

# Truststore'daki (tek) sertifikanin parmak izi; okunamazsa bos doner.
truststore_sha256() {
    openssl pkcs12 -in "$1" -nokeys -passin "pass:$TRUSTSTORE_PASS" 2>/dev/null >"$TMP_DIR/store.pem" || return 1
    cert_sha256 "$TMP_DIR/store.pem" 2>/dev/null
}

system_java_truststore() {
    local f
    for f in /etc/ssl/certs/java/cacerts /etc/pki/ca-trust/extracted/java/cacerts; do
        [ -s "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

# systemd ExecStart icin -jar oncesi Java argumanlari.
# Sistem Java deposu (Debian/RHEL) changeit ile yazilir; parola olmadan PKCS12 sertifikalari okunamaz.
tls_java_opts() {
    case "$TLS_MODE" in
        system) printf '"-Djavax.net.ssl.trustStore=%s" -Djavax.net.ssl.trustStorePassword=%s ' "$JAVA_TRUSTSTORE" "$TRUSTSTORE_PASS" ;;
        pinned) printf '"-Djavax.net.ssl.trustStore=%s" -Djavax.net.ssl.trustStoreType=PKCS12 -Djavax.net.ssl.trustStorePassword=%s ' "$INSTALL_DIR/truststore.p12" "$TRUSTSTORE_PASS" ;;
    esac
    return 0
}

ensure_root() {
    [ "$(id -u)" -eq 0 ] && return 0
    command -v sudo >/dev/null 2>&1 || die "root olarak calistirin."
    local script=$0 tmp_script="" preserve=()
    if [ ! -f "$script" ]; then
        # bash <(curl ...) veya stdin: sudo bu dosyayi okuyamaz, kendini indir.
        # Yeni surec bu gecici dosyayi baslarken siler (bkz. remove_reexec_copy).
        script="$(mktemp)"
        tmp_script=$script
        download "$SCRIPT_URL" "$script" || { rm -f "$script"; die "root olarak calistirin: curl ... | sudo bash"; }
    fi
    # Secret komut satirina yazilmaz; sadece ortamda varsa korunur.
    [ -n "${JENKINS_SECRET:-}" ] && preserve=(--preserve-env=JENKINS_SECRET)
    info "root yetkisi gerekiyor, sudo ile yeniden calistiriliyor..."
    exec sudo ${preserve[@]+"${preserve[@]}"} env JENKINS_AGENT_INSTALLER_TMP="$tmp_script" bash "$script" "$@"
}

remove_reexec_copy() {
    # bash dosyayi acik tuttugu icin calisirken silinmesi sorun olmaz.
    if [ -n "${JENKINS_AGENT_INSTALLER_TMP:-}" ] && [ "$JENKINS_AGENT_INSTALLER_TMP" = "$0" ]; then
        rm -f -- "$0"
    fi
}

# ---------------------------------------------------------------------------
# Kurulum adimlari
# ---------------------------------------------------------------------------

java_ok() {
    local major
    major=$("$1" -version 2>&1 | parse_java_major)
    if [ "$major" -lt "$MIN_JAVA_MAJOR" ]; then
        info "Java surumu $MIN_JAVA_MAJOR veya ustu olmali (bulunan: $major): $1"
        return 1
    fi
    info "Java $major bulundu: $1"
}

install_temurin() {
    local arch type url archive extract top target
    arch=$(temurin_arch) || die "Desteklenmeyen mimari: $(uname -m). --java-home ile Java verin."
    archive="$TMP_DIR/temurin.tar.gz"
    for type in jre jdk; do
        url="https://api.adoptium.net/v3/binary/latest/$JAVA_VERSION/ga/linux/$arch/$type/hotspot/normal/eclipse"
        info "Indiriliyor: $url" >&2
        if download "$url" "$archive"; then break; fi
        info "Temurin $JAVA_VERSION $type indirilemedi." >&2
        rm -f "$archive"
    done
    [ -f "$archive" ] || die "Temurin $JAVA_VERSION indirilemedi."
    extract="$TMP_DIR/java"
    mkdir -p "$extract" "$INSTALL_DIR/java"
    tar -xzf "$archive" -C "$extract"
    top=$(find "$extract" -mindepth 1 -maxdepth 1 -type d)
    [ -n "$top" ] && [ "$(printf '%s\n' "$top" | wc -l)" -eq 1 ] || die "Java arsivinin yapisi beklenenden farkli."
    target="$INSTALL_DIR/java/$(basename "$top")"
    if [ -d "$target" ]; then
        info "Bu surum zaten var, mevcut dizin kullaniliyor: $target" >&2
    else
        mv "$top" "$target"
    fi
    printf '%s\n' "$target"
}

choose_java() {
    local mode="1" path="$JAVA_HOME_IN" java
    if [ -z "$path" ] && [ "$NON_INTERACTIVE" -eq 0 ]; then
        info "1) Temurin $JAVA_VERSION indir (onerilen)"
        info "2) Java dizin yolunu yaz"
        ask mode "Secim" "1"
    fi
    while true; do
        if [ -z "$path" ]; then
            if [ "$mode" = "2" ]; then
                ask_required path "Java dizini (JAVA_HOME, bin veya java yolu)"
            else
                path=$(install_temurin)
            fi
        fi
        if java=$(resolve_java "$path") && java_ok "$java"; then
            JAVA_BIN=$java
            return 0
        fi
        [ -n "$java" ] || info "java bulunamadi: $path"
        if [ "$NON_INTERACTIVE" -eq 1 ] || [ "$mode" != "2" ]; then die "Gecerli bir Java bulunamadi."; fi
        path=""
        java=""
    done
}

# Jenkins adresine sistem sertifika deposuyla (curl, -k olmadan) baglanir.
check_tls() {
    local rc=0 err="$TMP_DIR/curl.err"
    case "$JENKINS_URL" in https://*) ;; *) TLS_MODE=""; return ;; esac
    command -v curl >/dev/null 2>&1 || die "https adresi icin curl gerekli."
    curl -sS -o /dev/null --max-time 20 "$JENKINS_URL" 2>"$err" || rc=$?
    case "$rc" in
        0) TLS_MODE=system; info "Sertifika sistem sertifika deposuna gore gecerli." ;;
        35 | 51 | 58 | 60 | 77 | 83)
            TLS_MODE=untrusted
            info "Sertifika bu makinede dogrulanamadi: $(head -n1 "$err")"
            if [ -n "${https_proxy:-}${HTTPS_PROXY:-}" ]; then
                info "UYARI: Proxy tanimli (https_proxy). openssl ve Java bu proxy'yi kullanmaz; proxy TLS'e araya giriyorsa burada gorulen sertifika agent'in gorecegi sertifikadan farkli olabilir."
            fi
            ;;
        6) die "Jenkins adresi cozulemedi (DNS): $(head -n1 "$err")" ;;
        7) die "Jenkins'e baglanilamadi (ag, port veya firewall): $(head -n1 "$err")" ;;
        28) die "Jenkins'e baglanti zaman asimina ugradi: $(head -n1 "$err")" ;;
        *) die "Jenkins'e erisilemedi (curl kodu $rc): $(head -n1 "$err")" ;;
    esac
}

# fetch_top_cert CIKTI [openssl s_client ek argumanlari...]
# Zinciri sadece incelemek icin alir, en ustteki sertifikayi CIKTI'ya yazar.
fetch_top_cert() {
    local out=$1 host port
    shift
    read -r host port <<<"$(url_host_port "$JENKINS_URL")"
    timeout 20 openssl s_client -connect "$host:$port" -servername "$host" -showcerts "$@" \
        </dev/null >"$TMP_DIR/chain.txt" 2>/dev/null || return 1
    last_pem_cert <"$TMP_DIR/chain.txt" >"$out"
    [ -s "$out" ]
}

show_cert() {
    info "Konu      : $(cert_name subject "$1")"
    info "Yayinci   : $(cert_name issuer "$1")"
    info "Gecerlilik: $(openssl x509 -noout -startdate -in "$1" | cut -d= -f2) - $(openssl x509 -noout -enddate -in "$1" | cut -d= -f2)"
    info "SHA-256   : $(cert_sha256 "$1")"
    is_self_signed "$1" || info "UYARI: Bu sertifika kok CA degil (sitenin kendi sertifikasi veya ara CA). Sertifika yenilendiginde bu script yeniden calistirilmali."
}

# -y/--yes guvenlik onaylarini gecmez (confirm global ASSUME_YES'i okur).
confirm_strict() {
    local ASSUME_YES=0
    confirm "$@"
}

choose_bypass() {
    info "UYARI: Sertifika kontrolu kapatilirsa agi dinleyebilen biri kendini Jenkins gibi"
    info "gosterip agent secret'ini calabilir ve bu makineye istedigi isi gonderebilir."
    if [ "$SKIP_CERT_CHECK" -ne 1 ]; then
        confirm_strict "Yine de sertifika kontrolu kapatilsin mi?" n || die "Iptal edildi."
    fi
    TLS_MODE=bypass
}

choose_pin() {
    local fp
    fp=$(cert_sha256 "$PIN_PEM") || die "Sertifika parmak izi okunamadi."
    if [ -n "$TRUSTED_SHA256" ]; then
        [ "$TRUSTED_SHA256" = "$fp" ] || die "Sertifika parmak izi --trusted-cert-sha256 ile eslesmiyor (sunucu: $fp)."
        info "Parmak izi --trusted-cert-sha256 ile eslesti."
    else
        if in_cert_dir "$PIN_PEM" /etc/ssl/certs /etc/pki/ca-trust/extracted/pem/directory-hash; then
            info "NOT: Bu sertifika sistem deposunda zaten olan genel bir kok CA. Sabitlenirse agent bu CA'nin imzaladigi her sunucuya guvenir."
        fi
        confirm_strict "Bu sertifika sabitlensin mi? Parmak izini Jenkins yoneticisinden dogrulayin." n || die "Iptal edildi."
    fi
    TLS_MODE=pinned
}

# Sistem guveniyor ama Java icin sistem deposu yok: zinciri ayni dogrulamayla (sistem deposu +
# host adi) alir, imzalayan CA /etc/ssl/certs icindeyse onu, yoksa en ustteki sertifikayi sabitler.
pin_system_trusted() {
    local host port issuer f
    read -r host port <<<"$(url_host_port "$JENKINS_URL")"
    fetch_top_cert "$PIN_PEM" -verify_return_error "$(verify_host_opt "$host")" "$host" || die "Sertifika zinciri alinamadi veya dogrulanamadi."
    issuer=$(cert_name issuer "$PIN_PEM")
    for f in /etc/ssl/certs/"$(openssl x509 -noout -issuer_hash -in "$PIN_PEM")".[0-9]; do
        if [ -f "$f" ] && [ "$(cert_name subject "$f")" = "$issuer" ]; then
            cp "$f" "$PIN_PEM"
            break
        fi
    done
    TLS_MODE=pinned
}

choose_tls() {
    local store="$INSTALL_DIR/truststore.p12" mode="" problem
    PIN_PEM="$TMP_DIR/jenkins-ca.pem"
    case "$TLS_MODE" in
        "") info "http adresi, sertifika ayari gerekmiyor."; return ;;
        system)
            if JAVA_TRUSTSTORE=$(system_java_truststore); then
                info "Java sistem sertifika deposunu kullanacak: $JAVA_TRUSTSTORE"
                return
            fi
            command -v openssl >/dev/null 2>&1 || die "openssl gerekli."
            info "Java icin sistem deposu yok (Debian/Ubuntu: ca-certificates-java), sertifika sabitlenecek."
            pin_system_trusted
            show_cert "$PIN_PEM"
            return
            ;;
    esac
    command -v openssl >/dev/null 2>&1 || die "openssl gerekli."
    fetch_top_cert "$PIN_PEM" || die "Sertifika zinciri alinamadi."
    first_pem_cert <"$TMP_DIR/chain.txt" >"$TMP_DIR/site.pem"
    if problem=$(cert_problem "$TMP_DIR/site.pem" "$PIN_PEM" "$(url_host_port "$JENKINS_URL" | cut -d' ' -f1)"); then
        show_cert "$PIN_PEM"
        info "Sabitleme sunulmuyor, sabitleme bu sorunu cozmez: $problem"
        [ -n "$TRUSTED_SHA256" ] && die "$problem"
        if [ "$SKIP_CERT_CHECK" -eq 1 ]; then choose_bypass; return; fi
        [ "$NON_INTERACTIVE" -eq 1 ] && die "$problem Sertifikayi duzeltin veya --skip-certificate-check verin."
        info "1) Sertifika kontrolunu kapat (guvensiz)"
        info "2) Iptal"
        ask mode "Secim" "2"
        [ "$mode" = "1" ] && { choose_bypass; return; }
        die "Iptal edildi."
    fi
    if [ "$SKIP_CERT_CHECK" -ne 1 ] && [ -z "$TRUSTED_SHA256" ] && [ -f "$store" ] &&
        [ "$(truststore_sha256 "$store")" = "$(cert_sha256 "$PIN_PEM")" ]; then
        info "Mevcut truststore ayni sertifikayi iceriyor, kullaniliyor: $store"
        TLS_MODE=pinned
        TRUSTSTORE_REUSED=1
        return
    fi
    show_cert "$PIN_PEM"
    if [ "$SKIP_CERT_CHECK" -eq 1 ]; then choose_bypass; return; fi
    if [ -n "$TRUSTED_SHA256" ]; then choose_pin; return; fi
    [ "$NON_INTERACTIVE" -eq 1 ] && die "Sertifikaya guvenilmiyor. --trusted-cert-sha256 veya --skip-certificate-check verin."
    info "1) Sertifikayi sabitle (onerilen)"
    info "2) Sertifika kontrolunu kapat (guvensiz)"
    info "3) Iptal"
    ask mode "Secim" "1"
    case "$mode" in
        1) choose_pin ;;
        2) choose_bypass ;;
        *) die "Iptal edildi." ;;
    esac
}

# Secilen moda gore truststore.p12'yi yazar veya eski kalani siler.
write_truststore() {
    local store="$INSTALL_DIR/truststore.p12" keytool
    if [ "$TLS_MODE" != pinned ]; then
        rm -f "$store"
        return
    fi
    if [ "$TRUSTSTORE_REUSED" -eq 0 ]; then
        keytool="$(dirname "$JAVA_BIN")/keytool"
        [ -x "$keytool" ] || keytool="$(dirname "$(readlink -f "$JAVA_BIN")")/keytool"
        [ -x "$keytool" ] || die "keytool bulunamadi: $keytool"
        rm -f "$TMP_DIR/truststore.p12"
        "$keytool" -importcert -noprompt -alias jenkins-ca -file "$PIN_PEM" -keystore "$TMP_DIR/truststore.p12" \
            -storetype PKCS12 -storepass "$TRUSTSTORE_PASS" >"$TMP_DIR/keytool.log" 2>&1 ||
            die "truststore olusturulamadi: $(<"$TMP_DIR/keytool.log")"
        install -m 600 "$TMP_DIR/truststore.p12" "$store"
        info "Truststore yazildi: $store"
    fi
    chown "$AGENT_USER:" "$store"
    chmod 600 "$store"
}

ensure_user() {
    if id "$AGENT_USER" >/dev/null 2>&1; then
        info "Kullanici mevcut: $AGENT_USER"
        return
    fi
    local nologin
    nologin=$(command -v nologin || echo /sbin/nologin)
    useradd --system --user-group --home-dir "$WORK_DIR" --shell "$nologin" "$AGENT_USER"
    info "Sistem kullanicisi olusturuldu: $AGENT_USER"
}

read_secret() {
    local file=$1
    if [ -n "$SECRET_FILE_IN" ]; then
        [ -r "$SECRET_FILE_IN" ] || die "Secret dosyasi okunamiyor: $SECRET_FILE_IN"
        SECRET=$(tr -d '[:space:]' <"$SECRET_FILE_IN")
    elif [ -n "${JENKINS_SECRET:-}" ]; then
        SECRET=$JENKINS_SECRET
    elif [ -f "$file" ] && confirm "Mevcut secret dosyasi kullanilsin mi?" y; then
        SECRET=""
        return
    elif [ "$NON_INTERACTIVE" -eq 1 ]; then
        die "Secret verilmedi (--secret-file veya JENKINS_SECRET)."
    else
        info "Secret, Jenkins > Nodes > <agent> sayfasindaki komutta yer alir."
        SECRET=""
        while [ -z "$SECRET" ]; do
            read -r -s -p "  Secret: " SECRET </dev/tty || true
            echo >&2
        done
    fi
    [ -n "$SECRET" ] || die "Secret bos."
}

write_secret() {
    local file=$1
    mkdir -p "$SECRET_DIR"
    chmod 755 "$SECRET_DIR"
    if [ -n "$SECRET" ]; then
        (umask 077 && printf '%s' "$SECRET" >"$file")
    fi
    chown "$AGENT_USER:" "$file"
    chmod 600 "$file"
}

write_unit() {
    local unit_file=$1 secret_file=$2 url pre="" agent_opts=""
    # systemd % karakterini ozel yorumlar.
    url=${JENKINS_URL//%/%%}
    if [ "$TLS_MODE" = bypass ]; then
        pre='ExecStartPre=/bin/echo "WARN sertifika kontrolu kapali (-noCertificateCheck), baglanti dinlenebilir."'
        agent_opts=" -noCertificateCheck"
    fi
    cat >"$unit_file" <<EOF
[Unit]
Description=Jenkins inbound agent ($AGENT_NAME)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$AGENT_USER
WorkingDirectory=$WORK_DIR
$pre
ExecStart="$JAVA_BIN" $(tls_java_opts)-jar "$INSTALL_DIR/agent.jar" -url "$url" -name "$AGENT_NAME" -secret "@$secret_file" -webSocket -workDir "$WORK_DIR"$agent_opts
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$unit_file"
}

do_install() {
    local raw_url secret_file unit service jar
    step 1 "Jenkins adresi"
    raw_url=$JENKINS_URL
    [ -n "$raw_url" ] || ask_required raw_url "Jenkins URL (ornek: https://jenkins.example.com/)"
    JENKINS_URL=$(normalize_url "$raw_url") || die "Gecersiz Jenkins URL: $raw_url (http:// veya https:// ile baslamali)."
    check_tls

    step 2 "Agent adi"
    [ -n "$AGENT_NAME" ] || ask_required AGENT_NAME "Agent (node) adi" "$(hostname -s 2>/dev/null || hostname)"
    valid_agent_name "$AGENT_NAME" || die "Gecersiz agent adi: $AGENT_NAME (harf, rakam, nokta, tire, alt cizgi)."

    step 3 "Dizinler"
    [ -n "$INSTALL_DIR" ] || ask_required INSTALL_DIR "Kurulum dizini" "/opt/jenkins-agent"
    [ -n "$WORK_DIR" ] || ask_required WORK_DIR "Calisma dizini (workDir)" "/var/lib/jenkins-agent"

    step 4 "Sertifika"
    choose_tls

    step 5 "Kullanici"
    [ -n "$AGENT_USER" ] || ask_required AGENT_USER "Agent'in calisacagi kullanici" "jenkins"
    ensure_user
    mkdir -p "$INSTALL_DIR" "$WORK_DIR"
    chmod 755 "$INSTALL_DIR"
    chown "$AGENT_USER:" "$WORK_DIR"
    chmod 750 "$WORK_DIR"

    step 6 "Java"
    choose_java
    write_truststore

    step 7 "agent.jar"
    jar="$INSTALL_DIR/agent.jar"
    if [ ! -f "$jar" ] || confirm "agent.jar zaten var, guncellensin mi?" y; then
        info "Indiriliyor: ${JENKINS_URL}jnlpJars/agent.jar"
        case "$TLS_MODE" in
            pinned) download "${JENKINS_URL}jnlpJars/agent.jar" "$TMP_DIR/agent.jar" --cacert "$PIN_PEM" ;;
            bypass) download "${JENKINS_URL}jnlpJars/agent.jar" "$TMP_DIR/agent.jar" -k ;;
            *) download "${JENKINS_URL}jnlpJars/agent.jar" "$TMP_DIR/agent.jar" ;;
        esac
        install -m 644 "$TMP_DIR/agent.jar" "$jar"
    fi

    step 8 "Secret"
    secret_file="$SECRET_DIR/$AGENT_NAME.secret"
    read_secret "$secret_file"
    write_secret "$secret_file"
    SECRET=""
    info "Secret dosyasi: $secret_file"

    step 9 "systemd servisi"
    service="jenkins-agent-$AGENT_NAME.service"
    unit="/etc/systemd/system/$service"
    write_unit "$unit" "$secret_file"
    systemctl daemon-reload
    systemctl enable "$service" >/dev/null
    systemctl restart "$service"
    sleep 3
    systemctl --no-pager --lines=5 status "$service" || true

    printf '\nKurulum tamamlandi.\n'
    info "Durum : systemctl status $service"
    info "Log   : journalctl -u $service -f"
    info "Remoting logu: $WORK_DIR/remoting/logs"
}

do_uninstall() {
    local service
    [ -n "$AGENT_NAME" ] || ask_required AGENT_NAME "Agent (node) adi" "$(hostname -s 2>/dev/null || hostname)"
    valid_agent_name "$AGENT_NAME" || die "Gecersiz agent adi: $AGENT_NAME"
    [ -n "$INSTALL_DIR" ] || ask_required INSTALL_DIR "Kurulum dizini" "/opt/jenkins-agent"
    service="jenkins-agent-$AGENT_NAME.service"
    systemctl disable --now "$service" 2>/dev/null || true
    rm -f "/etc/systemd/system/$service" "$SECRET_DIR/$AGENT_NAME.secret"
    systemctl daemon-reload
    info "Servis ve secret dosyasi kaldirildi: $service"
    if [ -d "$INSTALL_DIR" ] && confirm "$INSTALL_DIR silinsin mi?" n; then
        rm -rf -- "$INSTALL_DIR"
        info "$INSTALL_DIR silindi."
    fi
    info "Calisma dizini ve kullanici silinmedi."
}

# Kontroller eval ile calisir, tek tirnak bilincli.
# shellcheck disable=SC2016
self_test() {
    local failed=0
    check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; failed=$((failed + 1)); fi; }
    check "java 25" '[ "$(echo "openjdk version \"25\" 2025-09-16" | parse_java_major)" = 25 ]'
    check "java 17.0.12" '[ "$(echo "openjdk version \"17.0.12\" 2024-07-16" | parse_java_major)" = 17 ]'
    check "java 1.8" '[ "$(echo "java version \"1.8.0_421\"" | parse_java_major)" = 8 ]'
    check "java taninmayan" '[ "$(echo "not found" | parse_java_major)" = 0 ]'
    check "url /" '[ "$(normalize_url "https://jenkins.example.com")" = "https://jenkins.example.com/" ]'
    check "url fazla /" '[ "$(normalize_url " https://jenkins.example.com/// ")" = "https://jenkins.example.com/" ]'
    check "url alt yol" '[ "$(normalize_url "http://ci.example.com:8080/jenkins")" = "http://ci.example.com:8080/jenkins/" ]'
    check "url semasiz red" '! normalize_url "jenkins.example.com" >/dev/null'
    check "ad gecerli" 'valid_agent_name build-01.x_64'
    check "ad bosluk red" '! valid_agent_name "build 01"'
    check "ad / red" '! valid_agent_name "a/b"'
    local dir
    dir=$(mktemp -d)
    mkdir -p "$dir/jdk/bin" && printf '#!/bin/sh\n' >"$dir/jdk/bin/java" && chmod +x "$dir/jdk/bin/java"
    check "java home" '[ "$(resolve_java "$dir/jdk")" = "$dir/jdk/bin/java" ]'
    check "java bin" '[ "$(resolve_java "$dir/jdk/bin")" = "$dir/jdk/bin/java" ]'
    check "java yolu" '[ "$(resolve_java "$dir/jdk/bin/java")" = "$dir/jdk/bin/java" ]'
    check "java yok" '! resolve_java "$dir/yok" >/dev/null'

    local hex=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
    check "sha256 iki nokta/buyuk" '[ "$(normalize_sha256 "SHA256 Fingerprint=01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF:01:23:45:67:89:AB:CD:EF")" = "$hex" ]'
    check "sha256 bosluklu" '[ "$(normalize_sha256 "01 23 45 67 89 ab cd ef 0123456789abcdef0123456789abcdef0123456789abcdef")" = "$hex" ]'
    check "sha256 kisa red" '! normalize_sha256 abcd >/dev/null'
    check "sha256 hex disi red" '! normalize_sha256 "${hex%?}g" >/dev/null'
    check "host varsayilan port" '[ "$(url_host_port "https://jenkins.example.com/")" = "jenkins.example.com 443" ]'
    check "host port yol" '[ "$(url_host_port "https://ci.example.com:8443/jenkins/")" = "ci.example.com 8443" ]'
    check "ipv4" 'is_ip 10.1.2.3 && ! is_ip jenkins.example.com'
    check "verify_ip" '[ "$(verify_host_opt 10.1.2.3)" = -verify_ip ] && [ "$(verify_host_opt jenkins.example.com)" = -verify_hostname ]'
    check "tarih gelecekte" 'date_in_future "Jan  1 00:00:00 2999 GMT" && ! date_in_future "Jan  1 00:00:00 2000 GMT"'
    check "iki flag birlikte red" '! (parse_args --trusted-cert-sha256 "$hex" --skip-certificate-check) 2>/dev/null'
    check "pem en ust" '[ "$(printf "x\n-----BEGIN CERTIFICATE-----\nA\n-----END CERTIFICATE-----\ny\n-----BEGIN CERTIFICATE-----\nB\n-----END CERTIFICATE-----\nz\n" | last_pem_cert | sed -n 2p)" = B ]'

    TMP_DIR=$dir INSTALL_DIR="/opt/ja dir" JAVA_BIN=/usr/bin/java AGENT_NAME=a1 AGENT_USER=jenkins WORK_DIR=/w JENKINS_URL=https://j/
    JAVA_TRUSTSTORE=/etc/ssl/certs/java/cacerts TLS_MODE=system
    check "opts system" '[ "$(tls_java_opts)" = "\"-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts\" -Djavax.net.ssl.trustStorePassword=changeit " ]'
    TLS_MODE=pinned
    check "opts pinned" '[ "$(tls_java_opts)" = "\"-Djavax.net.ssl.trustStore=/opt/ja dir/truststore.p12\" -Djavax.net.ssl.trustStoreType=PKCS12 -Djavax.net.ssl.trustStorePassword=changeit " ]'
    write_unit "$dir/unit" /s
    check "unit pinned" 'grep -q "^ExecStart=\"/usr/bin/java\" \"-Djavax.net.ssl.trustStore=/opt/ja dir/truststore.p12\" .* -jar \"/opt/ja dir/agent.jar\" .*-webSocket -workDir \"/w\"$" "$dir/unit" && ! grep -q "noCertificateCheck\|ExecStartPre" "$dir/unit"'
    TLS_MODE=bypass
    check "opts bypass" '[ -z "$(tls_java_opts)" ]'
    write_unit "$dir/unit" /s
    check "unit bypass" 'grep -q "^ExecStart=\"/usr/bin/java\" -jar .* -webSocket -workDir \"/w\" -noCertificateCheck$" "$dir/unit" && grep -q "^ExecStartPre=.*WARN" "$dir/unit"'
    TLS_MODE=""
    check "opts http" '[ -z "$(tls_java_opts)" ]'

    if command -v openssl >/dev/null 2>&1; then
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Test CA" -keyout "$dir/ca.key" -out "$dir/ca.pem" >/dev/null 2>&1
        openssl req -newkey rsa:2048 -nodes -subj "/CN=jenkins.example.com" -keyout "$dir/leaf.key" -out "$dir/leaf.csr" >/dev/null 2>&1
        openssl x509 -req -in "$dir/leaf.csr" -CA "$dir/ca.pem" -CAkey "$dir/ca.key" -CAcreateserial -days 2 -out "$dir/leaf.pem" >/dev/null 2>&1
        check "kendinden imzali" 'is_self_signed "$dir/ca.pem"'
        check "site sertifikasi kok degil" '! is_self_signed "$dir/leaf.pem"'
        check "parmak izi" '[ "$(cert_sha256 "$dir/ca.pem")" = "$(normalize_sha256 "$(openssl x509 -noout -fingerprint -sha256 -in "$dir/ca.pem")")" ] && [ "$(cert_sha256 "$dir/ca.pem")" != "$(cert_sha256 "$dir/leaf.pem")" ]'
        check "zincirden en ust" '[ "$(cat "$dir/leaf.pem" "$dir/ca.pem" | last_pem_cert | openssl x509 -noout -subject -nameopt RFC2253)" = "subject=CN=Test CA" ]'
        check "zincirden site" '[ "$(cat "$dir/leaf.pem" "$dir/ca.pem" | first_pem_cert | openssl x509 -noout -subject -nameopt RFC2253)" = "subject=CN=jenkins.example.com" ]'
        check "sorun yok" '! cert_problem "$dir/leaf.pem" "$dir/ca.pem" jenkins.example.com >/dev/null'
        check "ad uyusmuyor" 'cert_problem "$dir/leaf.pem" "$dir/ca.pem" other.example.com | grep -q "adres (other.example.com)"'
        check "ip uyusmuyor" 'cert_problem "$dir/leaf.pem" "$dir/ca.pem" 10.0.0.1 | grep -q "adres (10.0.0.1)"'
        mkdir -p "$dir/certs"
        cp "$dir/ca.pem" "$dir/certs/$(openssl x509 -noout -subject_hash -in "$dir/ca.pem").0"
        check "sistem deposunda" 'in_cert_dir "$dir/ca.pem" "$dir/yok" "$dir/certs"'
        check "sistem deposunda degil" '! in_cert_dir "$dir/leaf.pem" "$dir/certs"'
        if openssl req -help 2>&1 | grep -q not_after; then
            openssl req -x509 -newkey rsa:2048 -nodes -subj "/CN=jenkins.example.com" -not_before 20000101000000Z \
                -not_after 20010101000000Z -keyout "$dir/old.key" -out "$dir/old.pem" >/dev/null 2>&1
            check "suresi dolmus" 'cert_problem "$dir/old.pem" "$dir/old.pem" jenkins.example.com | grep -q "suresi dolmus"'
        else
            echo "SKIP  openssl -not_after yok, suresi dolmus testi atlandi"
        fi
    else
        echo "SKIP  openssl yok, sertifika testleri atlandi"
    fi
    rm -rf "$dir"
    [ "$failed" -eq 0 ] || { echo "$failed test basarisiz."; return 1; }
    echo "Tum testler gecti."
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --url) JENKINS_URL=${2:?--url degeri eksik}; shift 2 ;;
            --name) AGENT_NAME=${2:?--name degeri eksik}; shift 2 ;;
            --secret-file) SECRET_FILE_IN=${2:?--secret-file degeri eksik}; shift 2 ;;
            --install-dir) INSTALL_DIR=${2:?--install-dir degeri eksik}; shift 2 ;;
            --work-dir) WORK_DIR=${2:?--work-dir degeri eksik}; shift 2 ;;
            --user) AGENT_USER=${2:?--user degeri eksik}; shift 2 ;;
            --java-home) JAVA_HOME_IN=${2:?--java-home degeri eksik}; shift 2 ;;
            --java-version) JAVA_VERSION=${2:?--java-version degeri eksik}; shift 2 ;;
            --trusted-cert-sha256)
                TRUSTED_SHA256=$(normalize_sha256 "${2:?--trusted-cert-sha256 degeri eksik}") || die "Gecersiz --trusted-cert-sha256: $2"
                shift 2
                ;;
            --skip-certificate-check) SKIP_CERT_CHECK=1; shift ;;
            --non-interactive) NON_INTERACTIVE=1; shift ;;
            -y | --yes) ASSUME_YES=1; shift ;;
            --uninstall) UNINSTALL=1; shift ;;
            --self-test) self_test; exit $? ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; die "Bilinmeyen secenek: $1" ;;
        esac
    done
    [[ "$JAVA_VERSION" =~ ^[0-9]+$ ]] || die "Gecersiz --java-version: $JAVA_VERSION"
    if [ -n "$TRUSTED_SHA256" ] && [ "$SKIP_CERT_CHECK" -eq 1 ]; then
        die "--trusted-cert-sha256 ve --skip-certificate-check birlikte verilemez."
    fi
    return 0
}

main() {
    remove_reexec_copy
    parse_args "$@"
    ensure_root "$@"
    has_tty || NON_INTERACTIVE=1
    command -v systemctl >/dev/null 2>&1 || die "systemd (systemctl) bulunamadi."
    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT
    if [ "$UNINSTALL" -eq 1 ]; then do_uninstall; else do_install; fi
}

main "$@"
