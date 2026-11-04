#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h> // Essencial para o Flutter conseguir ativar as Notificações

// Os UUIDs exatos que o teu Flutter está à procura
#define SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

BLEServer* pServer = NULL;
BLECharacteristic* pCharacteristic = NULL;
bool deviceConnected = false;
bool oldDeviceConnected = false;

// Variáveis de teste
unsigned long tempoAnterior = 0;
int bateriaSimulada = 100;

// Callbacks para detetar quando o telemóvel conecta ou desconecta
class MyServerCallbacks: public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
      deviceConnected = true;
      Serial.println("Telemovel conectado à Bengala!");
    };

    void onDisconnect(BLEServer* pServer) {
      deviceConnected = false;
      Serial.println("Telemovel desconectado!");
    }
};

void setup() {
  Serial.begin(115200);
  Serial.println("A iniciar o Bluetooth da Bengala...");

  // 1. Nome do dispositivo que vai aparecer no Radar do Flutter
  BLEDevice::init("Bengala_ESP32");

  // 2. Criar o Servidor BLE
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  // 3. Criar o Serviço BLE com o UUID correto
  BLEService *pService = pServer->createService(SERVICE_UUID);

  // 4. Criar a Característica com permissão para NOTIFY (Notificar o telemóvel)
  pCharacteristic = pService->createCharacteristic(
                      CHARACTERISTIC_UUID,
                      BLECharacteristic::PROPERTY_READ   |
                      BLECharacteristic::PROPERTY_WRITE  |
                      BLECharacteristic::PROPERTY_NOTIFY |
                      BLECharacteristic::PROPERTY_INDICATE
                    );

  // IMPORTANTE: Adicionar este descritor permite que o Flutter ative o ".setNotifyValue(true)" sem dar erro
  pCharacteristic->addDescriptor(new BLE2902());

  // 5. Iniciar o serviço
  pService->start();

  // 6. Iniciar a publicidade (Advertising) para o telemóvel o encontrar
  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(false);
  pAdvertising->setMinPreferred(0x0);  
  BLEDevice::startAdvertising();
  
  Serial.println("Bluetooth ligado! Podes conectar pelo aplicativo Flutter.");
}

void loop() {
  // Se o Flutter estiver conectado, enviar dados a cada 5 segundos
  if (deviceConnected) {
    unsigned long tempoAtual = millis();
    
    if (tempoAtual - tempoAnterior > 5000) {
      tempoAnterior = tempoAtual;

      // Descarregar bateria falsa só para ver o valor a mudar na app
      bateriaSimulada -= 2;
      if (bateriaSimulada < 0) bateriaSimulada = 100;

      // Criar o pacote JSON exatamente com as chaves que o Flutter espera
      // (bat, emerg, lat, lng)
      char jsonBuffer[128];
      snprintf(jsonBuffer, sizeof(jsonBuffer),
               "{\"bat\":%d, \"emerg\":0, \"lat\":-29.4666, \"lng\":-51.9666}",
               bateriaSimulada);

      // Enviar os dados via Bluetooth
      pCharacteristic->setValue(jsonBuffer);
      pCharacteristic->notify();
      
      Serial.print("Dados enviados para o Flutter: ");
      Serial.println(jsonBuffer);
    }
  }

  // Gestão de desconexão (volta a ligar o modo de emparelhamento)
  if (!deviceConnected && oldDeviceConnected) {
      delay(500); 
      pServer->startAdvertising(); 
      Serial.println("A aguardar nova conexão...");
      oldDeviceConnected = deviceConnected;
  }
  
  if (deviceConnected && !oldDeviceConnected) {
      oldDeviceConnected = deviceConnected;
  }
}