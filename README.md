# backup_docker.sh

Script en Bash para realizar un respaldo de un entorno Docker.

## Como activar el Timer de systemd del script backup de docker

1. Guarda los archivos en

- /etc/systemd/system/backup-docker.service
- /etc/systemd/system/backup-docker.timer

3. Recarga systemd para que detecte los nuevos archivos
```bash
sudo systemctl daemon-reload
```

3. Habilita el timer (para que se inicie automáticamente al arrancar el servidor)
```bash
sudo systemctl enable backup-docker.timer
sudo systemctl start backup-docker.timer
```

5. Verificar el timer
```bash
systemctl list-timers backup-docker.timer
```

6. Revisar logs del propio timer
```bash
sudo journalctl -u backup-docker.service
```
