# backup_completo_semanal_docker.sh

Script en Bash para realizar un respaldo completo semanal de un entorno Docker. Guarda volúmenes, imágenes, configuraciones de contenedores, archivos de Docker Compose y el volumen de Portainer (si existe).

## 📦 ¿Qué respalda?

- Todos los **volúmenes Docker** activos, comprimidos en `.tar.gz`.
- Todas las **imágenes Docker** etiquetadas (excluye `<none>`), exportadas en `.tar`.
- La **configuración completa** (`docker inspect`) de cada contenedor.
- El volumen persistente de **Portainer**, si está presente.
- Archivos de **Docker Compose**, desde una ruta fija (`/data/compose`).

## 🛠️ Requisitos

- Bash
- Docker
- Imagen Alpine (se descarga automáticamente si no está presente)
- Permisos adecuados (root o usuario en el grupo `docker`)
- Hay que dejar el .sh en /usr/local/bin/ 

## 📂 Estructura de salida

El script crea un directorio con la fecha actual en `/var/backups`, por ejemplo:

/var/backups/docker_backup_completo_2025-09-15/ 
├── docker_compose_files_2025-09-15.tar.gz 
├── images/ 
│ ├── nombre__imagen__tag.tar 
│ └── ... 
├── inspect/ 
│ ├── contenedor_id.json 
│ └── ... 
├── portainer_data_2025-09-15.tar.gz 
└── volumen_nombre_2025-09-15.tar.gz

## 🕒 Automatización con cron

⚠️ Importante: La tarea debe estar definida en el crontab del usuario root, ya que requieren acceso completo a volúmenes, contenedores y rutas protegidas. Para editar el crontab de root:

sudo crontab -e


0 3 * * 0 /usr/local/bin/backup_completo_semanal_docker.sh >> /var/log/docker_backup.log 2>&1

- Este cron realiza el backup todos los domingos a las 3:00 AM


