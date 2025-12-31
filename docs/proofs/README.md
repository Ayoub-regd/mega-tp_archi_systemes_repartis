# Preuves (`docs/proofs`)

Objectif : fournir au correcteur des preuves simples, lisibles et reproductibles.

## Fichiers canoniques (versionnes)

- `docs/proofs/pcs_status.png` : sortie `pcs status --full` (cluster OK)
- `docs/proofs/vip_page.png` : page servie via la VIP `http://192.168.56.100/`
- `docs/proofs/zabbix_http.png` : check HTTP du front Zabbix (preuve de disponibilite)
- `docs/proofs/zabbix_dashboard.png` : capture du dashboard Zabbix **MegaTP - Dashboard** (capture manuelle)

## Dossiers d'archive (non versionnes)

- `docs/proofs/archive/<runid>/` : fichiers horodates generes automatiquement par `capture_proofs.ps1` (utile pour debug).
- `docs/proofs/archive/_local/<runid>/` : rangement local genere par `finalize_proofs.ps1 -Archive` (doublons, captures diverses).

## Generation

Depuis l'hote Windows (PowerShell) a la racine du projet :

- `.\scripts\proofs\capture_proofs.ps1`
- `.\scripts\proofs\capture_proofs.ps1 -OpenZabbix` (ouvre aussi les URLs + le dossier pour faire la capture dashboard)

Le script genere des fichiers horodates (utile pour debug) dans `docs/proofs/archive/<runid>/` puis met a jour les preuves canoniques ci-dessus.

## Archivage local

Pour eviter d'encombrer le repo avec des doublons (horodates restants dans `docs/proofs/` ou `docs/proofs/zabbix/`), archive-les en local :

- `.\scripts\proofs\finalize_proofs.ps1 -Archive`

Archive : `docs/proofs/archive/` (ignore par Git via `.gitignore`).
