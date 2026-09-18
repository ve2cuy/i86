// ============================================================
// irq_test.ino
// Test de branchement Arduino -> 8259 (IR1 "clavier", IR4 "UART") -
// meme esprit que le bouton-poussoir cable DIRECTEMENT sur IR0 (voir
// Solution-01/Directives.md, Solution-01/solution-01.asm:
// irq0_test_handler/irq1_test_handler/irq4_test_handler).
//
// Objectif: valider que l'Arduino peut reellement declencher une
// interruption materielle sur le 8088 via le 8259, AVANT d'implementer
// le vrai protocole de donnees (port 8255 dedie, pas encore cable) qui
// permettra de transmettre un scan code clavier ou un octet UART.
//
// Cablage attendu:
//   PIN_IR1_OUT  -> IR1 du 8259 (test "clavier")
//   PIN_IR4_OUT  -> IR4 du 8259 (test "UART")
//   PIN_BTN_KBD  -> bouton-poussoir vers GND (pull-up interne Arduino)
//                   - declenche une impulsion sur IR1
//   PIN_BTN_UART -> bouton-poussoir vers GND (pull-up interne Arduino)
//                   - declenche une impulsion sur IR4
//
// IMPORTANT - hypothese de polarite (A VERIFIER/AJUSTER selon le
// cablage reel du bouton-poussoir deja utilise pour IR0): le 8259A
// (mode declenchement par front, voir solution-01.asm/init_8259)
// reconnait une transition BAS->HAUT sur IRn comme une requete
// d'interruption - IRn est donc suppose normalement BAS au repos
// (IDLE_LEVEL) et pulse BRIEVEMENT HAUT (PULSE_LEVEL) pour
// declencher. Si le cablage reel du bouton-poussoir IR0 est plutot
// actif-bas (idle HAUT, impulsion BASSE), inverser IDLE_LEVEL/
// PULSE_LEVEL ci-dessous.
//
// PAS d'anti-rebond cote 8088 volontairement (voir irqN_test_handler)
// - plusieurs interruptions par impulsion restent attendues/normales.
// L'anti-rebond logiciel ci-dessous (DEBOUNCE_MS) est seulement pour
// eviter qu'un appui prolonge du bouton ne declenche des dizaines
// d'impulsions Arduino inutiles - il n'empeche PAS les rebonds
// electriques bruts de la ligne IRn elle-meme.
// ============================================================

const uint8_t PIN_IR1_OUT  = 8;   // vers IR1 du 8259 (test clavier)
const uint8_t PIN_IR4_OUT  = 9;   // vers IR4 du 8259 (test UART)
const uint8_t PIN_BTN_KBD  = 2;   // bouton "clavier" (vers GND)
const uint8_t PIN_BTN_UART = 3;   // bouton "UART" (vers GND)

const uint8_t IDLE_LEVEL   = LOW;
const uint8_t PULSE_LEVEL  = HIGH;

const unsigned long PULSE_MS    = 20;   // duree de l'impulsion IRn
const unsigned long DEBOUNCE_MS = 200;  // anti-rebond logiciel (voir note ci-dessus)

unsigned long lastKbdMs  = 0;
unsigned long lastUartMs = 0;

void pulse(uint8_t pin, const char *label) {
  digitalWrite(pin, PULSE_LEVEL);
  Serial.print(F("Impulsion IR sur pin "));
  Serial.print(pin);
  Serial.print(F(" ("));
  Serial.print(label);
  Serial.println(F(")"));
  delay(PULSE_MS);
  digitalWrite(pin, IDLE_LEVEL);
}

void setup() {
  pinMode(PIN_IR1_OUT, OUTPUT);
  pinMode(PIN_IR4_OUT, OUTPUT);
  digitalWrite(PIN_IR1_OUT, IDLE_LEVEL);
  digitalWrite(PIN_IR4_OUT, IDLE_LEVEL);

  pinMode(PIN_BTN_KBD, INPUT_PULLUP);
  pinMode(PIN_BTN_UART, INPUT_PULLUP);

  Serial.begin(9600);
  Serial.println(F("Test de branchement Arduino -> 8259 (IR1/IR4)"));
  Serial.println(F("Bouton clavier (D2) -> IR1, bouton UART (D3) -> IR4"));
}

void loop() {
  unsigned long now = millis();

  if (digitalRead(PIN_BTN_KBD) == LOW && (now - lastKbdMs) > DEBOUNCE_MS) {
    lastKbdMs = now;
    pulse(PIN_IR1_OUT, "clavier, IR1");
  }

  if (digitalRead(PIN_BTN_UART) == LOW && (now - lastUartMs) > DEBOUNCE_MS) {
    lastUartMs = now;
    pulse(PIN_IR4_OUT, "UART, IR4");
  }
}
