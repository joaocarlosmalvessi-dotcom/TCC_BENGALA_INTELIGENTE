#include <Wire.h>
#include <Adafruit_VL53L0X.h>

Adafruit_VL53L0X lox = Adafruit_VL53L0X();

// ===== PINOS =====
#define SDA_PIN 22
#define SCL_PIN 21
#define MOTOR_PIN 19
#define BUZZER_PIN 27

// ===== VARIÁVEIS =====
int distancia;
int intensidade;

void setup() 
{
  Serial.begin(9600);

  // I2C
  Wire.begin(SDA_PIN, SCL_PIN);

  // NOVO PADRÃO PARA ESP32 CORE 3.x
  // ledcAttach(pino, frequencia, resolucao_bits)
  ledcAttach(MOTOR_PIN, 5000, 8); 

  // Inicializa sensor
  if (!lox.begin()) 
  {
    Serial.println("Falha ao iniciar VL53L0X");
    while (1);
  }

  Serial.println("Sistema pronto!");
  
}

// Função para escanear e apitar
void diagnosticoI2C() {
  int nDevices = 0;
  
  // Configura o canal do buzzer
  ledcAttach(BUZZER_PIN, 2000, 8); // 2000Hz (frequência do som)

  // Varredura I2C
  for (byte address = 1; address < 127; address++) {
    Wire.beginTransmission(address);
    if (Wire.endTransmission() == 0) 
    {
      nDevices++;
    }
  }

  // Feedback sonoro
  if (nDevices == 0) {
    // Apito longo de erro (1 segundo) se nada for encontrado
    ledcWrite(BUZZER_PIN, 128); 
    delay(1000);
    ledcWrite(BUZZER_PIN, 0);
  } else {
    // Apita o número de vezes correspondente aos sensores
    for (int i = 0; i < nDevices; i++) {
      ledcWrite(BUZZER_PIN, 128); // Liga
      delay(250);                 // Duração do apito
      ledcWrite(BUZZER_PIN, 0);   // Desliga
      delay(250);                 // Intervalo entre apitos
    }
  }
}

void loop() 
{
  VL53L0X_RangingMeasurementData_t measure;
  diagnosticoI2C();
  lox.rangingTest(&measure, false);

  if (measure.RangeStatus != 4) 
  {
    distancia = measure.RangeMilliMeter;

    Serial.print("Distancia: ");
    Serial.print(distancia);
    Serial.print(" mm | ");

    // Limites de leitura para controle do motor
    if (distancia < 30) distancia = 30;   // Distância mínima (potência máxima)
    if (distancia > 300) distancia = 300; // Distância máxima (motor para)

    // Mapeia distância → intensidade (0 a 255)
    // 300mm = 0 (Desligado)  --->  30mm = 255 (Potência Máxima)
    intensidade = map(distancia, 300, 30, 0, 255);
    
    // Garante que o valor de PWM fique estritamente entre 0 e 255
    intensidade = constrain(intensidade, 0, 255);
    
    // Aplica o PWM no pino do motor
    ledcWrite(MOTOR_PIN, intensidade);

    Serial.print("PWM: ");
    Serial.println(intensidade);
  } 
  else 
  {
    Serial.println("Fora de alcance - Motor desligado");
    // Motor completamente desligado
    ledcWrite(MOTOR_PIN, 0); 
  }

  delay(50);
}