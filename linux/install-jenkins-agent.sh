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
TOTAL_STEPS=8

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
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "curl veya wget gerekli."
    fi
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
    local unit_file=$1 secret_file=$2 url
    # systemd % karakterini ozel yorumlar.
    url=${JENKINS_URL//%/%%}
    cat >"$unit_file" <<EOF
[Unit]
Description=Jenkins inbound agent ($AGENT_NAME)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$AGENT_USER
WorkingDirectory=$WORK_DIR
ExecStart="$JAVA_BIN" -jar "$INSTALL_DIR/agent.jar" -url "$url" -name "$AGENT_NAME" -secret "@$secret_file" -webSocket -workDir "$WORK_DIR"
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

    step 2 "Agent adi"
    [ -n "$AGENT_NAME" ] || ask_required AGENT_NAME "Agent (node) adi" "$(hostname -s 2>/dev/null || hostname)"
    valid_agent_name "$AGENT_NAME" || die "Gecersiz agent adi: $AGENT_NAME (harf, rakam, nokta, tire, alt cizgi)."

    step 3 "Dizinler"
    [ -n "$INSTALL_DIR" ] || ask_required INSTALL_DIR "Kurulum dizini" "/opt/jenkins-agent"
    [ -n "$WORK_DIR" ] || ask_required WORK_DIR "Calisma dizini (workDir)" "/var/lib/jenkins-agent"

    step 4 "Kullanici"
    [ -n "$AGENT_USER" ] || ask_required AGENT_USER "Agent'in calisacagi kullanici" "jenkins"
    ensure_user
    mkdir -p "$INSTALL_DIR" "$WORK_DIR"
    chmod 755 "$INSTALL_DIR"
    chown "$AGENT_USER:" "$WORK_DIR"
    chmod 750 "$WORK_DIR"

    step 5 "Java"
    choose_java

    step 6 "agent.jar"
    jar="$INSTALL_DIR/agent.jar"
    if [ ! -f "$jar" ] || confirm "agent.jar zaten var, guncellensin mi?" y; then
        info "Indiriliyor: ${JENKINS_URL}jnlpJars/agent.jar"
        download "${JENKINS_URL}jnlpJars/agent.jar" "$TMP_DIR/agent.jar"
        install -m 644 "$TMP_DIR/agent.jar" "$jar"
    fi

    step 7 "Secret"
    secret_file="$SECRET_DIR/$AGENT_NAME.secret"
    read_secret "$secret_file"
    write_secret "$secret_file"
    SECRET=""
    info "Secret dosyasi: $secret_file"

    step 8 "systemd servisi"
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
            --non-interactive) NON_INTERACTIVE=1; shift ;;
            -y | --yes) ASSUME_YES=1; shift ;;
            --uninstall) UNINSTALL=1; shift ;;
            --self-test) self_test; exit $? ;;
            -h | --help) usage; exit 0 ;;
            *) usage >&2; die "Bilinmeyen secenek: $1" ;;
        esac
    done
    [[ "$JAVA_VERSION" =~ ^[0-9]+$ ]] || die "Gecersiz --java-version: $JAVA_VERSION"
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
