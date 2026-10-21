# M13: releases automáticos sin notarización y autoupdate

## Objetivo
Publicar un release en cada push a `master` sin cuenta de pago de Apple (sin Developer ID ni notarización) y mantener el autoupdate (Sparkle) funcionando.

## Archivos modificados
- `.github/workflows/release.yml`: ya no depende de secretos de firma ni del entorno `release`; construye con firma ad hoc, empaqueta DMG + zip del CLI, genera `appcast.xml` si existe `SPARKLE_ED_PRIVATE_KEY` y siempre crea el release.
- `scripts/make-app.sh`: toma la clave pública de Sparkle de `Resources/sparkle-public-key.txt` si no viene por variable.
- `Resources/sparkle-public-key.txt` (nuevo): clave pública EdDSA (no es secreta).
- `docs/RELEASE.md`: nuevo modelo de publicación e instrucciones de configuración.

## Lógica y decisiones
- Gatekeeper bloquea la primera ejecución; el release lo explica en sus notas. Sparkle verifica la firma EdDSA, no la firma de código, por lo que funciona con firma ad hoc; las actualizaciones descargadas por Sparkle no llevan cuarentena.
- Se quitó el entorno `release` para que la publicación no espere aprobaciones; la clave privada de Sparkle es un secreto de repositorio.
- El par de claves se generó localmente; la privada se exportó a `~/machid-sparkle-private-key` (permisos 600) para que el propietario la cargue como secreto y la respalde.

## Riesgos / pendiente
- Sin el secreto `SPARKLE_ED_PRIVATE_KEY` no hay `appcast.xml`: el autoupdate no ve versiones nuevas (el workflow avisa).
- Si la clave privada se pierde hay que cambiar la pública y reinstalar a mano.
- El flujo no se ha ejecutado en GitHub todavía; se valida con el primer push.
- Sparkle "latest": los releases del registro (`registry-*`) deben seguir marcados como no latest.

## Pruebas
Revisión del workflow y de `make-app.sh` (construcción local); verificación real en el primer push y en la primera actualización entre dos releases.
