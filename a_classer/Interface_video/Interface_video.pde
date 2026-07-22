
const int buttonPin = 2; 
int buttonState; 
long int i=1;
void setup() 
{ 
  Serial.begin(115200); 
  Serial.println("Trace du i86 breadBoard"); 
  pinMode(buttonPin, INPUT);
  pinMode(13, OUTPUT);
  
} 


void loop() 
{ 
  /* Serial.print(thisByte, BYTE);    

  Serial.print(", dec: "); 
  Serial.print(thisByte);      
  Serial.print(", hex: "); 
  Serial.print(thisByte, HEX);     

  Serial.print(", oct: "); 
  Serial.print(thisByte, OCT);     

  Serial.print(", bin: "); 
  Serial.println(thisByte, BIN);   
  */
  
  buttonState = digitalRead(buttonPin);
  if (buttonState) {
    digitalWrite(13, buttonState);
    Serial.print("Recu une commande du i86: ");
    Serial.println(i++);
    while (digitalRead(buttonPin));
   digitalWrite(13, 0);

  } 
  
   
/*
  if(thisByte == 126) {     // you could also use if (thisByte == '~') {
    while(true) { 
      continue; 
    } 
  } 
  thisByte++;  
*/ 
} 
