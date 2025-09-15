#!/bin/bash
# backup_completo_semanal_docker.sh

# Creamos directorio de backups con fecha
BACKUP_DIR="/var/backups/docker_backup_completo_$(date +%F)"
mkdir -p "$BACKUP_DIR"

# Backup de volúmenes Docker
for VOLUME in $(docker volume ls -q); do
docker run --rm -v $VOLUME:/data -v "$BACKUP_DIR":/backup alpine \
    tar czf "/backup/${VOLUME}_$(date +%F).tar.gz" /data
    touch "$BACKUP_DIR/${VOLUME}.stamp"
done

# Backup de imágenes Docker
mkdir -p "$BACKUP_DIR/images"
for IMAGE in $(docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>"); do
    SAFE_NAME=$(echo "$IMAGE" | tr "/:" "__")
    docker save "$IMAGE" -o "$BACKUP_DIR/images/${SAFE_NAME}.tar"
done

# Backup de configuración de contenedores
echo "Backup de configuración de contenedores..."
mkdir -p "$BACKUP_DIR/inspect"
for ID in $(docker ps -a -q); do
    docker inspect "$ID" > "$BACKUP_DIR/inspect/${ID}.json"
    echo "Configuración guardada para contenedor $ID"
done

# Backup de configuración de Portainer (si usa volumen persistente)
echo "Backup de volumen de Portainer..."
if docker volume ls -q | grep -q "portainer_data"; then
docker run --rm -v portainer_data:/data -v "$BACKUP_DIR":/backup alpine \
    tar czf "/backup/portainer_data_$(date +%F).tar.gz" /data
    echo "Volumen portainer_data respaldado."
else
    echo "Volumen portainer_data no encontrado."
fi

# Backup de archivos Docker Compose (igual esta ruta hay que ajustarla)
COMPOSE_DIR="/data/compose"
if [ -d "$COMPOSE_DIR" ]; then
    echo "Backup de archivos Docker Compose..."
    tar czf "$BACKUP_DIR/docker_compose_files_$(date +%F).tar.gz" -C "$COMPOSE_DIR" .
else
    echo "Ruta de Docker Compose no encontrada: $COMPOSE_DIR"
fi

# Finalizado
echo "Backup completo guardado en: $BACKUP_DIR"
