#!/usr/bin/env bash
#
# Levanta el API Gateway y permite indicar la IP y el puerto de cada microservicio.
#
# Uso interactivo:   ./run.sh
# Uso sin preguntas: PRODUCT_SERVICE_HOST=192.168.1.50 PRODUCT_SERVICE_PORT=9000 ./run.sh < /dev/null
#   (si una variable ya viene definida, se usa como valor sugerido en la pregunta)

SERVICE_DIR="api_gateway"
GATEWAY_PORT="${GATEWAY_PORT:-8081}"
LOG_DIR="${LOG_DIR:-./logs}"
LOG="$LOG_DIR/api_gateway.log"
STARTUP_TIMEOUT=120
PID=""

# Microservicios: "PREFIJO_VARIABLE:nombre:puerto_por_defecto"
# (los puertos por defecto son los mismos de api_gateway/src/main/resources/application.yaml)
MICROSERVICES=(
    "USER_SERVICE:user-service:8861"
    "PRODUCT_SERVICE:product-service:8862"
    "PAYMENT_SERVICE:payment-service:8863"
    "VENDOR_SERVICE:vendor-service:8864"
    "CONTRACTOR_SERVICE:contractor-service:8865"
)

cd "$(dirname "$0")" || exit 1

# ---------------------------------------------------------------- utilidades

info()  { echo "[INFO] $*"; }
warn()  { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

# IPv4 con formato xxx.yyy.zzz.ccc y cada octeto entre 0 y 255
is_valid_ip() {
    local ip="$1" octet
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for octet in "${BASH_REMATCH[@]:1}"; do
        ((10#$octet <= 255)) || return 1
    done
}

is_valid_port() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
    else
        (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
    fi
}

# --------------------------------------------------------- detener al salir

cleanup() {
    trap - SIGINT SIGTERM EXIT
    if [[ -n "$PID" ]] && kill -0 "$PID" 2>/dev/null; then
        echo
        info "Deteniendo api_gateway..."
        pkill -TERM -P "$PID" 2>/dev/null
        kill -TERM "$PID" 2>/dev/null

        # si no se detiene en 15 s, se fuerza
        for _ in {1..15}; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$PID" 2>/dev/null; then
            warn "No se detuvo a tiempo, forzando cierre."
            pkill -KILL -P "$PID" 2>/dev/null
            kill -KILL "$PID" 2>/dev/null
        fi
        wait "$PID" 2>/dev/null
        info "api_gateway detenido."
    fi
}

trap 'cleanup; exit 130' SIGINT
trap 'cleanup; exit 143' SIGTERM
trap cleanup EXIT

# ------------------------------------------------------------- diagnóstico

# Revisa el log del gateway y explica la causa probable del fallo.
diagnose() {
    local found=0

    echo
    echo "==================== DIAGNÓSTICO ===================="

    if [[ ! -s "$LOG" ]]; then
        echo "- El log está vacío: el proceso no llegó a arrancar."
        found=1
    fi

    if grep -qiE "Port [0-9]+ was already in use|Address already in use" "$LOG" 2>/dev/null; then
        echo "- El puerto $GATEWAY_PORT ya está en uso por otro proceso."
        echo "  Revisa cuál con:  ss -ltnp | grep :$GATEWAY_PORT"
        echo "  O usa otro puerto: GATEWAY_PORT=8090 ./run.sh"
        found=1
    fi

    if grep -qiE "COMPILATION ERROR|Compilation failure" "$LOG" 2>/dev/null; then
        echo "- Error de compilación en el código del gateway. Detalle:"
        grep -E "\[ERROR\] .*\.java" "$LOG" | head -n 10 | sed 's/^/    /'
        found=1
    fi

    if grep -qiE "release version [0-9]+ not supported|UnsupportedClassVersionError|invalid target release" "$LOG" 2>/dev/null; then
        echo "- La versión de Java no es compatible. El proyecto necesita Java 25."
        echo "  Versión actual: $(java -version 2>&1 | head -n 1)"
        found=1
    fi

    if grep -qiE "Could not resolve dependencies|Could not transfer artifact|Unknown host|Connection timed out" "$LOG" 2>/dev/null; then
        echo "- Maven no pudo descargar dependencias. Revisa la conexión a internet"
        echo "  o un proxy/firewall que bloquee repo.maven.apache.org."
        found=1
    fi

    if grep -qiE "Could not resolve placeholder" "$LOG" 2>/dev/null; then
        echo "- Falta una variable de configuración:"
        grep -oE "Could not resolve placeholder '[^']+'" "$LOG" | sort -u | sed 's/^/    /'
        found=1
    fi

    if grep -qiE "issuer|jwk|auth0" "$LOG" 2>/dev/null && grep -qiE "Exception|ERROR" "$LOG" 2>/dev/null \
        && grep -iE "issuer|jwk|auth0" "$LOG" | grep -qiE "unable|failed|error|refused|timed out"; then
        echo "- Problema al contactar Auth0 (issuer-uri). Revisa la conexión a internet y"
        echo "  que issuer-uri en application.yaml sea correcto (incluida la '/' final)."
        found=1
    fi

    if grep -qiE "Permission denied|AccessDeniedException" "$LOG" 2>/dev/null; then
        echo "- Error de permisos sobre archivos. Probablemente se ejecutó antes con sudo."
        echo "  Corrige con:  sudo chown -R \"\$USER\" \"$SERVICE_DIR/target\" \"$LOG_DIR\""
        found=1
    fi

    if grep -qiE "APPLICATION FAILED TO START" "$LOG" 2>/dev/null; then
        echo "- Spring Boot reportó el siguiente motivo:"
        sed -n '/APPLICATION FAILED TO START/,/^Action:/{/Description:/,/^Action:/p}' "$LOG" \
            | grep -v '^Action:' | sed '/^\s*$/d' | head -n 10 | sed 's/^/    /'
        found=1
    fi

    if ((found == 0)); then
        echo "- No se identificó una causa conocida. Revisa las últimas líneas del log."
    fi

    echo
    echo "---- Últimas 30 líneas de $LOG ----"
    tail -n 30 "$LOG" 2>/dev/null
    echo "====================================================="
}

# ------------------------------------------------- verificaciones previas

preflight() {
    local ok=0

    if [[ ! -d "$SERVICE_DIR" ]]; then
        error "No se encontró el directorio $SERVICE_DIR."
        ok=1
    elif [[ ! -x "$SERVICE_DIR/mvnw" ]]; then
        error "$SERVICE_DIR/mvnw no existe o no tiene permisos de ejecución."
        echo "        Corrige con:  chmod +x $SERVICE_DIR/mvnw"
        ok=1
    fi

    if ! command -v java >/dev/null 2>&1 && [[ -z "$JAVA_HOME" ]]; then
        error "Java no está instalado o no está en el PATH (se necesita Java 25)."
        ok=1
    else
        local java_bin="${JAVA_HOME:+$JAVA_HOME/bin/}java" version
        version=$("$java_bin" -version 2>&1 | head -n 1 | grep -oE '"[0-9]+' | tr -d '"')
        if [[ -n "$version" ]] && ((version < 25)); then
            error "Java $version detectado; el proyecto necesita Java 25 o superior."
            ok=1
        fi
    fi

    if ! is_valid_port "$GATEWAY_PORT"; then
        error "GATEWAY_PORT='$GATEWAY_PORT' no es un puerto válido."
        ok=1
    elif port_in_use "$GATEWAY_PORT"; then
        error "El puerto $GATEWAY_PORT ya está en uso. ¿Hay otro gateway corriendo?"
        echo "        Revisa con:  ss -ltnp | grep :$GATEWAY_PORT"
        ok=1
    fi

    mkdir -p "$LOG_DIR" 2>/dev/null
    if ! touch "$LOG" 2>/dev/null; then
        error "No se puede escribir en $LOG (permisos)."
        echo "        Corrige con:  sudo chown -R \"\$USER\" \"$LOG_DIR\""
        ok=1
    fi

    if [[ -d "$SERVICE_DIR/target" && ! -w "$SERVICE_DIR/target" ]]; then
        error "No se puede escribir en $SERVICE_DIR/target (permisos)."
        echo "        Corrige con:  sudo chown -R \"\$USER\" \"$SERVICE_DIR/target\""
        ok=1
    fi

    return $ok
}

# -------------------------------------------- configuración de microservicios

configure_microservices() {
    local interactive=0
    [[ -t 0 ]] && interactive=1

    echo
    echo "=========== Ubicación de los microservicios ==========="
    if ((interactive)); then
        echo "IP en formato xxx.yyy.zzz.ccc (ej: 192.168.1.50)."
        echo "Si la dejas vacía o no tiene ese formato, se usará localhost."
        echo "Si dejas el puerto vacío o no es válido, se usará el valor entre []."
    fi
    echo

    local entry var name default_port host port input_host input_port
    for entry in "${MICROSERVICES[@]}"; do
        IFS=: read -r var name default_port <<<"$entry"

        # valores previos desde variables de entorno (si existen)
        local host_var="${var}_HOST" port_var="${var}_PORT"
        host="${!host_var:-}"
        port="${!port_var:-$default_port}"

        if ((interactive)); then
            read -r -p "  $name - IP [${host:-localhost}]: " input_host
            input_host="${input_host:-$host}"
            read -r -p "  $name - puerto [$port]: " input_port
            input_port="${input_port:-$port}"
        else
            input_host="$host"
            input_port="$port"
        fi

        if [[ -z "$input_host" || "$input_host" == "localhost" ]]; then
            host="localhost"
        elif is_valid_ip "$input_host"; then
            host="$input_host"
        else
            warn "'$input_host' no tiene formato xxx.yyy.zzz.ccc; se usará localhost."
            host="localhost"
        fi

        if is_valid_port "$input_port"; then
            port="$((10#$input_port))"
        else
            warn "'$input_port' no es un puerto válido (1-65535); se usará $default_port."
            port="$default_port"
        fi

        export "$host_var=$host" "$port_var=$port"
    done

    echo
    info "Rutas configuradas:"
    for entry in "${MICROSERVICES[@]}"; do
        IFS=: read -r var name _ <<<"$entry"
        local hv="${var}_HOST" pv="${var}_PORT"
        printf "         %-20s -> http://%s:%s\n" "$name" "${!hv}" "${!pv}"
    done
    echo
}

# ------------------------------------------------------------------ arranque

start_gateway() {
    info "Iniciando api_gateway en el puerto $GATEWAY_PORT..."

    (
        cd "$SERVICE_DIR" || exit 1
        export SERVER_PORT="$GATEWAY_PORT"
        exec ./mvnw spring-boot:run
    ) >"$LOG" 2>&1 &
    PID=$!

    info "PID: $PID   Log: $LOG"
}

wait_for_gateway() {
    local code
    info "Esperando a que api_gateway responda (máx. ${STARTUP_TIMEOUT}s; la primera vez Maven puede tardar más)..."

    for ((i = 1; i <= STARTUP_TIMEOUT; i++)); do
        if ! kill -0 "$PID" 2>/dev/null; then
            wait "$PID"
            local status=$?
            # Maven devuelve 0 aunque la aplicación falle al iniciar, por eso solo se muestra si no es 0
            error "api_gateway terminó durante el arranque$( ((status != 0)) && echo " (código de salida: $status)")."
            diagnose
            return 1
        fi

        # cualquier respuesta HTTP (incluido 401) significa que está arriba
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://localhost:$GATEWAY_PORT/" 2>/dev/null)
        if [[ -n "$code" && "$code" != "000" ]]; then
            info "api_gateway disponible en http://localhost:$GATEWAY_PORT"
            return 0
        fi

        sleep 1
    done

    error "api_gateway no respondió después de ${STARTUP_TIMEOUT}s."
    diagnose
    return 1
}

# --------------------------------------------------------------------- main

preflight || { error "Corrige los problemas anteriores y vuelve a ejecutar."; exit 1; }
configure_microservices
start_gateway
wait_for_gateway || exit 1

info "Presiona Ctrl+C para detenerlo."

while kill -0 "$PID" 2>/dev/null; do
    sleep 2
done

wait "$PID"
status=$?
PID=""
error "api_gateway se detuvo inesperadamente (código de salida: $status)."
diagnose
exit 1
