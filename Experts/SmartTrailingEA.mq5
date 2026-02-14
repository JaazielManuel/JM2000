//+------------------------------------------------------------------+
//|                                              SmartTrailingEA.mq5 |
//|                                  Copyright 2024, Jules AI        |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules AI"
#property link      "https://www.mql5.com"
#property version   "1.10"
#property strict

#include <../Include/UniversalTrailing.mqh>

//+------------------------------------------------------------------+
//| PARÂMETROS DE ENTRADA                                            |
//+------------------------------------------------------------------+
input group "== CONFIGURAÇÃO GERAL =="
input long   InpMagic = 20240501;       // Magic Number do EA
input bool   InpUseTrailing = true;     // Ativar Sistema de Trailing?
input bool   InpOnlyAboveEntry = true;  // Apenas em Lucro (Trailing Estrutural)?
input double InpMaxSpread = 50;         // Spread Máximo Permitido (Pontos)
input int    InpThrottle = 250;         // Intervalo de Processamento (ms)

input group "== MODO DE OPERAÇÃO =="
input ENUM_TRAILING_MODE InpMode = TRL_MODE_ATR; // Algoritmo Principal

input group "== CONFIGURAÇÃO ATR =="
input int    InpATRPeriod = 14;         // Período ATR
input double InpATRMult   = 1.5;        // Multiplicador de Volatilidade

input group "== CONFIGURAÇÃO PSAR =="
input double InpPSARStep = 0.02;        // Passo (Step)
input double InpPSARMax  = 0.2;         // Máximo (Maximum)

input group "== CONFIGURAÇÃO MÉDIA MÓVEL =="
input int    InpMAPeriod = 20;          // Período MA
input ENUM_MA_METHOD InpMAMethod = MODE_SMA; // Método MA

input group "== CONFIGURAÇÃO BOLLINGER =="
input int    InpBBPeriod = 20;          // Período BB
input double InpBBDev    = 2.0;         // Desvio BB

input group "== CONFIGURAÇÃO HIGH/LOW / SHADOW =="
input int    InpCandleCount = 3;        // Qtd de velas para busca

input group "== CONFIGURAÇÃO STEP (TRUE STEP) =="
input double InpStepSize = 100;         // Tamanho do Degrau (Pontos)
input double InpStepMinProfit = 50;     // Lucro Mínimo para iniciar (Pontos)

input group "== CONFIGURAÇÃO BREAKEVEN =="
input double InpBEActivation = 150;     // Ativar BE ao atingir (Pontos)
input double InpBELock = 20;            // Lucro Garantido no BE (Pontos)

//--- VARIÁVEIS GLOBAIS
CUniversalTrailing trailing;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Inicializa a biblioteca
   trailing.Init(InpMagic, _Symbol);

   // Configurações Elite / Institutional+
   trailing.SetMaxSpread(InpMaxSpread);
   trailing.SetThrottle(InpThrottle);
   trailing.SetOnlyAboveEntry(InpOnlyAboveEntry);

   // Configura o modo
   trailing.SetMode(InpMode);

   // Inicializa os indicadores necessários baseados no modo escolhido
   switch(InpMode)
   {
      case TRL_MODE_ATR:       trailing.SetATR(InpATRPeriod, InpATRMult); break;
      case TRL_MODE_PSAR:      trailing.SetPSAR(InpPSARStep, InpPSARMax); break;
      case TRL_MODE_MA:        trailing.SetMA(InpMAPeriod, 0, InpMAMethod, PRICE_CLOSE); break;
      case TRL_MODE_BOLLINGER: trailing.SetBollinger(InpBBPeriod, InpBBDev); break;
      case TRL_MODE_HL:        trailing.SetHL(InpCandleCount); break;
      case TRL_MODE_SHADOW:    trailing.SetHL(InpCandleCount); break;
      case TRL_MODE_FRACTALS:  trailing.SetFractals(); break;
      case TRL_MODE_STEP:      trailing.SetStep(InpStepSize, InpStepMinProfit); break;
   }

   // Configura Breakeven independente do modo de trailing
   trailing.SetBreakeven(InpBEActivation, InpBELock);

   Print("Smart Trailing EA ELITE inicializado com sucesso no ativo: ", _Symbol);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Print("Smart Trailing EA finalizado.");
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // Executa o processamento do trailing
   if(InpUseTrailing)
   {
      trailing.Process();
   }
}
//+------------------------------------------------------------------+
