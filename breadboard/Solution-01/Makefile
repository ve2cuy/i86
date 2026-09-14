# ============================================================
# Makefile - projet solution-01 (VE2CUY, 8088/8086 breadboard)
#
# HYPOTHESE (a corriger si necessaire): ce Makefile suppose GNU Make
# + un shell POSIX (cp, mkdir -p, rm -f) disponibles - le cas typique
# sous WSL, Git Bash ou MSYS2 sur Windows. Si tu utilises plutot
# nmake (Visual Studio) ou le make.exe minimaliste de MinGW sans
# coreutils, dis-le moi et j'adapte les regles ci-dessous (copy /
# mkdir / del au lieu de cp / mkdir -p / rm -f).
#
# nasm doit etre dans le PATH. Toutes les regles supposent que make
# est lance depuis LA RACINE de ce dossier (Solution-01/), jamais
# depuis un sous-dossier - c'est aussi la regle suivie par tous les
# %include du projet (voir include/hardware.inc).
# ============================================================

NASM        = nasm
NASMFLAGS   = -f bin

ROM_BIN     = solution-01.bin
ROM_OUT     = Z:/Partage/Alain/rom.bin

LCD_BIN     = lib/bin/lcd.bin
UART_BIN    = lib/bin/uart.bin
UTILS_BIN   = lib/utils.bin
LCD_I2C_BIN = lib/bin/lcd_i2c.bin

# Dossier de sortie pour les .bin jetables de check-modules. On evite /tmp:
# quand ce Makefile est lance par un make natif Windows (ex. WinAVR) qui
# invoke sh.exe (Git/MSYS) comme SHELL, la traduction du chemin POSIX /tmp
# n'est pas fiable (l'environnement MSYS n'est pas toujours initialise
# comme lors d'un lancement direct du shell) et nasm echoue a l'ouverture
# du fichier de sortie. Un dossier local du projet n'a pas ce probleme.
CHECK_DIR   = build/check

.PHONY: all rom lib check clean check-modules

# --- Cible par defaut: la ROM complete + les modules individuels ---
all: rom lib

# --- ROM complete, copiee vers Z:\Partage\Alain\rom.bin ---
rom: $(ROM_BIN)
	@mkdir -p "$(dir $(ROM_OUT))" 2>/dev/null || true
	cp $(ROM_BIN) "$(ROM_OUT)"
	@echo "ROM copiee vers $(ROM_OUT)"

$(ROM_BIN): solution-01.asm include/hardware.inc include/delay.inc \
            lib/common.asm lib/lcd.asm lib/uart.asm lib/utils.asm lib/lcd_i2c.asm
	$(NASM) $(NASMFLAGS) solution-01.asm -o $(ROM_BIN)

# --- Modules individuels (LCD, UART, delay_ms, LCD I2C) ---
lib: $(LCD_BIN) $(UART_BIN) $(UTILS_BIN) $(LCD_I2C_BIN)

$(LCD_BIN): lib/lcd.asm lib/common.asm include/hardware.inc | lib/bin
	$(NASM) $(NASMFLAGS) lib/lcd.asm -o $(LCD_BIN)

$(UART_BIN): lib/uart.asm lib/common.asm include/hardware.inc | lib/bin
	$(NASM) $(NASMFLAGS) lib/uart.asm -o $(UART_BIN)

$(UTILS_BIN): lib/utils.asm
	$(NASM) $(NASMFLAGS) lib/utils.asm -o $(UTILS_BIN)

$(LCD_I2C_BIN): lib/lcd_i2c.asm lib/lcd.asm lib/common.asm include/hardware.inc | lib/bin
	$(NASM) $(NASMFLAGS) lib/lcd_i2c.asm -o $(LCD_I2C_BIN)

lib/bin:
	mkdir -p lib/bin

# --- Verifie que chaque module (y compris common.asm, partage par
# lcd.asm/uart.asm) s'assemble seul sans erreur - sans produire de
# .bin livre, juste un test rapide de coherence des %include ---
check-modules: | $(CHECK_DIR)
	$(NASM) $(NASMFLAGS) lib/common.asm  -o $(CHECK_DIR)/_check_common.bin
	$(NASM) $(NASMFLAGS) lib/lcd.asm     -o $(CHECK_DIR)/_check_lcd.bin
	$(NASM) $(NASMFLAGS) lib/uart.asm    -o $(CHECK_DIR)/_check_uart.bin
	$(NASM) $(NASMFLAGS) lib/utils.asm   -o $(CHECK_DIR)/_check_utils.bin
	$(NASM) $(NASMFLAGS) lib/lcd_i2c.asm -o $(CHECK_DIR)/_check_lcd_i2c.bin
	@echo "Tous les modules s'assemblent individuellement - OK"

$(CHECK_DIR):
	mkdir -p $(CHECK_DIR)

# --- Verification structurelle de la ROM assemblee (taille, vecteur
# de reset, signature) - voir check_rom.py ---
check: $(ROM_BIN)
	python3 check_rom.py $(ROM_BIN)

clean:
	rm -f $(ROM_BIN) $(LCD_BIN) $(UART_BIN) $(UTILS_BIN) $(LCD_I2C_BIN)
	rm -rf $(CHECK_DIR)
