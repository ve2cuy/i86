J'ai déplacé la solution-01.asm dans le dossier Solution-01

À partir du dossier Solution-01, voici les tâches à réaliser:

* Sortir les procédures d'affichage du LCD, de transmissions UART ainsi que toutes les procédures associées et les déplacer dans lcd.asm ou uart.asm et sauvegader dans le dossier ./lib
* Rédiger une lib pour delay_ms ainsi qu'une macro 'delay ms' pour son utilisation 
* Rédiger un Make file
* Avec le Make file, produire un fichier .bin pour chacune des procédures (LCD et UART), et enregister sous ./lib/bin.  Enregister delay_ms dans ./lib/utils.bin
* Enregister le fichier .bin du ROM sous Z:\Partage\Alain\rom.bin 

* Dans un nouveau fichier, programmer un accès I2C, en bit banging, sur PA5 et PA0, pour un LCD. L'adresse I2C du LCD est 0x27.
* Incorporer un test de cette nouvelle fonctionnalité dans l'application, par exemple, en affichant Hello World sur le LCD-I2C au démarrage. 

Suite à discussion avec Claude Code (session du 14 septembre 2026), voici les tâches demandées et réalisées:

* Vérifier l'accès local aux outils nécessaires au projet (nasm, make, git, python3) depuis le dossier Solution-01.
* Corriger le Makefile pour qu'il fonctionne correctement sous une session Bash (le check-modules écrivait vers /tmp de façon peu fiable quand make natif Windows invoque le shell MSYS de Git) - "Recadrage pour WSL Bash".
* Committer les changements en attente dans le dépôt (réorganisation du dossier breadboard: fichiers historiques déplacés vers etapes/, solution modularisée dans Solution-01/).
* Rédiger un Makefile.md qui explique le fonctionnement du Makefile (variables, cibles, prérequis/recettes).
* Au démarrage, afficher sur le LCD l'écran suivant pendant 3 secondes:

      Breadboard 8088
      Version 1.0
      --------------------
      (c) VE2CUY 2026

* Diminuer les délais des routines LCD (lcd_short_delai, lcd_delay, lcd_delay_long, lcd_powerup_delay), tout en gardant une légère marge de sécurité, pour un LCD qui répond le plus vite possible.
* Rédiger, dans le dossier Solution-01, un README.md qui explique l'ensemble du projet, décrit la structure des dossiers/fichiers, présente les fonctions d'accès au LCD et à l'UART, énumère les outils nécessaires à la production du .bin final, et explique qu'il faut ouvrir une session WSL sous VS Code pour travailler.
* Dessiner un diagramme de bloc du circuit électronique et l'ajouter au README.md. Note: ROM select sur A19, RAM select sur NOT A19, 8255 select sur A7+IO.
* Réaliser les tâches des lignes 11-12 (accès I2C bit banging au LCD-I2C 0x27, test "Hello World" au démarrage) - implémenté dans lib/lcd_i2c.asm, initialement avec SCL=PA6 (partagée avec E du LCD parallèle).
* Déplacer SCL de PA6 vers PA0 (partagée avec D4 du LCD parallèle plutôt qu'avec E) - élimine tout risque de corruption du LCD parallèle par le trafic I2C, puisque le HD44780 ne capture les lignes de données que sur un front descendant de E, jamais touchée par ce module. i2c_lcd_* est donc utilisable n'importe où dans le projet, sans devoir être suivi d'un lcd_init.
* Affichage sur le LCD-I2C rapporté comme très lent (chaque caractère visible apparaître un par un) - cause: l'implémentation initiale faisait 6 transactions I2C complètes (START+adresse+donnée+STOP) séparées par octet envoyé (une par état EN=0/1/0 de chaque quartet). Corrigé en regroupant les écritures PCF8574 dans une seule transaction par quartet (i2c_lcd_strobe) ou par octet complet (nouveau i2c_lcd_send_byte, utilisé par i2c_lcd_command/i2c_lcd_data) - l'overhead START/adresse/STOP n'est plus payé qu'une fois au lieu de 3x ou 6x.
* Test plus rigoureux du temps de réponse du LCD-I2C: afficher la valeur hex des 16 octets du dump ROM sur le LCD-I2C (4x20), une mise à jour complète par ligne du dump (257 au total). Compilé de façon conditionnelle via la directive `%define TEST_I2C_DUMP` (commentée par défaut) en haut de solution-01.asm - voir README.md.
* Testé sur le matériel réel avec TEST_I2C_DUMP actif: le dump des 16 octets (48 caractères/commandes envoyés au LCD-I2C) prenait au moins 2,5 secondes - beaucoup trop lent. Cause identifiée: ce n'était PAS les délais volontaires (i2c_delay), mais la surcharge d'appels de procédure - chaque bit passait par i2c_set, qui relisait la copie fantôme du Port A via porta_write (lecture-modification-écriture complète, 5 push/pop) à CHAQUE bit (~27 fois par octet PCF8574, ~189 fois par transaction). Corrigé: i2c_start/i2c_stop/i2c_write_byte lisent maintenant la copie fantôme une seule fois par appel (pas par bit) et écrivent directement sur le port (out) pour chaque transition SDA/SCL - i2c_set supprimé (devenu inutile). Vitesse d'horloge I2C (i2c_delay) inchangée.
* Confirmé sur le matériel réel: beaucoup plus rapide après le correctif ci-dessus.
* Publication d'une release GitHub v1.0 (checkpoint stable avant la modification suivante): https://github.com/ve2cuy/i86/releases/tag/v1.0
* Montage confirmé avec une vraie puce 8255A (pas un clone) - remplacer la copie fantôme RAM par une lecture matérielle directe IN AL,PORTA dans i2c_start/i2c_stop/i2c_write_byte (fiable sur un 8255A authentique: un port en sortie renvoie le contenu du verrou de sortie a la lecture). Elimine le passage par VAR_SEG/ES/DI dans ces 3 routines. Sans impact sur porta_write (LCD parallele/UART): aucun de leurs masques ne couvre PA0(SCL)/PA5(SDA), sauf le LCD parallele qui ecrit toujours explicitement son propre bit D4/PA0.
* Testé sur le matériel réel: fonctionne, mais gain non perceptible par rapport à la version précédente - attendu, ce changement n'économise que quelques instructions par APPEL (pas par bit), contrairement à l'optimisation precedente. Question posée: est-ce que la copie fantôme a aussi été éliminée du traitement LCD parallèle? Réponse: non, lcd.asm/uart.asm passent toujours par porta_write (copie fantôme inchangée) - volontairement pas touché, car porta_write est partagé avec l'UART dont le timing bit-à-bit a été calibré a la main (UART_BIT_COUNT, "ne pas modifier sans re-mesurer" dans uart.asm) - un changement de porta_write changerait son nombre de cycles et risquerait de decaler la periode de bit UART.
* Réduction de i2c_delay (bx=2 -> bx=1, ~44,4kHz -> ~88,5kHz) - reduit le plancher impose par les ~189 appels a i2c_delay par transaction, le facteur dominant restant une fois la surcharge d'appels eliminee. Marge sous le plafond I2C 100kHz ramenee de ~125% a ~13% - premier candidat a assouplir (revenir a bx=2) si le LCD I2C devient instable.
* Confirmé sur le matériel réel: les 4 lignes s'affichent presque instantanément, aucune instabilité malgré la marge plus serrée sur i2c_delay.
* Il reste de la place sur les lignes du LCD-I2C (11/20 colonnes utilisées par le hexa) - afficher aussi les caracteres ASCII du dump, comme pour le dump UART (caracteres non imprimables remplaces par '.'). Ajouté à i2c_dump_hex_line (TEST_I2C_DUMP): "XX XX XX XX ASCI" = 16/20 colonnes.
* Petite modification: afficher 8 caractères ASCII sur les lignes 1 et 3 (couvrant aussi les octets de leur ligne suivante), rien sur les lignes 2 et 4. i2c_dump_hex_line scindée en i2c_dump_hex_only_line (hexa seul, lignes 2/4) et i2c_dump_hex_ascii8_line (hexa + 8 ASCII, lignes 1/3 - "XX XX XX XX ASCIIIII" = 20/20 colonnes, pleine largeur).
* Éliminer les redondances du code en utilisant des macros (ex: lcd_goto LINE1 au lieu de la procédure lcd_line1 complète), optimiser tout le code du projet par des techniques de refactoring. Réalisé:
  - Nouveau include/lcd_macros.inc (inclus avant start:, comme delay.inc): macros lcd_goto/lcd_show/i2c_lcd_goto/i2c_lcd_show, remplacent les 16 procédures lcd_line1..4/lcd_show_line1..4/i2c_lcd_line1..4/i2c_lcd_show_line1..4 (lib/lcd.asm, lib/lcd_i2c.asm) - ~20 sites d'appel mis à jour dans solution-01.asm.
  - lib/common.asm: macros génératrices def_tx_hex_nibble/byte/word (remplacent 8 procédures dupliquées - LCD parallèle/UART/LCD-I2C, même logique, seule la procédure d'émission change) et def_busy_delay (remplacent 5 procédures dupliquées: lcd_short_delai/lcd_delay/lcd_delay_long/i2c_delay/uart_bit_delay, même motif dec bx/jnz).
  - solution-01.asm: macro lcd_text pour les ~15 blocs de texte LCD à largeur fixe (db+times+db 0), macro ascii_or_dot (logique dupliquée dump UART/i2c_dump_hex_ascii8_line), macro i2c_dump_hex4 (boucle hexa dupliquée entre i2c_dump_hex_only_line/i2c_dump_hex_ascii8_line, TEST_I2C_DUMP).
  - Aucun changement fonctionnel voulu: vérifié via listing d'assemblage (nasm -l) que les macros génératrices (def_tx_hex_*, def_busy_delay, lcd_text) produisent des octets identiques à l'original; les macros inline (lcd_goto/lcd_show, ascii_or_dot) remplacent un "call" partagé par du code répété à chaque site - légère augmentation du binaire (2983 octets sur 262144, marge de ~0x3F38C octets avant le vecteur de reset), sans risque de dépassement. make all/check/check-modules + build TEST_I2C_DUMP tous validés.
