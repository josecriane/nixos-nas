# Plan de refactor — nixos-nas

Análisis del 2026-09-02. Todo lo que se afirma aquí está verificado ejecutando
comandos sobre el repo, no inferido de la lectura.

## Estado de partida

Repo pequeño (21 ficheros `.nix`), `flake.lock` limpio (7 nodos, un solo árbol de
nixpkgs, `disko` y `agenix` ya siguen a `nixpkgs`), `.git` en 720 KB, y un CI que
**sí construye** la configuración de ejemplo, cosa que no hace el de nixos-k8s.

Tiene un problema de corrección serio y varios de estilo.

---

## 1. `builtins.getEnv "PWD"` hace que el sistema dependa del directorio de trabajo

Esto es lo grave y hay que arreglarlo primero.

`flake.nix`:

```nix
projectDir = builtins.getEnv "PWD";
impureSecrets =
  if projectDir != "" && builtins.pathExists "${projectDir}/secrets" then
    builtins.path { path = "${projectDir}/secrets"; ... }
  else
    null;
```

Y `modules/samba-setup.nix:15`:

```nix
sambaSecretPath =
  if secretsPath != null then secretsPath + "/${machineName}/samba-password.age" else null;
sambaSecretExists = sambaSecretPath != null && builtins.pathExists sambaSecretPath;

age.secrets = mkIf sambaSecretExists { ... };
systemd.services.samba-setup-password = mkIf sambaSecretExists { ... };
```

Encadenando las dos cosas: **si la contraseña de Samba se configura o no depende de
desde qué directorio lances el build.** Construyendo desde el repo con el `.age`
presente, el servicio existe. Construyendo desde otro sitio, en modo puro, o desde
CI, el servicio **desaparece sin decir nada**. No hay error, no hay warning: el NAS
simplemente arranca sin la contraseña configurada.

Es justo la clase de fallo que los flakes existen para evitar, y es invisible hasta
que alguien no puede montar un share.

Hoy no está mordiendo porque `secrets/` solo contiene `secrets.example.nix` (verificado),
así que `impureSecrets` acaba en un directorio vacío o en `null` en ambos casos y el
`.drv` sale idéntico. En cuanto se genere el primer `samba-password.age`, empieza a
morder.

### Qué hacer

Quitar `getEnv` del flake y pasar `secretsPath` explícitamente, igual que ya hace
`mkNasMachine` cuando se usa como librería. Para el modo standalone, dos opciones:

- **Trackear los `.age` en git** (están cifrados, es lo que hace nixos-config y es la
  práctica normal con agenix). Entonces `secretsPath = "${self}/secrets"` y se acabó
  la impureza. Requiere quitar `secrets/*/*.age` del `.gitignore`.
- Si prefieres no trackearlos, que `secretsPath` sea un argumento obligatorio del
  modo standalone y que el flake **falle con un mensaje claro** si falta, en vez de
  degradar en silencio.

En cualquiera de los dos casos, `sambaSecretExists` no debe decidirse con
`builtins.pathExists`. Que sea una opción explícita del `config.nix` de la máquina
(`samba.passwordSecret = true;`), para que la ausencia del fichero sea un error de
build y no una funcionalidad que se evapora.

Con eso desaparece también el `--impure` del CI.

---

## 2. El CI necesita `--impure` y no tiene `checks`

`.github/workflows/check.yml`:

```yaml
- run: nix flake check --impure --all-systems
- run: nix build .#nixosConfigurations.example.config.system.build.toplevel --impure --no-link
```

Lo bueno: **construye de verdad** el ejemplo, así que hay cobertura real. Verificado
que `nixosConfigurations.example` evalúa también en modo puro:

```
/nix/store/8fxswscaima244knx9w2q5kwnn4fj1ki-nixos-system-nixos-nas-26.11.20260819.ffb3c9b.drv
```

Lo mejorable:

- El `--impure` es consecuencia directa del punto 1. Al arreglarlo, se cae solo.
- No hay salida `checks`, así que `nix flake check` no construye nada por su cuenta;
  la cobertura viene del paso `nix build` escrito a mano. Moverlo a `checks` deja el
  CI en una sola línea y hace que `nix flake check` sirva también en local:

```nix
checks.${system} = nixpkgs.lib.mapAttrs (
  _: cfg: cfg.config.system.build.toplevel
) self.nixosConfigurations;
```

- No se comprueba el formato. Ya expones `formatter`, así que basta con añadir
  `nix fmt -- --ci`.

Además, los `examples/config-*.nix` y `examples/disko-*.nix` no los ejercita nada.
Merece la pena construir al menos `config-full.nix`, que es el que activa todos los
servicios y por tanto el que más código toca.

---

## 3. `nasConfig` sin tipar

13 accesos defensivos con `or`, con defaults duplicados:

```
3 × nasConfig.services.filebrowser or false
3 × nasConfig.services.cockpit or false
2 × nasConfig.services.monitoring or false
2 × nasConfig.services.authentikIntegration or false
1 × nasConfig.dataDisks or [ ]
```

Solo 3 ficheros del repo usan `mkOption`. Un typo en `config.nix`
(`filebowser = true`) evalúa sin quejarse y deja el servicio apagado en silencio.

La solución es la misma que en los otros dos repos: `modules/options.nix` con
`options.nas.*` tipado, alimentado desde el attrset (`config.nas = nasConfig;`).

**Aviso comprobado empíricamente:** los `imports` condicionales no pueden leer
`config` ni `pkgs` (recursión infinita, el propio sistema de módulos lo dice). Aquí
afecta poco porque `flake.nix` importa los 10 módulos incondicionalmente y cada uno
se auto-desactiva con `mkIf`, que es el patrón correcto. Mantenerlo así.

---

## 4. `with lib;` en tres módulos

`modules/reverse-proxy.nix`, `modules/webui.nix`, `modules/samba-setup.nix` abren con
`with lib;`. Está desaconsejado desde hace años: mete todo `lib` en el scope, hace que
un nombre no resuelto falle lejos de donde se escribió y empeora los mensajes de error.

Sustituir por `inherit (lib) mkIf mkOption types ...` con lo que cada fichero use.
Son tres ficheros, es mecánico.

---

## 5. Limpieza mecánica

**22 argumentos de módulo declarados y no usados**, entre ellos:

```
configuration.nix        lib, pkgs, config
modules/networking.nix   lib, pkgs, config
modules/monitoring.nix   pkgs, config
modules/users.nix        lib
```

Riesgo cero, una pasada.

---

## 6. `.gitignore`: dos avisos

```
# Flake lock file (uncomment if you want to version it)
# flake.lock
```

`flake.lock` está trackeado ahora mismo (verificado), que es lo correcto. Ese
comentario invita a hacer lo contrario, que rompería la reproducibilidad del repo
entero. Yo lo borraría para que nadie lo descomente por error.

```
secrets/*/*.age
```

Es lo que fuerza el `getEnv` del punto 1. Si se opta por trackear los `.age`
cifrados, esta línea se va.

---

## Orden sugerido

1. **Punto 1** (`getEnv` fuera) — es corrección, no estética; el resto puede esperar
2. **Punto 2** (`checks` + quitar `--impure` + comprobar formato)
3. **Puntos 4 y 5** (`with lib;` y args sin usar) — mecánicos
4. **Punto 3** (opciones tipadas) — el grande, con el CI ya cubriendo

Tras cada paso, confirmar que no cambia nada:

```sh
nix build --no-link .#nixosConfigurations.example.config.system.build.toplevel
nix store diff-closures <antes> <después>
```

---

# Actualización tras refactorizar nixos-k8s (2026-09-03)

## Corrección: los argumentos sin usar son 14, no 22

La cifra original salió de un `grep -E` que en aquella shell estaba envuelto por
`ugrep -G`, así que la regex extendida no se aplicaba y contaba de más. Recuento
real con `grep -w`: **14**.

## Receta de opciones tipadas, ya validada en nixos-k8s

Para el punto 3 de este plan. Esto es lo que funcionó allí, con las trampas que
costó encontrar:

1. **Aplicar los defaults una sola vez en la entrada**, no con un `or` en cada
   sitio. En `mkNasMachine`:

   ```nix
   cfg = lib.recursiveUpdate (import ./modules/nas-defaults.nix) nasConfig;
   ```

   Con eso `nasConfig` llega completo a los módulos y **desaparecen los 13 `or`**
   de golpe, sin tener que importar un fichero de defaults por medio repo.

   Esto además arregla de raíz la discrepancia con 282: hoy su glue pone
   `monitoring = true` mientras nixos-nas pone `false`. Con un único origen, el
   valor deja de depender de quién rellene la clave.

2. **`freeformType = types.attrs` es obligatorio** si algún consumidor añade
   claves propias. 282 construye el record `nasConfig` a mano en su `flake.nix`,
   así que conviene comprobar qué claves manda antes de cerrar el esquema.

3. **El sistema de módulos solo comprueba el tipo cuando alguien lee la opción.**
   Una clave que solo se consuma desde el specialArg crudo nunca valida su tipo.
   Se fuerza con un `deepSeq` en `assertions`.

4. **`imports` no puede leer `config` ni `pkgs`** (recursión infinita). Aquí
   afecta poco, porque `flake.nix` importa los 10 módulos incondicionalmente y
   cada uno se auto-desactiva con `mkIf`, que es el patrón correcto.

## Al añadir `checks` (punto 2)

Los `examples/config-*.nix` no los ejercita nada. En nixos-k8s, tener solo la
variante por defecto escondió una regresión real, porque el ejemplo trae los
servicios desactivados y media base de código no se compilaba. Aquí pasa igual:
merece la pena una variante con `config-full.nix`, que enciende todo, además de
la mínima.

---

# Ejecución (2026-09-03)

Puntos 1, 2, 3, 4, 5 y 6 hechos. Todo verificado como no-op: el `example`
construye **byte a byte idéntico** a la línea base.

## El punto 1 no era hipotético: está mordiendo en 282 ahora mismo

El plan decía que `pathExists` + `getEnv` podían hacer que la contraseña de Samba
desapareciera en silencio. Comprobado sobre el homelab real:

```
$ nix eval '.#nixosConfigurations.nas1.config.systemd.services' --apply 'x: x ? samba-setup-password'
false
$ nix eval '.#nixosConfigurations.nas1.config.age.secrets' --apply 'x: x ? samba-password'
false
```

**nas1 y nas2 corren sin contraseña de Samba configurada**, aunque
`secrets/nas1/samba-password.age` existe en el repo de 282.

La causa no está en nixos-nas sino en el filtro de 282:

```nix
secretsPath = builtins.path {
  path = ./secrets;
  filter = _: type: type == "regular";   # descarta TODOS los directorios
};
```

Los secretos de samba viven en `secrets/nas1/`, un directorio, así que nunca
llegan al store. El filtro de nixos-nas sí lo hacía bien
(`t == "directory" || ...`). **Arreglo en 282: añadir `type == "directory"` al
filtro.**

### Lo que se cambió aquí

- `getEnv "PWD"` fuera; el modo standalone usa `secretsPath = "${self}/secrets"`
- `samba-setup.nix` ahora **avisa en tiempo de build** cuando no encuentra el
  secreto, en vez de no generar el servicio y callarse. Verificado que el aviso
  cae exactamente sobre el fallo real de 282 y apunta a la causa:

  ```
  evaluation warning: nixos-nas: no Samba password secret for 'nas1' at
  /nix/store/.../homelab-secrets/nas1/samba-password.age. ... If the file does
  exist in your repo, check that whatever builds secretsPath is not filtering
  out directories.
  ```

Se dejó como aviso y no como aserción a propósito: un error de build en un NAS en
producción por un secreto ausente es peor que el aviso, y el script del servicio
ya degrada bien en runtime.

## Puntos 2, 4, 5, 6

- `checks.${system}` con dos variantes: `example` y `example-full`
  (`examples/config-full.nix`, que enciende cockpit, filebrowser y authentik).
  Sin la segunda, media base de código no se compilaba.
- CI: fuera `--impure` y `--all-systems`, dentro `nix fmt -- --ci`. Ahora es
  `nix flake check` a secas y construye las dos variantes.
- `with lib;` eliminado de los tres módulos, sustituido por `inherit (lib) ...`.
- 14 argumentos sin usar (no 22, ver corrección arriba), verificando build tras
  cada uno.
- `.gitignore`: fuera el comentario que invitaba a dejar de versionar
  `flake.lock`.

## Punto 3: esquema tipado

`modules/nas-defaults.nix` (origen único) + `modules/options.nix`, con los
defaults aplicados **una vez** en `mkNasMachine` vía `recursiveUpdate`. Con eso
los `or` desaparecen del todo (0 restantes).

Validación comprobada:

```
monitoring = "si"        -> is not of type `boolean'
puid = "mil"             -> is not of type `signed integer'
dataDisks = "disk1"      -> is not of type `list of string'
nameservers = "1.1.1.1"  -> is not of type `list of string'
```

Dos decisiones que conviene conocer:

1. **El namespace es `machine`, no `nas`.** `nas` ya estaba ocupado:
   `webui.nix` declara `options.nas.webui` y `reverse-proxy.nix`
   `options.nas.reverseProxy`. Conviven por el merge del sistema de módulos,
   pero mezclar el config de entrada con las opciones de feature bajo el mismo
   prefijo es pedir un fallo raro, sobre todo con `freeformType`, donde un typo
   cae en la parte libre sin avisar.

2. **`freeformType` es necesario**: 282 manda claves que nixos-nas no declara.

## Hallazgo: 282 manda tres claves que no lee nadie

`podCidr`, `serviceCidr` y `clusterIPs` los construye `mkNasConfig` en el
`flake.nix` de 282 y **no los usa ningún módulo de nixos-nas** (verificado con
grep sobre todo el repo). Son inofensivas (caen en el freeform), pero engañan al
leer el glue. Anotado en el plan de 282.

## Hallazgo: `services.samba` y `services.nfs` no se honran

282 y `config-full.nix` los mandan, pero ningún módulo los lee:
`modules/services.nix` hace `services.samba.enable = true` incondicionalmente.
Poner `samba = false` no apaga nada. No se tocó porque cambiarlo **sí** alteraría
el comportamiento; queda como decisión pendiente.

## Verificación

```
example:       idéntico byte a byte a la línea base
example-full:  idéntico antes/después del refactor de opciones
nix flake check (sin --impure): exit=0
nix fmt --ci:  limpio
282/nas1, 282/nas2: OK contra este nixos-nas
```
