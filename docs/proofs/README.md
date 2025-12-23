# Preuves (captures)

Ce dossier contient les preuves demandées pour le rendu :
- `pcs_status.png` : sortie `pcs status --full` (cluster OK)
- `vip_page.png` : page servie via la VIP `192.168.56.100`
- `zabbix_dashboard.png` : capture du dashboard Zabbix (“MegaTP - Dashboard”)

Génération automatique (depuis l’hôte Windows, dans `mega-tp_final_en_cour`) :
- `.\scripts\proofs\capture_proofs.ps1`
- `.\scripts\proofs\capture_proofs.ps1 -OpenZabbix` (ouvre aussi les URLs + le dossier pour faire la capture du dashboard)

Les fichiers horodatés (`*_YYYYMMDD_HHMMSS.*`) sont conservés pour l’historique. Les fichiers `*.png` sans date sont les “dernières preuves” (celles à afficher dans `README.md`).


