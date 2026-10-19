#!/usr/bin/env bash
# =============================================================================
#  setup_server.sh
#  Configuración automática de Ubuntu Server (22.04 / 24.04):
#    - Red (Netplan, IP fija)       - Usuarios + SSH con control por IP
#    - DHCP (isc-dhcp-server)       - DNS (BIND9): zona directa, inversa y reenvío AD
#
#  Uso:
#    sudo ./setup_server.sh
#    sudo IFACE=enp0s3 ./setup_server.sh      # forzar la interfaz de red
#
#  Idempotente: se puede ejecutar las veces que haga falta. Solo modifica un
#  fichero si su contenido cambia, y antes guarda una copia <fichero>.bak.<fecha>
# =============================================================================
set -euo pipefail

# =============================================================================
#  VARIABLES GLOBALES
# =============================================================================
readonly HOSTNAME_FQDN_SHORT="N3OONE-001"
readonly DOMAIN="n3oone.local"

readonly SERVER_IP="192.168.1.1"
readonly PREFIX="24"
readonly NETWORK="192.168.1.0"
readonly NETMASK="255.255.255.0"
readonly GATEWAY="192.168.1.1"
readonly DNS_SERVER="192.168.1.1"
IFACE="${IFACE:-}"                                # vacío = autodetección

# DNS externos que usa BIND para resolver Internet
readonly UPSTREAM_DNS="8.8.8.8; 1.1.1.1;"

# Windows Server (Active Directory)
readonly WIN_HOST="win-server"
readonly WIN_IP="192.168.1.2"
readonly WIN_MAC="08:60:6E:E8:24:DE"
readonly AD_DOMAIN="n3oone.com"

# DHCP
readonly DHCP_RANGE_START="192.168.1.3"
readonly DHCP_RANGE_END="192.168.1.224"
readonly DHCP_LEASE_DEFAULT="86400"
readonly DHCP_LEASE_MAX="172800"

# Zona inversa
readonly REVERSE_ZONE="1.168.192.in-addr.arpa"
readonly ZONE_DIR="/etc/bind/zones"
readonly FWD_ZONE_FILE="${ZONE_DIR}/db.${DOMAIN}"
readonly REV_ZONE_FILE="${ZONE_DIR}/db.${REVERSE_ZONE}"

# Usuarios del sistema (en Linux los nombres van en minúscula)
readonly USERS=(marcos n3oone eneko jeremy akram)
readonly DEFAULT_PASSWORD="Cambiame123!"          # se obliga a cambiarla en el primer login

# Reglas SSH (AllowUsers admite usuario o usuario@IP)
readonly SSH_ALLOW="n3oone eneko@192.168.1.4 jeremy@192.168.1.4 akram@192.168.1.2 akram@192.168.1.4"
readonly SSH_DENY="marcos"

# Ficheros de configuración
readonly NETPLAN_FILE="/etc/netplan/01-netcfg.yaml"
readonly SSHD_DROPIN="/etc/ssh/sshd_config.d/10-n3oone.conf"
readonly DHCPD_CONF="/etc/dhcp/dhcpd.conf"
readonly DHCPD_DEFAULT="/etc/default/isc-dhcp-server"
readonly BIND_OPTIONS="/etc/bind/named.conf.options"
readonly BIND_LOCAL="/etc/bind/named.conf.local"

readonly PACKAGES=(openssh-server isc-dhcp-server bind9 bind9utils bind9-dnsutils)
readonly TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
readonly LOG_FILE="/var/log/setup_server.log"

# =============================================================================
#  FUNCIONES AUXILIARES
# =============================================================================
C_OK='\e[32m'; C_WARN='\e[33m'; C_ERR='\e[31m'; C_INFO='\e[36m'; C_RST='\e[0m'

log()     { echo -e "${C_INFO}[INFO]${C_RST}  $*"; }
ok()      { echo -e "${C_OK}[ OK ]${C_RST}  $*"; }
warn()    { echo -e "${C_WARN}[WARN]${C_RST}  $*"; }
die()     { echo -e "${C_ERR}[FAIL]${C_RST}  $*" >&2; exit 1; }
section() { echo -e "\n${C_INFO}==================== $* ====================${C_RST}"; }

trap 'echo -e "${C_ERR}[FAIL]${C_RST}  Error en la línea $LINENO (código $?). Revisa ${LOG_FILE}" >&2' ERR

# Escribe el contenido de stdin en el fichero destino SOLO si cambia.
# Si el fichero ya existía y va a cambiar, se guarda un .bak con fecha.
# Devuelve 0 si el fichero ha cambiado y 1 si ya estaba igual.
write_if_changed() {
    local dest="$1" mode="${2:-644}" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if [[ -f "$dest" ]] && cmp -s "$tmp" "$dest"; then
        rm -f "$tmp"
        log "Sin cambios: $dest"
        return 1
    fi
    mkdir -p "$(dirname "$dest")"
    if [[ -f "$dest" ]]; then
        cp -a "$dest" "${dest}.bak.${TIMESTAMP}"
        log "Copia de seguridad: ${dest}.bak.${TIMESTAMP}"
    fi
    install -m "$mode" "$tmp" "$dest"
    rm -f "$tmp"
    ok "Actualizado: $dest"
    return 0
}

# Número de serie de una zona: solo se incrementa si el contenido cambia.
zone_serial() {
    local file="$1" body_new="$2" old_serial new_serial body_old
    if [[ -f "$file" ]]; then
        old_serial="$(awk '/; Serial/ {print $1; exit}' "$file")"
        body_old="$(grep -v '; Serial' "$file" | grep -v '^; Generado')"
        if [[ -n "$old_serial" && "$body_old" == "$body_new" ]]; then
            echo "$old_serial"; return
        fi
    fi
    new_serial="$(date +%Y%m%d)01"
    if [[ -n "${old_serial:-}" && "$old_serial" -ge "$new_serial" ]]; then
        new_serial=$((old_serial + 1))
    fi
    echo "$new_serial"
}

detect_iface() {
    if [[ -n "$IFACE" ]]; then
        [[ -d "/sys/class/net/$IFACE" ]] || die "La interfaz '$IFACE' no existe."
        return
    fi
    IFACE="$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)"
    if [[ -z "$IFACE" ]]; then
        local n
        for n in /sys/class/net/*; do
            n="${n##*/}"
            [[ "$n" == "lo" || -d "/sys/class/net/$n/wireless" ]] && continue
            if [[ -e "/sys/class/net/$n/device" ]]; then IFACE="$n"; break; fi
        done
    fi
    [[ -n "$IFACE" ]] || die "No se pudo detectar la interfaz. Ejecuta: sudo IFACE=enp0s3 $0"
}

svc_name_bind() {
    if systemctl list-unit-files named.service &>/dev/null; then echo named; else echo bind9; fi
}

# =============================================================================
#  0. COMPROBACIONES PREVIAS
# =============================================================================
preflight() {
    section "Comprobaciones previas"
    [[ $EUID -eq 0 ]] || die "Este script debe ejecutarse como root (sudo $0)."
    grep -qi ubuntu /etc/os-release || warn "El sistema no parece Ubuntu; se continúa igualmente."
    detect_iface
    ok "Interfaz de red: $IFACE"
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        warn "Estás conectado por SSH. Al aplicar la IP ${SERVER_IP} y las reglas SSH puedes perder la sesión."
    fi
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]] && ! grep -qw "$SUDO_USER" <<< "$SSH_ALLOW"; then
        warn "Tu usuario '$SUDO_USER' NO estará permitido por SSH tras la configuración."
    fi
}

# =============================================================================
#  1. PAQUETES (antes de tocar la red: después puede no haber Internet)
# =============================================================================
install_packages() {
    section "Paquetes"
    local missing=() p
    for p in "${PACKAGES[@]}"; do
        dpkg -s "$p" &>/dev/null || missing+=("$p")
    done
    if (( ${#missing[@]} == 0 )); then
        ok "Todos los paquetes ya están instalados"
        return
    fi
    log "Instalando: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    local apt_opts=(-o Acquire::http::Timeout=15 -o Acquire::Retries=2 -o Dpkg::Options::=--force-confold)
    apt-get "${apt_opts[@]}" update
    apt-get "${apt_opts[@]}" install -y "${missing[@]}" \
        || die "No se pudieron instalar los paquetes. ¿Hay salida a Internet? (ping -c2 archive.ubuntu.com)"
    ok "Paquetes instalados"
}

# =============================================================================
#  2. HOSTNAME
# =============================================================================
configure_hostname() {
    section "Hostname"
    if [[ "$(hostname)" != "$HOSTNAME_FQDN_SHORT" ]]; then
        hostnamectl set-hostname "$HOSTNAME_FQDN_SHORT"
        ok "Hostname: $HOSTNAME_FQDN_SHORT"
    else
        log "Hostname ya es $HOSTNAME_FQDN_SHORT"
    fi
    local line="${SERVER_IP} ${HOSTNAME_FQDN_SHORT}.${DOMAIN} ${HOSTNAME_FQDN_SHORT}"
    if ! grep -qxF "$line" /etc/hosts; then
        cp -a /etc/hosts "/etc/hosts.bak.${TIMESTAMP}"
        sed -i "/[[:space:]]${HOSTNAME_FQDN_SHORT}\([[:space:]]\|$\)/d" /etc/hosts
        echo "$line" >> /etc/hosts
        ok "/etc/hosts actualizado"
    fi
}

# =============================================================================
#  3. USUARIOS
# =============================================================================
configure_users() {
    section "Usuarios"
    local u
    for u in "${USERS[@]}"; do
        if id "$u" &>/dev/null; then
            log "El usuario '$u' ya existe"
        else
            useradd -m -s /bin/bash "$u"
            echo "${u}:${DEFAULT_PASSWORD}" | chpasswd
            chage -d 0 "$u"        # cambio de contraseña obligatorio en el primer login
            ok "Usuario creado: $u (home /home/$u)"
        fi
    done
}

# =============================================================================
#  4. SSH
# =============================================================================
configure_ssh() {
    section "SSH"
    # Los ficheros de sshd_config.d se leen antes que sshd_config: el primer valor gana.
    grep -qE '^\s*Include\s+/etc/ssh/sshd_config.d/\*\.conf' /etc/ssh/sshd_config \
        || die "/etc/ssh/sshd_config no incluye sshd_config.d/*.conf"

    write_if_changed "$SSHD_DROPIN" 644 <<EOF || true
# Generado por setup_server.sh — no editar a mano
# Solo pueden iniciar sesión los usuarios listados en AllowUsers.
PermitRootLogin no
AllowUsers ${SSH_ALLOW}
DenyUsers ${SSH_DENY}
MaxAuthTries 3
LoginGraceTime 30
EOF
}

# =============================================================================
#  5. DHCP
# =============================================================================
configure_dhcp() {
    section "DHCP"
    write_if_changed "$DHCPD_CONF" 644 <<EOF || true
# Generado por setup_server.sh — no editar a mano
authoritative;
ddns-update-style none;
default-lease-time ${DHCP_LEASE_DEFAULT};
max-lease-time ${DHCP_LEASE_MAX};

option domain-name "${DOMAIN}";
option domain-name-servers ${DNS_SERVER};

subnet ${NETWORK} netmask ${NETMASK} {
    range ${DHCP_RANGE_START} ${DHCP_RANGE_END};
    option routers ${GATEWAY};
    option subnet-mask ${NETMASK};
    option broadcast-address 192.168.1.255;
}

# Reserva estática: Windows Server (Active Directory)
host ${WIN_HOST} {
    hardware ethernet ${WIN_MAC};
    fixed-address ${WIN_IP};
}
EOF

    write_if_changed "$DHCPD_DEFAULT" 644 <<EOF || true
# Generado por setup_server.sh — no editar a mano
INTERFACESv4="${IFACE}"
INTERFACESv6=""
EOF
}

# =============================================================================
#  6. DNS (BIND9)
# =============================================================================
configure_dns() {
    section "DNS (BIND9)"
    install -d -m 755 -o root -g bind "$ZONE_DIR"

    write_if_changed "$BIND_OPTIONS" 644 <<EOF || true
// Generado por setup_server.sh — no editar a mano
options {
    directory "/var/cache/bind";

    recursion yes;
    allow-query     { localhost; ${NETWORK}/${PREFIX}; };
    allow-recursion { localhost; ${NETWORK}/${PREFIX}; };
    allow-transfer  { none; };

    forwarders { ${UPSTREAM_DNS} };

    // "no" para que las respuestas del AD (${AD_DOMAIN}) no se rechacen por DNSSEC
    dnssec-validation no;

    listen-on    { 127.0.0.1; ${SERVER_IP}; };
    listen-on-v6 { none; };
};
EOF

    write_if_changed "$BIND_LOCAL" 644 <<EOF || true
// Generado por setup_server.sh — no editar a mano

// Zona directa
zone "${DOMAIN}" {
    type master;
    file "${FWD_ZONE_FILE}";
};

// Zona inversa
zone "${REVERSE_ZONE}" {
    type master;
    file "${REV_ZONE_FILE}";
};

// Reenvío del dominio de Active Directory al Windows Server
zone "${AD_DOMAIN}" {
    type forward;
    forward only;
    forwarders { ${WIN_IP}; };
};
EOF

    # ---- Zona directa ----
    local soa_tail fwd_records rev_records serial
    soa_tail="        3600       ; Refresh
        1800       ; Retry
        604800     ; Expire
        86400 )    ; Negative TTL
@       IN  NS     dns.${DOMAIN}."

    fwd_records="@               IN  A      ${SERVER_IP}
server          IN  A      ${SERVER_IP}
ssh             IN  A      ${SERVER_IP}
dns             IN  A      ${SERVER_IP}
wordpress       IN  A      ${WIN_IP}"

    rev_records="1               IN  PTR    ${DOMAIN}.
2               IN  PTR    wordpress.${DOMAIN}."

    local fwd_body rev_body
    fwd_body="\$TTL 86400
@       IN  SOA    dns.${DOMAIN}. admin.${DOMAIN}. (
${soa_tail}
${fwd_records}"
    rev_body="\$TTL 86400
@       IN  SOA    dns.${DOMAIN}. admin.${DOMAIN}. (
${soa_tail}
${rev_records}"

    serial="$(zone_serial "$FWD_ZONE_FILE" "$fwd_body")"
    write_if_changed "$FWD_ZONE_FILE" 644 <<EOF || true
; Generado por setup_server.sh — zona directa ${DOMAIN}
\$TTL 86400
@       IN  SOA    dns.${DOMAIN}. admin.${DOMAIN}. (
        ${serial} ; Serial
${soa_tail}
${fwd_records}
EOF

    serial="$(zone_serial "$REV_ZONE_FILE" "$rev_body")"
    write_if_changed "$REV_ZONE_FILE" 644 <<EOF || true
; Generado por setup_server.sh — zona inversa ${REVERSE_ZONE}
\$TTL 86400
@       IN  SOA    dns.${DOMAIN}. admin.${DOMAIN}. (
        ${serial} ; Serial
${soa_tail}
${rev_records}
EOF
    chown root:bind "$FWD_ZONE_FILE" "$REV_ZONE_FILE"
}

# =============================================================================
#  7. VALIDACIÓN DE SINTAXIS (antes de reiniciar nada)
# =============================================================================
validate_configs() {
    section "Validación de sintaxis"
    mkdir -p /run/sshd
    sshd -t                                   && ok "sshd -t"            || die "Error en la configuración SSH"
    dhcpd -t -cf "$DHCPD_CONF" &>/dev/null    && ok "dhcpd -t"           || { dhcpd -t -cf "$DHCPD_CONF"; die "Error en $DHCPD_CONF"; }
    named-checkconf                           && ok "named-checkconf"    || die "Error en la configuración de BIND"
    named-checkzone "$DOMAIN" "$FWD_ZONE_FILE" >/dev/null       && ok "named-checkzone $DOMAIN"       || die "Error en $FWD_ZONE_FILE"
    named-checkzone "$REVERSE_ZONE" "$REV_ZONE_FILE" >/dev/null && ok "named-checkzone $REVERSE_ZONE" || die "Error en $REV_ZONE_FILE"
}

# =============================================================================
#  8. RED (Netplan)
# =============================================================================
configure_network() {
    section "Red (Netplan)"

    # El gateway es el propio servidor: no se añade ruta por defecto hacia sí mismo.
    local route_block=""
    if [[ "$GATEWAY" != "$SERVER_IP" ]]; then
        route_block="      routes:
        - to: default
          via: ${GATEWAY}"
    fi

    local changed=0
    {
        echo "# Generado por setup_server.sh — no editar a mano"
        echo "network:"
        echo "  version: 2"
        echo "  renderer: networkd"
        echo "  ethernets:"
        echo "    ${IFACE}:"
        echo "      dhcp4: false"
        echo "      dhcp6: false"
        echo "      addresses: [${SERVER_IP}/${PREFIX}]"
        [[ -n "$route_block" ]] && echo "$route_block"
        echo "      nameservers:"
        echo "        addresses: [127.0.0.1]"
        echo "        search: [${DOMAIN}]"
    } | write_if_changed "$NETPLAN_FILE" 600 && changed=1 || true

    # Desactiva otros ficheros netplan que configuren la misma interfaz (evita conflictos)
    local f
    for f in /etc/netplan/*.yaml; do
        [[ -e "$f" && "$f" != "$NETPLAN_FILE" ]] || continue
        if grep -qE "^\s+${IFACE}:" "$f"; then
            mv "$f" "${f}.bak.${TIMESTAMP}"
            warn "Desactivado $f (renombrado a ${f}.bak.${TIMESTAMP})"
            changed=1
        fi
    done

    # Evita que cloud-init regenere la red en el próximo arranque
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
        echo "network: {config: disabled}" | write_if_changed /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg 644 || true
    fi

    netplan generate || die "Netplan rechaza la configuración"
    if (( changed )) || ! ip -4 addr show "$IFACE" | grep -q "inet ${SERVER_IP}/"; then
        log "Aplicando netplan..."
        netplan apply
        sleep 3
    fi
    ip -4 addr show "$IFACE" | grep -q "inet ${SERVER_IP}/" \
        && ok "IP ${SERVER_IP}/${PREFIX} activa en ${IFACE}" \
        || warn "La IP ${SERVER_IP} todavía no aparece en ${IFACE}"
}

# =============================================================================
#  9. SERVICIOS
# =============================================================================
restart_services() {
    section "Servicios"
    local bind_svc; bind_svc="$(svc_name_bind)"

    systemctl daemon-reload
    # Ubuntu 24.04 usa activación por socket para SSH
    if systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket
    fi
    systemctl enable ssh &>/dev/null || true
    systemctl restart ssh

    systemctl enable "$bind_svc" &>/dev/null || true
    systemctl restart "$bind_svc"

    systemctl enable isc-dhcp-server &>/dev/null
    systemctl restart isc-dhcp-server \
        || warn "isc-dhcp-server no arrancó. Revisa: journalctl -u isc-dhcp-server -n 30"
}

# =============================================================================
#  10. RESUMEN FINAL
# =============================================================================
show_status() {
    section "Estado final"
    local svc state bind_svc; bind_svc="$(svc_name_bind)"
    for svc in ssh isc-dhcp-server "$bind_svc"; do
        state="$(systemctl is-active "$svc" 2>/dev/null || true)"
        if [[ "$state" == "active" ]]; then ok "$(printf '%-18s %s' "$svc" "$state")"
        else warn "$(printf '%-18s %s' "$svc" "${state:-desconocido}")"; fi
    done

    echo
    log "Pruebas DNS:"
    local q
    _dig() { dig +short +time=2 +tries=1 @127.0.0.1 "$@" 2>/dev/null | grep -v '^;;' | head -1 || true; }
    for q in server ssh dns wordpress; do
        printf '   %-24s -> %s\n' "${q}.${DOMAIN}" "$(_dig "${q}.${DOMAIN}")"
    done
    printf '   %-24s -> %s\n' "${SERVER_IP} (PTR)" "$(_dig -x "$SERVER_IP")"
    printf '   %-24s -> %s\n' "${WIN_IP} (PTR)"    "$(_dig -x "$WIN_IP")"

    echo
    log "Reglas SSH efectivas:"
    sshd -T 2>/dev/null | grep -Ei '^(allowusers|denyusers|permitrootlogin)' | sed 's/^/   /'

    echo
    ok "Configuración completada. Log: ${LOG_FILE}"
}

# =============================================================================
#  MAIN
# =============================================================================
main() {
    [[ $EUID -eq 0 ]] || die "Este script debe ejecutarse como root (sudo $0)."
    exec > >(tee -a "$LOG_FILE") 2>&1
    echo "===== setup_server.sh — ${TIMESTAMP} ====="

    preflight
    install_packages
    configure_hostname
    configure_users
    configure_ssh
    configure_dhcp
    configure_dns
    validate_configs
    configure_network
    restart_services
    show_status
}

main "$@"
