# Firma estable para conservar permisos de privacidad

## Objetivo
La app perdía Input Monitoring, Accesibilidad y Cámara en cada instalación/relanzamiento. macOS (TCC) asocia los permisos al requisito de firma (designated requirement). Con firma ad hoc ese requisito es el hash del binario, que cambia en cada build.

## Archivos modificados
- `scripts/install-app.sh`: elige automáticamente una identidad válida (no revocada) Developer ID o Apple Development del llavero, o usa `SIGN_IDENTITY`; avisa si no hay ninguna.
- `scripts/sign-app.sh`: las identidades Apple Development (hash o nombre) se firman con runtime y `--timestamp=none`; Developer ID mantiene timestamp seguro (notarización).

## Lógica
Requisito de firma resultante: `identifier "app.machid.MacHID" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: ..."`. Es constante entre builds mientras se use el mismo certificado.

## Decisiones / riesgos
- Los certificados Apple Development no sirven para distribuir ni notarizar; solo estabilizan permisos en este Mac. Para GitHub Releases se necesita Developer ID (o un certificado autofirmado estable en CI).
- Una sola vez hay que volver a conceder los permisos (los grants antiguos eran de la firma ad hoc). Cambiar de certificado en el futuro los reinicia otra vez.
- Si el certificado Apple Development caduca o se revoca, los permisos se pierden al re-firmar.

## Pruebas
- Instalación con `scripts/install-app.sh`; `codesign -dvv` y `codesign -d -r-` confirman la firma y el requisito estable.
- Pendiente (manual): conceder permisos, reinstalar y confirmar que persisten.
