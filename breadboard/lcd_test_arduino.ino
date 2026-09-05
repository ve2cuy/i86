/*
 * lcd_test_arduino.ino
 * ------------------------------------------------------------
 * Test de reference INDEPENDANT du montage 8088, pour verifier
 * si un module LCD 1602A fonctionne correctement avec une
 * bibliotheque connue et fiable (LiquidCrystal). Utilise le
 * meme cablage logique que le montage 8088 (R/W a la masse,
 * mode 4 bits, D0-D3 a la masse), pour rester une comparaison
 * la plus equitable possible.
 *
 * Cablage:
 *   LCD VSS -> Arduino GND
 *   LCD VDD -> Arduino 5V
 *   LCD V0  -> curseur du potentiometre de contraste (comme
 *              sur le montage 8088)
 *   LCD RS  -> Arduino pin 7
 *   LCD R/W -> Arduino GND (toujours en ecriture)
 *   LCD E   -> Arduino pin 8
 *   LCD D4  -> Arduino pin 9
 *   LCD D5  -> Arduino pin 10
 *   LCD D6  -> Arduino pin 11
 *   LCD D7  -> Arduino pin 12
 *   LCD D0-D3 -> Arduino GND (comme sur le montage 8088)
 *
 * Resultat attendu si le LCD est fonctionnel:
 *   Ligne 1: "Hello, World!"
 *   Ligne 2: "Arduino OK"
 * ------------------------------------------------------------
 */

#include <LiquidCrystal.h>

// LiquidCrystal(rs, enable, d4, d5, d6, d7)
LiquidCrystal lcd(7, 8, 9, 10, 11, 12);

void setup() {
  lcd.begin(16, 2);       // initialise le LCD en 16 colonnes x 2 lignes
  lcd.clear();

  lcd.setCursor(0, 0);    // debut de la ligne 1
  lcd.print("Hello, World!");

  lcd.setCursor(0, 1);    // debut de la ligne 2 (adresse DDRAM 0x40)
  lcd.print("Arduino OK");
}

void loop() {
  // rien a faire - le texte reste affiche en permanence
}
