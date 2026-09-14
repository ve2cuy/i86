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
