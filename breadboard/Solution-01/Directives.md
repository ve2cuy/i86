J'ai déplacé la solution-01.asm dans le dossier Solution-01

À partir du dossier Solution-01, voici les tâches à réaliser:

* Sortir les procédures d'affichage du LCD, de transmissions UART ainsi que toutes les procédures associées et les déplacer dans lcd.asm ou uart.asm et sauvegader dans le dossier ./lib
* Rédiger une lib pour delay_ms ainsi qu'une macro 'delay ms' pour son utilisation 
* Rédiger un Make file
* Avec le Make file, produire un fichier .bin pour chacune des procédures (LCD et UART), et enregister sous ./lib/bin.  Enregister delay_ms dans ./lib/utils.bin
* Enregister le fichier .bin du ROM sous Z:\Partage\Alain\rom.bin 

* Dans un nouveau fichier, programmer un accès I2C, en bit banging, sur PA5 et PA6, pour un LCD. L'adresse I2C du LCD est 0x27.
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
