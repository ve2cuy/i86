# Solution-01 — 8088/8086 sur breadboard (VE2CUY)

Firmware ROM pour un ordinateur 8088/8086 assemblé sur breadboard par
Alain Boudreault (VE2CUY). Au démarrage, la carte :

1. affiche "Hello World" sur un second LCD, piloté en I2C logiciel
   (bit-bang), en guise de test de cette fonctionnalité ;
2. affiche un écran de démarrage sur le LCD parallèle 4×20 pendant
   3 secondes ;
3. anime le Port C du 8255 (chenillard) pendant que la ligne UART
   transmet un bandeau de bienvenue ;
4. teste la totalité de la RAM statique (128 Ko) et rapporte le
   résultat (UART + LCD) ;
5. fait un dump hexadécimal des 4 premiers Ko de la ROM (+ les 16
   derniers octets : vecteur de reset et signature) ;
6. reboucle indéfiniment (sans reprendre le test du LCD I2C, qui ne
   tourne qu'une fois).

Ce cycle sert de "power-on self-test" (POST) pour valider le montage
matériel (8255, RAM, LCD parallèle, LCD I2C, UART) à chaque mise sous
tension.

## Matériel visé

- CPU 8088/8086 (le code est écrit pour être compatible 8086 strict —
  voir `CPU 8086` dans `solution-01.asm` — mais ciblé pour tourner sur
  un vrai 8088)
- ROM 256 Ko, mappée à l'adresse physique `C0000h-FFFFFh`
- RAM statique 128 Ko
- Un 8255 (PIO) : Port A entièrement occupé (LCD parallèle, UART
  logiciel et LCD I2C logiciel), Port C utilisé pour l'animation du POST
- Câblage du Port A (voir l'en-tête de `solution-01.asm`) — **les 8
  bits sont utilisés** :
  - `PA0` → `D4` du LCD parallèle **ET** `SCL` du LCD I2C (broche
    partagée — voir `lib/lcd_i2c.asm` : sans risque, car le HD44780
    ne capture les lignes de données que sur un front descendant de
    `E`, jamais touchée par le module I2C)
  - `PA1-PA3` → `D5-D7` du LCD parallèle
  - `PA4` → `RS` du LCD parallèle
  - `PA5` → `SDA` du LCD I2C (PCF8574)
  - `PA6` → `E` du LCD parallèle (dédiée, jamais touchée par le module I2C)
  - `PA7` → ligne UART (remplace un ancien latch 74LS373 externe)
- LCD parallèle HD44780 4 lignes × 20 caractères, piloté en mode 4 bits
- LCD I2C HD44780 (derrière un expandeur PCF8574, adresse `0x27` —
  "backpack" standard), piloté en I2C logiciel

Comme le LCD parallèle, l'UART et le LCD I2C se partagent le même
octet matériel (le 8255 en mode 0 n'adresse pas le Port A bit à bit),
toute écriture sur ce port passe par `porta_write` (voir
`lib/common.asm`), qui ne modifie que les bits concernés et préserve
les autres via une copie fantôme en RAM.

## Schéma bloc du circuit électronique

Décodage d'adresses (logique simple, sans décodeur dédié — un seul
bit d'adresse suffit à distinguer ROM/RAM, la sélection du 8255 se
faisant sur le bus d'E/S) :

- **ROM** : `CS = A19`
- **RAM** : `CS = NOT A19`
- **8255 (PIO)** : `CS = A7 AND IO/M` (cycle d'E/S, adresse ≥ 80h —
  `A0`/`A1` vont directement aux broches `A0`/`A1` du 8255 pour
  sélectionner Port A/B/C/registre de commande — voir `PORTA`/`PORTB`/
  `PORTC`/`PIO` dans `include/hardware.inc`, ports 80h-83h)

```mermaid
flowchart TD
    subgraph CPU["CPU 8088/8086"]
        AB["Bus d'adresses A0-A19"]
        DB["Bus de donnees D0-D7"]
        IOM["IO/M (cycle E/S vs memoire)"]
    end

    subgraph DEC["Decodage d'adresses"]
        A19G["A19"]
        NOTA19["NOT A19"]
        A7IO["A7 AND IO/M"]
    end

    subgraph MEM["Memoire"]
        ROM["ROM 256 Ko\nC0000h-FFFFFh\nCS = A19"]
        RAM["RAM statique 128 Ko\n00000h-1FFFFh\nCS = NOT A19"]
    end

    subgraph IOBLK["Entrees/Sorties"]
        PIO["8255 PIO\nPorts 80h-83h\nCS = A7 AND IO/M"]
    end

    subgraph PERIPH["Peripheriques (Port A du 8255, partage via porta_write)"]
        LCD["LCD parallele HD44780 4x20\nPA0-PA3=D4-D7, PA4=RS, PA6=E"]
        UART["UART logiciel 9600 8N1\nPA7 (bit-bang)"]
        I2CLCD["LCD I2C (PCF8574 0x27)\nPA5=SDA, PA0=SCL (partagee avec D4, sans risque)"]
    end

    LED["Port C: chenillard (animation POST)"]

    AB --> A19G
    A19G --> NOTA19
    AB --> A7IO
    IOM --> A7IO

    A19G -->|CS| ROM
    NOTA19 -->|CS| RAM
    A7IO -->|CS| PIO

    DB --- ROM
    DB --- RAM
    DB --- PIO

    PIO --> LCD
    PIO --> UART
    PIO --> I2CLCD
    PIO --> LED
```

⚠️ Note : la sélection de la ROM ne dépend que de `A19` (pas de
`A18`) — la ROM physique (256 Ko = `A0-A17`) est donc mise en miroir
sur les 512 Ko de la moitié haute de l'espace mémoire (`80000h-FFFFFh`)
si `A18` n'est câblé nulle part ailleurs ; le firmware n'utilise que
la fenêtre `C0000h-FFFFFh`. Même remarque pour la RAM (128 Ko, moitié
basse de 1 Mo) : seuls `00000h-1FFFFh` sont réellement testés par
`test_ram` (voir `solution-01.asm`).

## Structure du dossier

```
Solution-01/
├── solution-01.asm       Flux principal (start, test RAM, dump ROM,
│                          animation 8255) + tous les textes/données
├── Directives.md          Cahier des charges du projet
├── Makefile               Automatise l'assemblage (voir Makefile.md)
├── Makefile.md            Explication détaillée du Makefile
├── check_rom.py           Validation structurelle du .bin assemblé
├── .gitignore             Ignore build/ (fichiers jetables de check-modules)
├── include/
│   ├── hardware.inc       Constantes matérielles (8255, adresses RAM
│   │                      des variables partagées)
│   └── delay.inc          Macro `delay_ms` (voir lib/utils.asm)
└── lib/
    ├── common.asm         porta_write (accès partagé LCD/UART/LCD-I2C
    │                      au Port A) + hex_table
    ├── lcd.asm            Toutes les procédures d'affichage du LCD parallèle
    ├── uart.asm           Toutes les procédures de transmission UART
    ├── utils.asm          delay_ms_proc (routine derrière la macro)
    ├── lcd_i2c.asm        Accès I2C logiciel (bit-bang) au LCD PCF8574 0x27
    └── bin/                (généré) lcd.bin, uart.bin, lcd_i2c.bin
```

Fichiers générés par `make` (non versionnés, voir `.gitignore`) :
`solution-01.bin`, `lib/bin/lcd.bin`, `lib/bin/uart.bin`,
`lib/utils.bin`, `lib/bin/lcd_i2c.bin`, `build/check/*.bin`.

**Règle importante** : tous les `%include` du projet sont écrits comme
des chemins relatifs à **cette racine** (`Solution-01/`), jamais
relatifs au fichier qui fait le `%include` — NASM résout les chemins
par rapport au répertoire courant au moment de l'assemblage. Il faut
donc toujours lancer `nasm`/`make` **depuis ce dossier**, jamais depuis
un sous-dossier.

## Fonctions d'accès au LCD (`lib/lcd.asm`)

| Fonction | Rôle |
|---|---|
| `lcd_init` | Séquence d'initialisation HD44780 standard en 4 bits (4 lignes × 20, curseur off, Clear Display) |
| `lcd_command` / `lcd_data` | Envoie un octet complet (2 quartets) : `lcd_command` = instruction (RS=0), `lcd_data` = caractère (RS=1). Entrée : `AL` |
| `lcd_strobe` | Envoie un quartet déjà prêt et génère l'impulsion `E` (via `porta_write`, jamais un `out` direct — préserve le bit UART) |
| `lcd_print` | Affiche une chaîne terminée par `0` depuis `DS:SI` (pas de padding — le texte doit déjà avoir la largeur voulue) |
| `lcd_line1` … `lcd_line4` | Positionne le curseur DDRAM au début d'une des 4 lignes (convention "type A" pour afficheur 20×4) |
| `lcd_show_line1` … `lcd_show_line4` | `lcd_lineN` + `lcd_print` en un seul appel (entrée : `DS:SI`) |
| `lcd_tx_hex_nibble` / `lcd_tx_hex_byte` / `lcd_tx_hex_word` | Affiche une valeur en hexadécimal majuscule (entrée : `AL` ou `AX`) |
| `lcd_tx_dec3` | Affiche `AX` (0-999) en décimal, toujours sur 3 chiffres avec zéros de tête |
| `lcd_short_delai` / `lcd_delay` / `lcd_delay_long` / `lcd_powerup_delay` | Délais calibrés au plus proche du minimum HD44780 (voir en-tête du fichier pour les marges de sécurité de chacun) |

## Fonctions d'accès à l'UART (`lib/uart.asm`)

Transmission série logicielle (bit-bang, 9600 8N1) sur `PA7`.

| Fonction | Rôle |
|---|---|
| `uart_tx_string` | Transmet une chaîne terminée par `0` depuis `DS:SI` |
| `uart_tx_byte` | Transmet `AL` en 8N1 (bit start, 8 bits LSB en premier, bit stop) via `porta_write` |
| `uart_bit_delay` | Délai d'un bit, calibré (`UART_BIT_COUNT`) pour ~9600 bauds — **valeur mesurée à l'analyseur logique sur ce montage, ne pas modifier sans re-mesurer** |
| `uart_tx_hex_nibble` / `uart_tx_hex_byte` / `uart_tx_hex_word` | Affiche une valeur en hexadécimal majuscule (entrée : `AL` ou `AX`) |

## Fonctions d'accès au LCD I2C (`lib/lcd_i2c.asm`)

Second LCD HD44780, derrière un expandeur I2C PCF8574 (adresse
`0x27`), piloté en I2C **logiciel** (bit-bang) sur `SDA=PA5` /
`SCL=PA0` (`PA0` partagée avec `D4` du LCD parallèle, mais **sans
risque** : le HD44780 ne capture les lignes de données que sur un
front descendant de `E` — jamais touchée par ce module — donc le
trafic I2C lui est invisible. **`i2c_lcd_*` peut être appelé
n'importe où dans le projet**, même pendant un affichage actif sur
le LCD parallèle, sans avoir besoin d'un `lcd_init` après coup — voir
l'en-tête de `lib/lcd_i2c.asm` pour le détail, y compris l'essai
initial avec `SCL` sur `PA6`/`E`, abandonné pour cette raison). Le
Port A du 8255 étant configuré tout en sortie (push-pull, pas
open-drain), cette implémentation **n'accuse jamais réception (ACK)**
— voir l'en-tête du fichier pour le détail.

| Fonction | Rôle |
|---|---|
| `i2c_lcd_init` | Séquence d'initialisation HD44780 standard en 4 bits, via le PCF8574 |
| `i2c_lcd_command` / `i2c_lcd_data` | Envoie un octet complet au LCD I2C (voir `i2c_lcd_send_byte`). Entrée : `AL` |
| `i2c_lcd_send_byte` | Envoie 2 quartets × 3 états `EN` en **une seule transaction I2C** (1 START + adresse + 6 octets de données + 1 STOP) |
| `i2c_lcd_strobe` | Envoie un quartet + `RS` avec l'impulsion `EN`, en une seule transaction I2C (1 START + adresse + 3 octets + STOP) |
| `i2c_lcd_print` | Affiche une chaîne terminée par `0` depuis `DS:SI` |
| `i2c_lcd_line1` … `i2c_lcd_line4` | Positionne le curseur DDRAM au début d'une des 4 lignes (mêmes adresses que `lcd_line1..4`) |
| `i2c_lcd_show_line1` … `i2c_lcd_show_line4` | `i2c_lcd_lineN` + `i2c_lcd_print` en un seul appel (entrée : `DS:SI`) |
| `i2c_lcd_tx_hex_nibble` / `i2c_lcd_tx_hex_byte` | Affiche une valeur en hexadécimal majuscule (entrée : `AL`) |
| `i2c_write_byte` | Transmet un octet (8 bits, MSB en premier) sur le bus I2C |
| `i2c_start` / `i2c_stop` | Conditions START/STOP du protocole I2C |
| `i2c_delay` | Demi-période SCL (~7,5 µs → ~45-66 kHz, sous le maximum 100 kHz du mode I2C "standard") |

⚡ **Optimisations** (trois passes, voir Directives.md pour l'historique) :
1. Les écritures PCF8574 (états `EN=0/1/0` par quartet) sont regroupées dans
   une seule transaction I2C par appel plutôt qu'une transaction séparée par
   écriture — l'overhead START+adresse+STOP n'est payé qu'une fois par
   quartet (`i2c_lcd_strobe`) ou par octet complet (`i2c_lcd_send_byte`), au
   lieu de 3× ou 6×.
2. `i2c_start`/`i2c_stop`/`i2c_write_byte` lisaient la copie fantôme du Port A
   **une seule fois par appel** (pas par bit) et écrivaient directement sur le
   port (`out`) pour chaque transition SDA/SCL, au lieu de passer par un
   `i2c_set` intermédiaire qui relisait la copie fantôme via `porta_write`
   (lecture-modification-écriture complète, 5 `push`/`pop`) à **chaque bit**
   (~27 fois par octet PCF8574). C'est cette surcharge d'appels de procédure
   — mesurée sur le matériel réel bien plus coûteuse que les délais
   volontaires eux-mêmes — qui dominait le temps total, pas la vitesse
   d'horloge I2C (`i2c_delay`, inchangée).
3. La copie fantôme RAM (`PORTA_SHADOW`) n'est plus utilisée **du tout** par
   ces 3 routines : remplacée par une lecture matérielle directe
   `IN AL, PORTA`. Fiable sur un 8255A authentique (confirmé sur ce
   montage) — un port configuré en sortie renvoie, à la lecture, le contenu
   du **verrou de sortie** (comportement documenté du 8255A ; à revalider si
   le 8255 change un jour pour un clone non garanti équivalent). Élimine le
   passage par `VAR_SEG`/`ES`/`DI` entièrement dans ce module. Sans impact
   sur `porta_write` (LCD parallèle/UART) : aucun de leurs masques ne couvre
   `PA0`(`SCL`)/`PA5`(`SDA`), sauf le LCD parallèle qui écrit toujours
   explicitement son propre bit `D4`/`PA0`.

Réutilise `lcd_delay` / `lcd_delay_long` / `lcd_powerup_delay` de
`lib/lcd.asm` pour les temps d'exécution propres au HD44780 (mêmes
exigences, peu importe le transport parallèle ou I2C).

### Test de performance conditionnel (`TEST_I2C_DUMP`)

Active un affichage supplémentaire, sur le LCD I2C, des 16 octets en
hexadécimal de **chaque ligne** du dump ROM (`dump_line`) — 4 octets
par ligne sur les 4 lignes du LCD 4×20 — en plus de ce qui s'affiche
déjà sur le LCD parallèle et l'UART. Sert à mesurer/stresser le temps
de réponse du LCD I2C sur 257 mises à jour complètes et successives.
Aucun impact sur le comportement normal quand la directive reste
désactivée : le code correspondant (dans `dump_line` et dans la
procédure `i2c_dump_hex_line`) est entièrement gardé par
`%ifdef TEST_I2C_DUMP` / `%endif` et n'est simplement pas assemblé.

**Façon recommandée de l'activer — sans modifier le fichier** : passer
la définition directement à NASM en ligne de commande, avec le flag `-d` :

```sh
nasm -f bin -d TEST_I2C_DUMP solution-01.asm -o solution-01.bin
```

Alternative : `solution-01.asm` contient aussi la ligne
`%define TEST_I2C_DUMP`, **commentée par défaut**, dans le bloc de
commentaires "TEST_I2C_DUMP" près du haut du fichier (avec
`STACK_SEG`/`SECONDE`) — la décommenter active la directive de façon
permanente pour tout `make`/`nasm` lancé sur ce fichier, sans avoir à
répéter le flag `-d` à chaque fois.

## Outils nécessaires pour produire le `.bin` final

| Outil | Rôle |
|---|---|
| [NASM](https://www.nasm.us/) | Assembleur x86 (`nasm -f bin ...`) — doit être dans le `PATH` |
| GNU Make | Orchestre l'assemblage via le `Makefile` (voir `Makefile.md`) |
| Python 3 | Exécute `check_rom.py` (cible `make check`) |
| Git | Suivi de version du projet |
| Un shell POSIX (`cp`, `mkdir -p`, `rm -f`) | Requis par les recettes du `Makefile` |

```sh
make          # construit tout : ROM complète + modules individuels
make rom      # ROM complète, copiée vers Z:\Partage\Alain\rom.bin
make lib      # modules individuels (lib/bin/lcd.bin, lib/bin/uart.bin, lib/utils.bin, lib/bin/lcd_i2c.bin)
make check    # assemble la ROM puis valide sa structure (check_rom.py)
make check-modules  # verifie que chaque module s'assemble seul, sans erreur
make clean    # supprime tous les .bin generes
```

Détails complets de chaque cible : voir [Makefile.md](Makefile.md).

## Environnement de travail : session WSL sous VS Code

Le `Makefile` suppose GNU Make + un shell POSIX (`cp`, `mkdir -p`,
`rm -f`). Pour travailler sur ce projet, **ouvrir une session WSL
(Windows Subsystem for Linux) dans VS Code** plutôt qu'un terminal
Windows natif (PowerShell/cmd) :

1. Dans VS Code, ouvrir une palette de commandes (`Ctrl+Shift+P`) →
   **WSL: Connect to WSL** (ou ouvrir un terminal intégré et choisir le
   profil **WSL** dans le sélecteur de shell).
2. Se placer à la racine de ce dossier (`Solution-01/`).
3. Vérifier que `nasm`, `make`, `python3` et `git` sont installés et
   accessibles dans ce shell WSL (`nasm -v`, `make -v`, `python3
   --version`, `git --version`).
4. Lancer `make` (ou toute autre cible) depuis ce terminal WSL.

Travailler sous WSL évite les problèmes de traduction de chemins
(`Z:\Partage\Alain\`, chemins POSIX vs Windows) et de shell
(`cmd.exe` vs `sh`) qui peuvent survenir avec un `make` natif Windows
appelant un shell MSYS/Git Bash.
