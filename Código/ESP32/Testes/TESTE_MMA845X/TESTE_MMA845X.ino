#include <Wire.h>
#include "SparkFun_MMA8452Q.h"

MMA8452Q accel;
/*

pino led chao = 3
pino led levantado = 7

*/


const int pinLedChao = 3;
const int pinLedLevantado = 7;

bool estaNoChao = false; 
bool emSuspeitaDeQueda = false;

unsigned long tempoInicioParado = 0; 
const long tempoNecessarioParado = 2000; // 5 segundos

// Variáveis para sentir tremor/movimento
float ultX = 0, ultY = 0, ultZ = 0;

void setup() {
  Serial.begin(9600);
  pinMode(pinLedChao, OUTPUT);
  pinMode(pinLedLevantado, OUTPUT);

  if (accel.begin(Wire, 0x1C) == false) {
    Serial.println("Erro I2C 0x1C!");
    while (1);
  }

  // Começa assumindo que está sendo usada (De pé)
  digitalWrite(pinLedChao, LOW);
  digitalWrite(pinLedLevantado, HIGH);
  Serial.println(">>> SISTEMA MONITORANDO BENGALA (STATUS: EM USO)");
}

void loop() {
  if (accel.available()) {
    accel.read();
    
    float m = sqrt(pow(accel.cx, 2) + pow(accel.cy, 2) + pow(accel.cz, 2));
    float variacaoEixos = abs(accel.cx - ultX) + abs(accel.cy - ultY) + abs(accel.cz - ultZ);
    unsigned long tempoAtual = millis();

    // --- LÓGICA DE DETECÇÃO DE QUEDA/PARADA ---
    if (!estaNoChao) {
      // Se houver um impacto OU o sensor estiver muito parado (repouso absoluto)
      if (m > 1.4 || variacaoEixos < 0.04) {
        if (!emSuspeitaDeQueda) {
          emSuspeitaDeQueda = true;
          tempoInicioParado = tempoAtual; // Começa a contar os 5 segundos
          Serial.println("... Suspeita de queda/parada. Verificando estabilidade...");
        }

        // Se passar 5 segundos imóvel
        if (tempoAtual - tempoInicioParado >= tempoNecessarioParado) {
          estaNoChao = true;
          emSuspeitaDeQueda = false;
          digitalWrite(pinLedChao, HIGH);
          digitalWrite(pinLedLevantado, LOW);
          Serial.println(">>> STATUS: CONFIRMADO PARADA/CAIDA (5s imovel)");
        }
      } 
      // Se houver movimento significativo durante a contagem, cancela a suspeita
      if (variacaoEixos > 0.10) {
        emSuspeitaDeQueda = false;
      }
    } 

    // --- LÓGICA PARA LEVANTAR (INSTANTÂNEO) ---
    else {
      // Se detectar tremor de mão ou mudança de ângulo, levanta na hora
      if (abs(m - 1.0) > 0.15 || variacaoEixos > 0.08) { 
        estaNoChao = false;
        emSuspeitaDeQueda = false;
        digitalWrite(pinLedChao, LOW);
        digitalWrite(pinLedLevantado, HIGH);
        Serial.println(">>> STATUS: LEVANTADO / EM USO");
      }
    }

    // Salva posição para o próximo ciclo
    ultX = accel.cx;
    ultY = accel.cy;
    ultZ = accel.cz;
  }
  delay(50); // Delay para o delta de eixos ser perceptível
}