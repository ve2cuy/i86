/*
 * Arduino UNO R4 (Renesas RA4M1)
 * Projet : 8088 sur breadboard - version 2026
 * ------------------------------------------------------------------------------
 * Production d'une horloge sur D9, fréquence variable par potentiomètre sur A2,
 * avec un duty cycle fixe de 1/3 (33.33 %) - Nécessaire pour un 8088.
 * -------------------------------------------------------------------------------
 * - Potentiomètre lu sur A2
 * - Horloge générée sur D9 via PWM MATÉRIEL (timer GPT), duty cycle fixe = 1/3
 * - La fréquence dépend de la position du potentiomètre
 * - La fréquence demandée est affichée sur le moniteur série
*/
#include <Arduino.h>
#include "pwm.h"
#include "rgb_lcd.h"

const float FREQ_MIN_HZ = 10000.0f;     // pot au minimum
const float FREQ_MAX_HZ = 4770000.0f;  // pot au maximum -> 1 MHz, à ajuster

const uint32_t INTERVALLE_MAJ_MS = 50; // rythme de mise à jour (non critique)
const uint8_t PIN_HORLOGE = 9;   // D9
const uint8_t PIN_POT     = A2;  // potentiomètre

PwmOut pwm(PIN_HORLOGE);
rgb_lcd lcd;
void setup() {
  Serial.begin(115200);  
  lcd.begin(16, 2 /*, LCD_5x8DOTS, Wire1*/);
  lcd.print("Horloge 8088");
  

  //period 50us = 20000hz; pulse 0 us = 0%
  // pwm.begin(1000000.0f, 33.0f);
  // Modifier le duty cycle
  // pwm.pulse_perc(50.0f);
  delay(1000);

}

void loop() {
  static uint32_t derniereMaj = 0;  
  uint32_t maintenant = millis();
  static int valPot = 2;

  if ((uint32_t)(maintenant - derniereMaj) >= INTERVALLE_MAJ_MS) {
    derniereMaj = maintenant;
    // Pour ne pas reconfigurer le timer matériel à chaque lecture du potentiomètre, 
    // on ne le fait que si la valeur a changé de plus de 2 unités (0..1023)
    if (abs(valPot - analogRead(PIN_POT)) >= 2) { 
        valPot = analogRead(PIN_POT);   // 0 .. 1023

        // Position du pot -> fréquence cible, en Hz
        float freq_hz = FREQ_MIN_HZ +
                        (FREQ_MAX_HZ - FREQ_MIN_HZ) * ((float)valPot / 1023.0f);

        // Reconfigure le timer matériel : période ET duty cycle sont recalculés
        // et appliqués par le GPT, sans intervention logicielle dans la boucle
        // de génération du signal.
        pwm.end();  // C'est nécessaire de faire un end() avant de refaire un begin() sinon j'obtiens: Fault on interrupt or bare metal(no OS) environment
        pwm.begin(freq_hz, 33.0f);

        Serial.print(F("Pot = "));
        Serial.print(valPot);
        Serial.print(F("  ->  Frequence demandee = "));
        Serial.print(freq_hz, 1);
        Serial.println(F(" Hz (duty cycle = 33.33 %)"));
        lcd.setCursor(0, 1);
        lcd.print("Freq: ");
        lcd.print(freq_hz, 0);
        lcd.print(" Hz  ");
      }  
  }

}

/*
 * Arduino UNO R4 Minima (Renesas RA4M1)
 * ---------------------------------------------------------------
 * - Potentiomètre lu sur A2
 * - Horloge générée sur D9 via PWM MATÉRIEL (timer GPT), duty cycle fixe = 1/3
 * - La fréquence dépend de la position du potentiomètre
 * - La fréquence demandée est affichée sur le moniteur série
 *
 * Pourquoi le PWM matériel plutôt que du bit-banging logiciel :
 * la classe PwmOut configure un timer GPT du RA4M1 pour qu'il pilote la
 * broche tout seul, en silicium, via ses registres de période et de
 * comparaison. Le CPU ne participe plus du tout à la bascule du signal :
 * il n'y a donc plus aucun overhead logiciel (appels de fonction, boucles
 * d'attente, lecture ADC) qui pourrait venir déformer le duty cycle, quelle
 * que soit la fréquence. C'est à la fois plus précis ET plus rapide que
 * l'accès direct au port en boucle logicielle utilisé précédemment.
 *
 * Remarque : D8 n'est pas listé parmi les broches PWM "officiellement
 * supportées" de l'UNO R4 Minima (D3, D5, D6, D9, D10, D11 pour
 * analogWrite()), mais elle reste pilotable par un timer GPT via la classe
 * PwmOut de bas niveau utilisée ici. Si horloge.begin() renvoie false sur
 * votre carte, essayez une des broches officiellement supportées.
 */


 /*
const uint8_t PIN_HORLOGE = 9;   // D9
const uint8_t PIN_POT     = A2;  // potentiomètre

PwmOut horloge(PIN_HORLOGE);

const float DUTY_PERCENT = 100.0f / 3.0f; // exactement 1/3

// Plage de fréquences balayée par le potentiomètre.
// FREQ_MAX_HZ peut être poussée plus haut : essayez et vérifiez au
// scope/analyseur logique jusqu'où le duty cycle de 1/3 reste propre.
const float FREQ_MIN_HZ = 50.0f;       // pot au minimum
const float FREQ_MAX_HZ = 1000000.0f;  // pot au maximum -> 1 MHz, à ajuster

const uint32_t INTERVALLE_MAJ_MS = 50; // rythme de mise à jour (non critique)
uint32_t derniereMaj = 0;

void setup() {
  Serial.begin(115200);
  analogReadResolution(10); // 0..1023

  bool ok = horloge.begin(FREQ_MIN_HZ, DUTY_PERCENT);
  if (!ok) {
    Serial.println(F("Erreur : impossible de configurer le PWM materiel sur D8."));
    Serial.println(F("Essayez une broche PWM officiellement supportee (D3, D5, D6, D9, D10, D11)."));
  }
}

void loop() {
  uint32_t maintenant = millis();
  if ((uint32_t)(maintenant - derniereMaj) >= INTERVALLE_MAJ_MS) {
    derniereMaj = maintenant;

    int valPot = analogRead(PIN_POT); // 0 .. 1023

    // Position du pot -> fréquence cible, en Hz
    float freq_hz = FREQ_MIN_HZ +
                    (FREQ_MAX_HZ - FREQ_MIN_HZ) * ((float)valPot / 1023.0f);

    // Reconfigure le timer matériel : période ET duty cycle sont recalculés
    // et appliqués par le GPT, sans intervention logicielle dans la boucle
    // de génération du signal.
    horloge.begin(freq_hz, DUTY_PERCENT);

    Serial.print(F("Pot = "));
    Serial.print(valPot);
    Serial.print(F("  ->  Frequence demandee = "));
    Serial.print(freq_hz, 1);
    Serial.println(F(" Hz (duty cycle = 33.33 %)"));
  }
}

*/