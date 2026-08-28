#!/bin/bash
# =============================================================================
# deploy.sh
# Script de automatización para desplegar y publicar un servicio con
# Docker + Nginx (proxy inverso) + ngrok en un entorno Killercoda.
#
# Uso: bash deploy.sh
# =============================================================================

set -e

# --- Colores para mensajes ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[AVISO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# =============================================================================
# 1. VALIDACIÓN DE DEPENDENCIAS
# =============================================================================
info "Validando dependencias necesarias..."

command -v docker >/dev/null 2>&1 || { error "Docker no está instalado. Abortando."; exit 1; }
docker compose version >/dev/null 2>&1 || { error "Docker Compose (plugin) no está disponible. Abortando."; exit 1; }
command -v curl >/dev/null 2>&1 || { error "curl no está instalado. Abortando."; exit 1; }

info "Dependencias OK (docker, docker compose, curl)."

# =============================================================================
# 2. DATOS DEL SERVICIO (solicitados al usuario)
# =============================================================================
echo ""
info "=== Configuración del servicio ==="

read -p "Nombre del servicio [laboratorio]: " SERVICE_NAME
SERVICE_NAME=${SERVICE_NAME:-laboratorio}

read -p "Nombre de la imagen Docker [${SERVICE_NAME}-app]: " IMAGE_NAME
IMAGE_NAME=${IMAGE_NAME:-${SERVICE_NAME}-app}

read -p "Nombre del contenedor de la app [${SERVICE_NAME}-app]: " APP_CONTAINER
APP_CONTAINER=${APP_CONTAINER:-${SERVICE_NAME}-app}

read -p "Puerto interno de la aplicación [8080]: " APP_PORT
APP_PORT=${APP_PORT:-8080}

read -p "Puerto del proxy inverso (Nginx, expuesto al host) [8082]: " NGINX_PORT
NGINX_PORT=${NGINX_PORT:-8082}

echo ""
info "=== Variables de entorno para la base de datos ==="

read -p "Nombre de la base de datos [${SERVICE_NAME}_backend]: " DB_NAME
DB_NAME=${DB_NAME:-${SERVICE_NAME}_backend}

read -p "Usuario de la base de datos [root]: " DB_USER
DB_USER=${DB_USER:-root}

read -s -p "Contraseña de la base de datos: " DB_PASSWORD
echo ""
if [ -z "$DB_PASSWORD" ]; then
    error "La contraseña de la base de datos no puede estar vacía. Abortando."
    exit 1
fi

read -s -p "Contraseña root de MySQL [igual a la anterior]: " MYSQL_ROOT_PASSWORD
echo ""
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD:-$DB_PASSWORD}

# =============================================================================
# 3. DATOS DE NGROK
# =============================================================================
echo ""
info "=== Configuración de ngrok ==="

read -s -p "Token de autenticación de ngrok: " NGROK_TOKEN
echo ""
if [ -z "$NGROK_TOKEN" ]; then
    error "El token de ngrok no puede estar vacío. Abortando."
    exit 1
fi

read -p "¿Usar un dominio fijo de ngrok? (dejar vacío si no aplica): " NGROK_DOMAIN

# =============================================================================
# 4. GENERACIÓN DE ARCHIVOS
# =============================================================================
echo ""
info "Generando archivos de configuración..."

WORKDIR="./${SERVICE_NAME}-deploy"
mkdir -p "${WORKDIR}/nginx"
cd "${WORKDIR}"

# --- .env ---
cat > .env <<EOF
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}
DB_NAME=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
NGINX_PORT=${NGINX_PORT}
APP_PORT=${APP_PORT}
EOF

# --- nginx/default.conf ---
cat > nginx/default.conf <<EOF
server {
    listen 80;

    location / {
        proxy_pass http://${APP_CONTAINER}:${APP_PORT};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF

# --- docker-compose.yml ---
cat > docker-compose.yml <<EOF
services:
  mysql:
    image: mysql:8.0
    container_name: ${SERVICE_NAME}-db
    environment:
      MYSQL_ROOT_PASSWORD: \${MYSQL_ROOT_PASSWORD}
      MYSQL_DATABASE: \${DB_NAME}
    networks:
      - ${SERVICE_NAME}-net
    volumes:
      - mysql_data:/var/lib/mysql
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost", "-u", "root", "-p\${MYSQL_ROOT_PASSWORD}"]
      interval: 5s
      timeout: 5s
      retries: 10

  app:
    build: ${SOURCE_DIR:-.}
    image: ${IMAGE_NAME}
    container_name: ${APP_CONTAINER}
    environment:
      SPRING_DATASOURCE_URL: jdbc:mysql://mysql:3306/\${DB_NAME}
      SPRING_DATASOURCE_USERNAME: \${DB_USERNAME}
      SPRING_DATASOURCE_PASSWORD: \${DB_PASSWORD}
      SPRING_JPA_HIBERNATE_DDL_AUTO: update
    depends_on:
      mysql:
        condition: service_healthy
    networks:
      - ${SERVICE_NAME}-net

  nginx:
    image: nginx:alpine
    container_name: ${SERVICE_NAME}-nginx
    ports:
      - "\${NGINX_PORT}:80"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
    depends_on:
      - app
    networks:
      - ${SERVICE_NAME}-net

networks:
  ${SERVICE_NAME}-net:
    driver: bridge

volumes:
  mysql_data:
EOF

info "Archivos generados en ${WORKDIR}/"

# =============================================================================
# 5. VALIDAR QUE EXISTE EL CÓDIGO FUENTE / DOCKERFILE
# =============================================================================
if [ ! -f "../Dockerfile" ] && [ ! -f "./Dockerfile" ]; then
    warn "No se encontró un Dockerfile en el directorio del proyecto."
    read -p "Ruta al directorio con el código fuente y Dockerfile del servicio: " SOURCE_DIR
    if [ ! -f "${SOURCE_DIR}/Dockerfile" ]; then
        error "No se encontró Dockerfile en ${SOURCE_DIR}. Abortando."
        exit 1
    fi
    # Reescribir el build context en el compose ya generado
    sed -i "s|build: .|build: ${SOURCE_DIR}|" docker-compose.yml
else
    cp ../Dockerfile . 2>/dev/null || true
fi

# =============================================================================
# 6. CONSTRUCCIÓN Y DESPLIEGUE CON DOCKER
# =============================================================================
echo ""
info "Construyendo imagen y levantando contenedores..."
docker compose up -d --build

info "Esperando a que los servicios estén saludables..."
sleep 5

docker compose ps

# =============================================================================
# 7. VALIDACIÓN DEL SERVICIO Y DEL PROXY
# =============================================================================
echo ""
info "Validando que el servicio responde a través de Nginx (puerto ${NGINX_PORT})..."

MAX_RETRIES=10
RETRY=0
until curl -s -o /dev/null -w "%{http_code}" "http://localhost:${NGINX_PORT}/" | grep -qE "^[0-9]"; do
    RETRY=$((RETRY+1))
    if [ "$RETRY" -ge "$MAX_RETRIES" ]; then
        error "El servicio no respondió después de ${MAX_RETRIES} intentos."
        docker compose logs app
        exit 1
    fi
    sleep 3
done

info "Servicio y proxy respondiendo correctamente en http://localhost:${NGINX_PORT}"

# =============================================================================
# 8. INSTALACIÓN Y CONFIGURACIÓN DE NGROK
# =============================================================================
echo ""
info "Verificando instalación de ngrok..."

if ! command -v ngrok >/dev/null 2>&1; then
    warn "ngrok no está instalado. Instalando..."
    curl -sSL https://ngrok-agent.s3.amazonaws.com/ngrok.asc \
        | sudo tee /etc/apt/trusted.gpg.d/ngrok.asc >/dev/null
    echo "deb https://ngrok-agent.s3.amazonaws.com buster main" \
        | sudo tee /etc/apt/sources.list.d/ngrok.list
    sudo apt update -y && sudo apt install -y ngrok
fi

info "Configurando token de autenticación de ngrok..."
ngrok config add-authtoken "${NGROK_TOKEN}"

# =============================================================================
# 9. INICIO DEL TÚNEL
# =============================================================================
echo ""
info "Iniciando túnel ngrok hacia el puerto ${NGINX_PORT}..."

if [ -n "$NGROK_DOMAIN" ]; then
    nohup ngrok http --domain="${NGROK_DOMAIN}" "${NGINX_PORT}" > ngrok.log 2>&1 &
else
    nohup ngrok http "${NGINX_PORT}" > ngrok.log 2>&1 &
fi

sleep 5

# =============================================================================
# 10. VALIDACIÓN DE LA PUBLICACIÓN EXTERNA
# =============================================================================
info "Obteniendo URL pública..."

PUBLIC_URL=""
RETRY=0
while [ -z "$PUBLIC_URL" ] && [ "$RETRY" -lt 10 ]; do
    PUBLIC_URL=$(curl -s http://localhost:4040/api/tunnels | grep -o '"public_url":"[^"]*"' | head -n1 | cut -d'"' -f4)
    if [ -z "$PUBLIC_URL" ]; then
        RETRY=$((RETRY+1))
        sleep 2
    fi
done

if [ -z "$PUBLIC_URL" ]; then
    error "No se pudo obtener la URL pública de ngrok. Revisa ngrok.log"
    exit 1
fi

info "Validando acceso a través de la URL pública..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${PUBLIC_URL}")

if [[ "$HTTP_CODE" =~ ^[23] ]]; then
    info "Publicación externa validada correctamente (HTTP ${HTTP_CODE})."
else
    warn "La URL pública respondió con código HTTP ${HTTP_CODE}. Verifica manualmente."
fi

# =============================================================================
# 11. RESUMEN FINAL
# =============================================================================
echo ""
echo "============================================================"
echo -e "${GREEN}DESPLIEGUE COMPLETADO${NC}"
echo "============================================================"
echo "Servicio:          ${SERVICE_NAME}"
echo "URL local:          http://localhost:${NGINX_PORT}"
echo "URL pública ngrok:  ${PUBLIC_URL}"
echo "============================================================"
echo ""
echo "Para detener el entorno:"
echo "  cd ${WORKDIR} && docker compose down"
echo "  kill %1   # detiene el proceso de ngrok"
echo ""
