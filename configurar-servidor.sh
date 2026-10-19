#!/usr/bin/env bash
# =====================================================================
#  configurar-servidor.sh
#  Configura automáticamente un Ubuntu Server: IP fija, SSH, DHCP y DNS.
#  Todos los datos se leen de un fichero de configuración (servidor.conf),
#  así que el mismo script sirve para cualquier servidor.
#
#  Uso:
#    sudo ./configurar-servidor.sh                    # usa ./servidor.conf
#    sudo ./configurar-servidor.sh -c otro.conf       # otro fichero
#    sudo ./configurar-servidor.sh -s ssh,dns         # solo algunos servicios
#    sudo ./configurar-servidor.sh -n                 # simulación: genera los
#                                                     # ficheros en ./salida-prueba
#                                                     # sin tocar el sistema
#    sudo ./configurar-servidor.sh -y                 # no pide confirmación
#
#  Probado en Ubuntu Server 22.04 y 24.04.
# =====================================================================
set -euo pipefail

# ---------------------------------------------------------------------
#  Utilidades
# ---------------------------------------------------------------------
VERDE='\e[32m'; AMARILLO='\e[33m'; ROJO='\e[31m'; AZUL='\e[36m'; NC='\e[0m'
info()  { echo -e "${AZUL}[INFO]${NC}  $*"; }
ok()    { echo -e "${VERDE}[OK]${NC}    $*"; }
aviso() { echo -e "${AMARILLO}[AVISO]${NC} $*"; }
error() { echo -e "${ROJO}[ERROR]${NC} $*" >&2; exit 1; }
titulo(){ echo -e "\n${AZUL}========== $* ==========${NC}"; }

uso() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0; }

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FICHERO_CONF="$DIR_SCRIPT/servidor.conf"
SOLO=""
SIMULACION="no"
SIN_PREGUNTAR="no"
FECHA="$(date +%Y%m%d-%H%M%S)"

while getopts ":c:s:nyh" opt; do
  case $opt in
    c) FICHERO_CONF="$OPTARG" ;;
    s) SOLO="$OPTARG" ;;
    n) SIMULACION="si" ;;
    y) SIN_PREGUNTAR="si" ;;
    h) uso ;;
    *) error "Opción no válida. Usa -h para ver la ayuda." ;;
  esac
done

[[ -f "$FICHERO_CONF" ]] || error "No encuentro el fichero de configuración: $FICHERO_CONF"
# shellcheck source=/dev/null
source "$FICHERO_CONF"

# Valores por defecto si faltan en el .conf
: "${CONFIGURAR_RED:=no}" "${CONFIGURAR_SSH:=no}" "${CONFIGURAR_DHCP:=no}"
: "${CONFIGURAR_DNS:=no}" "${CONFIGURAR_FIREWALL:=no}"
: "${SSH_PUERTO:=22}" "${SSH_PERMITIR_ROOT:=no}" "${SSH_CREAR_USUARIOS:=no}"
: "${DHCP_TIEMPO_CONCESION:=86400}" "${DNS_DNSSEC:=no}" "${INTERFAZ:=}"
: "${DNS_REENVIADORES:=8.8.8.8}" "${DNS_SERVIDOR:=127.0.0.1}"
declare -p SSH_USUARIOS      &>/dev/null || SSH_USUARIOS=()
declare -p DHCP_RESERVAS     &>/dev/null || DHCP_RESERVAS=()
declare -p DNS_REGISTROS     &>/dev/null || DNS_REGISTROS=()
declare -p DNS_ZONAS_REENVIO &>/dev/null || DNS_ZONAS_REENVIO=()

# -s ssh,dns  -> sobreescribe lo que diga el .conf
if [[ -n "$SOLO" ]]; then
  CONFIGURAR_RED=no; CONFIGURAR_SSH=no; CONFIGURAR_DHCP=no; CONFIGURAR_DNS=no; CONFIGURAR_FIREWALL=no
  IFS=',' read -ra _s <<< "$SOLO"
  for s in "${_s[@]}"; do
    case "${s,,}" in
      red) CONFIGURAR_RED=si ;; ssh) CONFIGURAR_SSH=si ;; dhcp) CONFIGURAR_DHCP=si ;;
      dns) CONFIGURAR_DNS=si ;; firewall|ufw) CONFIGURAR_FIREWALL=si ;;
      *) error "Servicio desconocido en -s: $s (válidos: red,ssh,dhcp,dns,firewall)" ;;
    esac
  done
fi

# En simulación todo se escribe bajo ./salida-prueba en vez de en /
RAIZ=""
if [[ "$SIMULACION" == "si" ]]; then
  RAIZ="$DIR_SCRIPT/salida-prueba"
  mkdir -p "$RAIZ"
  aviso "MODO SIMULACIÓN: no se instala ni se reinicia nada. Ficheros en $RAIZ"
else
  [[ $EUID -eq 0 ]] || error "Ejecuta el script como root (sudo)."
fi

# ---------------------------------------------------------------------
#  Funciones de red / validación
# ---------------------------------------------------------------------
es_ip() {
  local ip=$1 o
  [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}
es_ip_o_cidr() {
  local v=$1
  if [[ $v == */* ]]; then es_ip "${v%/*}" && [[ ${v#*/} =~ ^[0-9]+$ ]] && (( ${v#*/} <= 32 )); else es_ip "$v"; fi
}
es_mac() { [[ $1 =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; }

prefijo_a_mascara() {
  local p=$1 m="" i
  for i in 1 2 3 4; do
    if   (( p >= 8 )); then m+=255; p=$((p-8))
    else m+=$(( 256 - 2**(8-p) )); p=0; fi
    [[ $i -lt 4 ]] && m+=.
  done
  echo "$m"
}

ip_a_num() { local IFS=.; read -r a b c d <<< "$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }

ip_en_red() {  # ip_en_red IP RED/PREFIJO
  local ip red pref mask
  ip=$(ip_a_num "$1"); red=$(ip_a_num "${2%/*}"); pref=${2#*/}
  mask=$(( pref == 0 ? 0 : (0xFFFFFFFF << (32-pref)) & 0xFFFFFFFF ))
  (( (ip & mask) == (red & mask) ))
}

# Copia de seguridad del fichero antes de tocarlo (una por ejecución)
respaldo() {
  local f="$RAIZ$1"
  if [[ -f "$f" && ! -f "$f.bak-$FECHA" ]]; then
    cp -a "$f" "$f.bak-$FECHA"
    info "Copia de seguridad: $1.bak-$FECHA"
  fi
}

escribir() {  # escribir RUTA  (contenido por stdin)
  local f="$RAIZ$1"
  mkdir -p "$(dirname "$f")"
  respaldo "$1"
  cat > "$f"
}

instalar() {
  if [[ "$SIMULACION" == "si" ]]; then info "(simulación) apt-get install $*"; return; fi
  local falta=()
  for p in "$@"; do dpkg -s "$p" &>/dev/null || falta+=("$p"); done
  if (( ${#falta[@]} )); then
    info "Instalando: ${falta[*]}"
    export DEBIAN_FRONTEND=noninteractive
    local opts=(-o Acquire::http::Timeout=15 -o Acquire::Retries=1)
    apt-get "${opts[@]}" update \
      || error "No se pudo actualizar la lista de paquetes. ¿Tiene el servidor salida a Internet? (prueba: ping -c2 8.8.8.8)"
    apt-get "${opts[@]}" install -y "${falta[@]}" \
      || error "No se pudieron instalar: ${falta[*]}. Comprueba la conexión a Internet."
  fi
}

# Descarga TODOS los paquetes antes de tocar la red: después de poner la
# IP fija el servidor puede quedarse sin salida a Internet.
instalar_todo() {
  local paquetes=()
  [[ "$CONFIGURAR_SSH"      == "si" ]] && paquetes+=(openssh-server)
  [[ "$CONFIGURAR_DHCP"     == "si" ]] && paquetes+=(isc-dhcp-server)
  [[ "$CONFIGURAR_DNS"      == "si" ]] && paquetes+=(bind9 bind9utils bind9-dnsutils)
  [[ "$CONFIGURAR_FIREWALL" == "si" ]] && paquetes+=(ufw)
  (( ${#paquetes[@]} )) || return 0
  titulo "Paquetes"
  instalar "${paquetes[@]}"
  ok "Paquetes listos"
}

servicio() {  # servicio ACCIÓN NOMBRE
  if [[ "$SIMULACION" == "si" ]]; then info "(simulación) systemctl $1 $2"; return; fi
  systemctl "$1" "$2"
}

# ---------------------------------------------------------------------
#  Validación general de la configuración
# ---------------------------------------------------------------------
titulo "Comprobando configuración ($FICHERO_CONF)"
[[ $RED =~ ^([0-9.]+)/(8|16|24)$ ]] || error "RED debe ser tipo 192.168.1.0/24 (máscaras /8, /16 o /24)."
RED_BASE="${RED%/*}"; PREFIJO="${RED#*/}"; MASCARA=$(prefijo_a_mascara "$PREFIJO")
es_ip "$RED_BASE"    || error "RED no válida: $RED"
es_ip "$IP_SERVIDOR" || error "IP_SERVIDOR no válida: $IP_SERVIDOR"
ip_en_red "$IP_SERVIDOR" "$RED" || error "IP_SERVIDOR ($IP_SERVIDOR) no pertenece a $RED"

if [[ -z "$INTERFAZ" ]]; then
  INTERFAZ=$(ip -o -4 route show to default 2>/dev/null | awk '{print $5; exit}' || true)
  if [[ -z "$INTERFAZ" ]]; then
    for n in /sys/class/net/*; do
      n=${n##*/}; [[ $n == lo || -d /sys/class/net/$n/wireless ]] && continue
      [[ -e /sys/class/net/$n/device ]] && { INTERFAZ=$n; break; }
    done
  fi
  [[ -n "$INTERFAZ" ]] || error "No pude detectar la interfaz de red. Ponla en INTERFAZ=..."
  info "Interfaz detectada: $INTERFAZ"
fi

echo
echo "  Servidor : $NOMBRE_HOST ($IP_SERVIDOR en $INTERFAZ, red $RED)"
echo "  Red=$CONFIGURAR_RED  SSH=$CONFIGURAR_SSH  DHCP=$CONFIGURAR_DHCP  DNS=$CONFIGURAR_DNS  Firewall=$CONFIGURAR_FIREWALL"
echo
if [[ "$SIN_PREGUNTAR" != "si" && "$SIMULACION" != "si" ]]; then
  read -rp "¿Continuar? [s/N] " r; [[ ${r,,} == s* ]] || { echo "Cancelado."; exit 0; }
fi

# =====================================================================
#  1. RED (IP fija con netplan)
# =====================================================================
configurar_red() {
  titulo "Red: IP fija $IP_SERVIDOR/$PREFIJO"
  es_ip "$GATEWAY" || error "GATEWAY no válido: $GATEWAY"

  local dns_yaml="" d
  for d in $DNS_SERVIDOR; do es_ip "$d" || error "DNS_SERVIDOR no válido: $d"; dns_yaml+="$d, "; done
  dns_yaml="[${dns_yaml%, }]"

  # Si el gateway es el propio servidor no se añade ruta por defecto
  local ruta=""
  if [[ "$GATEWAY" != "$IP_SERVIDOR" ]]; then
    ruta=$'      routes:\n        - to: default\n          via: '"$GATEWAY"
  else
    aviso "El GATEWAY es el propio servidor: no se añade ruta por defecto en el servidor."
  fi

  # Se desactivan otros ficheros netplan que configuren la misma interfaz
  if [[ "$SIMULACION" != "si" ]]; then
    for f in /etc/netplan/*.yaml; do
      [[ -e $f && $f != /etc/netplan/01-servidor-auto.yaml ]] || continue
      if grep -q "$INTERFAZ" "$f"; then
        mv "$f" "$f.desactivado-$FECHA"; info "Desactivado $f (renombrado)"
      fi
    done
    # Evita que cloud-init vuelva a sobreescribir la red
    if [[ -d /etc/cloud/cloud.cfg.d ]]; then
      echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
    fi
  fi

  escribir /etc/netplan/01-servidor-auto.yaml <<EOF
# Generado por configurar-servidor.sh el $FECHA
network:
  version: 2
  renderer: networkd
  ethernets:
    $INTERFAZ:
      dhcp4: false
      addresses: [$IP_SERVIDOR/$PREFIJO]
${ruta}
      nameservers:
        addresses: $dns_yaml
        search: [${DNS_DOMINIO:-local}]
EOF
  sed -i '/^$/d' "$RAIZ/etc/netplan/01-servidor-auto.yaml"
  chmod 600 "$RAIZ/etc/netplan/01-servidor-auto.yaml"

  if [[ "$SIMULACION" != "si" ]]; then
    hostnamectl set-hostname "$NOMBRE_HOST" 2>/dev/null || true
    if ! grep -qE "^[0-9.]+\s+.*\b$NOMBRE_HOST\b" /etc/hosts; then
      echo "$IP_SERVIDOR $NOMBRE_HOST.${DNS_DOMINIO:-local} $NOMBRE_HOST" >> /etc/hosts
    fi
    netplan generate || error "netplan no acepta la configuración."
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
      aviso "Estás conectado por SSH: si la IP cambia perderás la sesión. Reconecta a $IP_SERVIDOR."
    fi
    netplan apply
  fi
  ok "Red configurada"
}

# =====================================================================
#  2. SSH
# =====================================================================
configurar_ssh() {
  titulo "SSH"
  instalar openssh-server

  local permitidos=() denegados=() entrada usuario acceso ip
  for entrada in "${SSH_USUARIOS[@]}"; do
    usuario="${entrada%%:*}"; usuario="${usuario,,}"
    acceso="${entrada#*:}"
    [[ $usuario =~ ^[a-z_][a-z0-9_-]*$ ]] || error "Nombre de usuario no válido: $usuario"

    case "${acceso,,}" in
      denegado|no|ninguno)
        denegados+=("$usuario") ;;
      cualquiera|todas|any|"*")
        permitidos+=("$usuario") ;;
      *)
        IFS=',' read -ra ips <<< "$acceso"
        for ip in "${ips[@]}"; do
          ip="${ip// /}"
          es_ip_o_cidr "$ip" || error "IP no válida para $usuario: $ip"
          permitidos+=("$usuario@$ip")
        done ;;
    esac

    # Crear el usuario si no existe
    if [[ "$SSH_CREAR_USUARIOS" == "si" && "$SIMULACION" != "si" ]] && ! id "$usuario" &>/dev/null; then
      useradd -m -s /bin/bash "$usuario"
      echo "$usuario:$SSH_PASSWORD_INICIAL" | chpasswd
      chage -d 0 "$usuario"   # obliga a cambiar la contraseña al entrar
      ok "Usuario creado: $usuario (debe cambiar la contraseña en el primer acceso)"
    fi
  done

  (( ${#permitidos[@]} )) || error "Ningún usuario tendría acceso SSH. Revisa SSH_USUARIOS."

  # Aviso para no quedarse fuera del servidor
  local yo="${SUDO_USER:-}"
  if [[ -n "$yo" && "$yo" != root ]] && ! printf '%s\n' "${permitidos[@]}" | grep -qE "^$yo(@|$)"; then
    aviso "Tu usuario ($yo) NO estará en la lista de acceso SSH."
    if [[ "$SIN_PREGUNTAR" != "si" && "$SIMULACION" != "si" ]]; then
      read -rp "¿Seguro que quieres continuar? [s/N] " r; [[ ${r,,} == s* ]] || error "Cancelado para no perder el acceso."
    fi
  fi

  # Fichero en sshd_config.d: en Ubuntu se lee antes que el principal, así que manda
  escribir /etc/ssh/sshd_config.d/10-servidor-auto.conf <<EOF
# Generado por configurar-servidor.sh el $FECHA
# Solo pueden entrar los usuarios listados en AllowUsers (usuario o usuario@IP).
Port $SSH_PUERTO
PermitRootLogin $SSH_PERMITIR_ROOT
AllowUsers ${permitidos[*]}
$( (( ${#denegados[@]} )) && echo "DenyUsers ${denegados[*]}" )
MaxAuthTries 3
LoginGraceTime 30
EOF

  if [[ "$SIMULACION" != "si" ]]; then
    mkdir -p /run/sshd
    sshd -t || error "La configuración de SSH no es válida (no se ha reiniciado el servicio)."
    systemctl daemon-reload
    systemctl is-active --quiet ssh.socket && systemctl restart ssh.socket || true
    systemctl enable ssh &>/dev/null || true
    systemctl restart ssh
  fi

  echo "  Permitidos: ${permitidos[*]}"
  (( ${#denegados[@]} )) && echo "  Denegados : ${denegados[*]}"
  ok "SSH configurado"
}

# =====================================================================
#  3. DHCP (isc-dhcp-server)
# =====================================================================
configurar_dhcp() {
  titulo "DHCP"
  local v
  for v in DHCP_RANGO_INICIO DHCP_RANGO_FIN DHCP_GATEWAY; do
    es_ip "${!v}" || error "$v no válido: ${!v}"
  done
  ip_en_red "$DHCP_RANGO_INICIO" "$RED" && ip_en_red "$DHCP_RANGO_FIN" "$RED" \
    || error "El rango DHCP no pertenece a $RED"
  (( $(ip_a_num "$DHCP_RANGO_INICIO") <= $(ip_a_num "$DHCP_RANGO_FIN") )) || error "DHCP_RANGO_INICIO es mayor que DHCP_RANGO_FIN"

  local dns_dhcp="" d
  for d in ${DHCP_DNS//,/ }; do es_ip "$d" || error "DHCP_DNS no válido: $d"; dns_dhcp+="$d, "; done
  dns_dhcp="${dns_dhcp%, }"

  instalar isc-dhcp-server

  # Reservas (IP fijas por MAC)
  local reservas="" r nombre resto mac ipf
  for r in "${DHCP_RESERVAS[@]}"; do
    nombre="${r%%:*}"; resto="${r#*:}"
    ipf="${resto##*:}"; mac="${resto%:*}"
    es_mac "$mac" || error "MAC no válida en reserva '$r'"
    es_ip "$ipf"  || error "IP no válida en reserva '$r'"
    ip_en_red "$ipf" "$RED" || error "La reserva $ipf no pertenece a $RED"
    reservas+="
host $nombre {
  hardware ethernet $mac;
  fixed-address $ipf;
}
"
  done

  escribir /etc/dhcp/dhcpd.conf <<EOF
# Generado por configurar-servidor.sh el $FECHA
authoritative;
default-lease-time $DHCP_TIEMPO_CONCESION;
max-lease-time $(( DHCP_TIEMPO_CONCESION * 2 ));
ddns-update-style none;
option domain-name "${DHCP_DOMINIO:-local}";
option domain-name-servers $dns_dhcp;

subnet $RED_BASE netmask $MASCARA {
  range $DHCP_RANGO_INICIO $DHCP_RANGO_FIN;
  option routers $DHCP_GATEWAY;
  option subnet-mask $MASCARA;
}
$reservas
EOF

  escribir /etc/default/isc-dhcp-server <<EOF
# Generado por configurar-servidor.sh el $FECHA
INTERFACESv4="$INTERFAZ"
INTERFACESv6=""
EOF

  if [[ "$SIMULACION" != "si" ]]; then
    dhcpd -t -cf /etc/dhcp/dhcpd.conf &>/dev/null || { dhcpd -t -cf /etc/dhcp/dhcpd.conf; error "dhcpd.conf no es válido."; }
    systemctl enable isc-dhcp-server &>/dev/null
    systemctl restart isc-dhcp-server || aviso "isc-dhcp-server no arrancó: comprueba que $INTERFAZ tiene la IP $IP_SERVIDOR (journalctl -u isc-dhcp-server)."
  fi
  echo "  Rango: $DHCP_RANGO_INICIO - $DHCP_RANGO_FIN | Gateway: $DHCP_GATEWAY | DNS: $dns_dhcp"
  ok "DHCP configurado"
}

# =====================================================================
#  4. DNS (bind9) — zona directa, zona inversa y reenvíos
# =====================================================================
configurar_dns() {
  titulo "DNS"
  [[ -n "${DNS_DOMINIO:-}" ]] || error "DNS_DOMINIO está vacío."
  instalar bind9 bind9utils bind9-dnsutils

  local serie dir_zonas zona_inv fichero_dir fichero_inv
  serie=$(date +%s)   # siempre crece, así los cambios se aplican
  dir_zonas=/etc/bind/zonas
  mkdir -p "$RAIZ$dir_zonas"

  # Nombre de la zona inversa según la máscara (/24 -> 1.168.192.in-addr.arpa)
  IFS=. read -r o1 o2 o3 _ <<< "$RED_BASE"
  case $PREFIJO in
    24) zona_inv="$o3.$o2.$o1.in-addr.arpa" ;;
    16) zona_inv="$o2.$o1.in-addr.arpa" ;;
    8)  zona_inv="$o1.in-addr.arpa" ;;
  esac
  fichero_dir="$dir_zonas/db.$DNS_DOMINIO"
  fichero_inv="$dir_zonas/db.$zona_inv"

  # --- Registros A y PTR ---
  local registros_a="" registros_ptr="" reg nombre ip a b c dd parte
  for reg in "${DNS_REGISTROS[@]}"; do
    nombre="${reg%%:*}"; ip="${reg#*:}"
    es_ip "$ip" || error "IP no válida en registro DNS '$reg'"
    registros_a+="$(printf '%-20s IN  A    %s' "$nombre" "$ip")"$'\n'
    if ip_en_red "$ip" "$RED"; then
      IFS=. read -r a b c dd <<< "$ip"
      case $PREFIJO in 24) parte="$dd" ;; 16) parte="$dd.$c" ;; 8) parte="$dd.$c.$b" ;; esac
      registros_ptr+="$(printf '%-12s IN  PTR  %s.%s.' "$parte" "$nombre" "$DNS_DOMINIO")"$'\n'
    else
      aviso "$nombre ($ip) está fuera de $RED: no se crea su PTR."
    fi
  done

  # Asegura que el propio servidor DNS (ns1) tiene registro
  local cabecera
  cabecera="\$TTL 86400
@   IN  SOA  ns1.$DNS_DOMINIO. admin.$DNS_DOMINIO. (
        $serie ; Serial
        3600       ; Refresh
        1800       ; Retry
        604800     ; Expire
        86400 )    ; TTL negativo
@   IN  NS   ns1.$DNS_DOMINIO."

  escribir "$fichero_dir" <<EOF
; Zona directa $DNS_DOMINIO — generado por configurar-servidor.sh el $FECHA
$cabecera
$(printf '%-20s IN  A    %s' ns1 "$IP_SERVIDOR")
$registros_a
EOF

  escribir "$fichero_inv" <<EOF
; Zona inversa $zona_inv — generado por configurar-servidor.sh el $FECHA
$cabecera
$registros_ptr
EOF

  # --- named.conf.local ---
  local reenvios="" z dom dns_ext
  for z in "${DNS_ZONAS_REENVIO[@]}"; do
    dom="${z%%:*}"; dns_ext="${z#*:}"
    es_ip "$dns_ext" || error "IP no válida en zona de reenvío '$z'"
    reenvios+="
// Dominio resuelto por otro servidor DNS
zone \"$dom\" {
    type forward;
    forward only;
    forwarders { $dns_ext; };
};
"
  done

  escribir /etc/bind/named.conf.local <<EOF
// Generado por configurar-servidor.sh el $FECHA
zone "$DNS_DOMINIO" {
    type master;
    file "$fichero_dir";
};

zone "$zona_inv" {
    type master;
    file "$fichero_inv";
};
$reenvios
EOF

  # --- named.conf.options ---
  local fw="" f
  for f in $DNS_REENVIADORES; do es_ip "$f" || error "DNS_REENVIADORES no válido: $f"; fw+="$f; "; done

  escribir /etc/bind/named.conf.options <<EOF
// Generado por configurar-servidor.sh el $FECHA
options {
    directory "/var/cache/bind";

    recursion yes;
    allow-query     { localhost; $RED; };
    allow-recursion { localhost; $RED; };
    allow-transfer  { none; };

    forwarders { $fw};

    dnssec-validation $DNS_DNSSEC;
    listen-on { 127.0.0.1; $IP_SERVIDOR; };
    listen-on-v6 { none; };
};
EOF

  if [[ "$SIMULACION" != "si" ]]; then
    chown -R root:bind "$dir_zonas"; chmod 644 "$dir_zonas"/db.*
    named-checkconf || error "La configuración de bind9 no es válida."
    named-checkzone "$DNS_DOMINIO" "$fichero_dir" >/dev/null || error "Error en la zona $DNS_DOMINIO"
    named-checkzone "$zona_inv"    "$fichero_inv" >/dev/null || error "Error en la zona $zona_inv"
    systemctl enable named &>/dev/null || systemctl enable bind9 &>/dev/null || true
    systemctl restart named 2>/dev/null || systemctl restart bind9
  fi

  echo "  Zona directa : $DNS_DOMINIO"
  echo "  Zona inversa : $zona_inv"
  ok "DNS configurado"
}

# =====================================================================
#  5. FIREWALL (ufw)
# =====================================================================
configurar_firewall() {
  titulo "Firewall (ufw)"
  instalar ufw
  if [[ "$SIMULACION" == "si" ]]; then info "(simulación) ufw allow $SSH_PUERTO/tcp, 53, 67/udp"; return; fi
  ufw allow "$SSH_PUERTO/tcp" comment 'SSH' >/dev/null
  [[ "$CONFIGURAR_DNS"  == "si" ]] && ufw allow 53 comment 'DNS' >/dev/null
  [[ "$CONFIGURAR_DHCP" == "si" ]] && ufw allow 67/udp comment 'DHCP' >/dev/null
  ufw --force enable >/dev/null
  ok "Firewall activo"
}

# =====================================================================
#  Ejecución
# =====================================================================
instalar_todo
[[ "$CONFIGURAR_RED"      == "si" ]] && configurar_red
[[ "$CONFIGURAR_SSH"      == "si" ]] && configurar_ssh
[[ "$CONFIGURAR_DHCP"     == "si" ]] && configurar_dhcp
[[ "$CONFIGURAR_DNS"      == "si" ]] && configurar_dns
[[ "$CONFIGURAR_FIREWALL" == "si" ]] && configurar_firewall

titulo "Terminado"
if [[ "$SIMULACION" == "si" ]]; then
  echo "Revisa los ficheros generados en: $RAIZ"
else
  echo "Comprobaciones rápidas:"
  [[ "$CONFIGURAR_DNS"  == "si" ]] && echo "  dig @127.0.0.1 server.$DNS_DOMINIO      |  dig @127.0.0.1 -x $IP_SERVIDOR"
  [[ "$CONFIGURAR_DHCP" == "si" ]] && echo "  systemctl status isc-dhcp-server       |  cat /var/lib/dhcp/dhcpd.leases"
  [[ "$CONFIGURAR_SSH"  == "si" ]] && echo "  sshd -T | grep -Ei 'allowusers|denyusers'"
  echo "Las copias de seguridad de los ficheros modificados terminan en .bak-$FECHA"
fi
