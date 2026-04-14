//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- 1. ENUMS E ESTRUTURAS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

enum RuleType {
   RT_MA_CROSS,
   RT_RSI,
   RT_STOCH,
   RT_BB,
   RT_DAILY_BREAK,
   RT_DELTA,
   RT_VOL_CYCLE,
   RT_AMA,
   RT_BAR2,
   RT_RELATIVE,
   RT_AI_PRED
};

struct Rule {
   bool      active;
   RuleType  type;
   int       tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   int       p1_handle, p2_handle; // Handles de indicadores
   Signal    intent; // BUY, SELL ou NONE (se for filtro)
};

// ---------- 2. VARIÁVEIS GLOBAIS DE ESTADO ----------
#define EA_MAGIC 20260101
Rule rules[30];
int nRules = 0;

double p_riskPercent = 1.0;
double p_stopPoints = 0;
double p_takePoints = 0;
int    p_maxTrades = 3;
double p_beStart = 0;
double p_bePlus = 0;
double p_trailingStart = 0;
double p_trailingStep = 10;
bool   p_useMartingale = false;
int    p_startTimeSeconds = 0; // Segundos desde a meia-noite
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;

datetime lastBarTime = 0;
datetime lastCSVWrite = 0;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;

// Protótipos
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string texto);
void GravaCSV();
void CalculaEstatisticas();
double CalculaLote(double risco);
void ResetStrategy();

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   symbolInfo.Name(_Symbol);
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   ResetStrategy();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   ResetStrategy();
}

void ResetStrategy()
{
   for(int i=0; i<nRules; i++)
   {
      if(rules[i].p1_handle != INVALID_HANDLE && rules[i].p1_handle != 0) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE && rules[i].p2_handle != 0) IndicatorRelease(rules[i].p2_handle);
   }
   ZeroMemory(rules);
   for(int i=0; i<30; i++) { rules[i].p1_handle = INVALID_HANDLE; rules[i].p2_handle = INVALID_HANDLE; }
   nRules = 0;

   p_riskPercent = 1.0;
   p_stopPoints = 0;
   p_takePoints = 0;
   p_maxTrades = 3;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
   p_useMartingale = false;
   p_startTimeSeconds = 0;
   p_frequency = PERIOD_CURRENT;
}

// ---------- 3. BIBLIOTECA DE INDICADORES ----------

double GetBufferValue(int handle, int buffer, int shift)
{
   double res[];
   ArraySetAsSeries(res, true);
   if(CopyBuffer(handle, buffer, shift, 1, res) > 0) return res[0];
   return 0;
}

Signal AvaliaRegra(Rule &r)
{
   if(!r.active) return NONE;
   int shift1 = 1;
   int shift2 = 2;

   switch(r.type)
   {
      case RT_MA_CROSS:
      {
         double ma1 = GetBufferValue(r.p1_handle, 0, shift1);
         double ma2 = GetBufferValue(r.p1_handle, 0, shift2);
         double pr1 = GetBufferValue(r.p2_handle, 0, shift1);
         double pr2 = GetBufferValue(r.p2_handle, 0, shift2);
         // Buy when price crosses ABOVE the MA
         if(pr2 <= ma2 && pr1 > ma1) return BUY;
         // Sell when price crosses BELOW the MA
         if(pr2 >= ma2 && pr1 < ma1) return SELL;
         break;
      }
      case RT_RSI:
      {
         double v = GetBufferValue(r.p1_handle, 0, shift1);
         if(r.intent == BUY && v > r.d1) return BUY;
         if(r.intent == SELL && v < r.d2) return SELL;
         // Modo reverso/exaustão se d1 e d2 forem usados como sobrecompra/venda clássicos
         if(r.intent == NONE)
         {
            if(v < r.d2) return BUY;
            if(v > r.d1) return SELL;
         }
         break;
      }
      case RT_STOCH:
      {
         double k1 = GetBufferValue(r.p1_handle, 0, shift1);
         double d1 = GetBufferValue(r.p1_handle, 1, shift1);
         double k2 = GetBufferValue(r.p1_handle, 0, shift2);
         double d2 = GetBufferValue(r.p1_handle, 1, shift2);
         if(k2 <= d2 && k1 > d1) return BUY;
         if(k2 >= d2 && k1 < d1) return SELL;
         break;
      }
      case RT_BB:
      {
         double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift1);
         double upper = GetBufferValue(r.p1_handle, 1, shift1);
         double lower = GetBufferValue(r.p1_handle, 2, shift1);
         if(close < lower) return BUY;
         if(close > upper) return SELL;
         break;
      }
      case RT_DAILY_BREAK:
      {
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double close = iClose(_Symbol, PERIOD_M1, 0);
         if(close > hi) return BUY;
         if(close < lo) return SELL;
         break;
      }
      case RT_DELTA:
      {
         MqlTick ticks[];
         int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
         long buy = 0, sell = 0;
         for(int i=0; i<n; i++) if(ticks[i].flags & TICK_FLAG_BUY) buy++; else if(ticks[i].flags & TICK_FLAG_SELL) sell++;
         long delta = buy - sell;
         if(delta > r.p2) return BUY;
         if(delta < -r.p2) return SELL;
         break;
      }
      case RT_VOL_CYCLE:
      {
         long vol[];
         ArraySetAsSeries(vol, true);
         CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, r.p1, vol);
         int maxIdx = ArrayMaximum(vol);
         int minIdx = ArrayMinimum(vol);
         if(minIdx == 0) return BUY;
         if(maxIdx == 0) return SELL;
         break;
      }
      case RT_AMA:
      {
         double ama1 = GetBufferValue(r.p1_handle, 0, shift1);
         double ama2 = GetBufferValue(r.p1_handle, 0, shift2);
         if(ama1 > ama2) return BUY;
         if(ama1 < ama2) return SELL;
         break;
      }
      case RT_BAR2:
      {
         double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift1);
         double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift1);
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift2);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift2);
         bool inside = (h0 < h1 && l0 > l1);
         bool outside = (h0 > h1 && l0 < l1);
         double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift1);
         double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift1);
         if(inside || outside) return (c0 > o0) ? BUY : SELL;
         break;
      }
      case RT_RELATIVE:
      {
         double r1 = GetBufferValue(r.p1_handle, 0, shift1);
         double r2 = GetBufferValue(r.p2_handle, 0, shift1);
         if(r1 > r2 + 5) return BUY;
         if(r1 < r2 - 5) return SELL;
         break;
      }
      case RT_AI_PRED:
      {
         // Simulação de predição de IA baseada em momentum e volatilidade
         double atr = iATR(_Symbol, PERIOD_CURRENT, 14);
         double body = MathAbs(iClose(_Symbol, PERIOD_CURRENT, 1) - iOpen(_Symbol, PERIOD_CURRENT, 1));
         if(body > GetBufferValue(r.p1_handle, 0, 1) * 1.5) // Explosão de volatilidade
         {
             return (iClose(_Symbol, PERIOD_CURRENT, 1) > iOpen(_Symbol, PERIOD_CURRENT, 1)) ? BUY : SELL;
         }
         break;
      }
   }
   return NONE;
}

Signal AvaliaTudo()
{
   int buyVotos = 0;
   int sellVotos = 0;
   int buyRules = 0;
   int sellRules = 0;

   for(int i=0; i<nRules; i++)
   {
      Signal s = AvaliaRegra(rules[i]);
      if(rules[i].intent == BUY || rules[i].intent == NONE)
      {
         buyRules++;
         if(s == BUY) buyVotos++;
      }
      if(rules[i].intent == SELL || rules[i].intent == NONE)
      {
         sellRules++;
         if(s == SELL) sellVotos++;
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) return BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SELL;
   return NONE;
}

// ---------- 4. MOTOR DE INTERPRETAÇÃO (NLP) ----------

double ExtraiNumero(string txt, int start=0)
{
   string res = "";
   bool achou = false;
   for(int i=start; i<StringLen(txt); i++)
   {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.') { res += CharToString((uchar)c); achou = true; }
      else if(achou) break;
   }
   return StringToDouble(res);
}

double ExtraiValorApos(string txt, string chave)
{
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   return ExtraiNumero(txt, pos + StringLen(chave));
}

int PeriodoTexto(string nome)
{
   nome = StringSubstr(nome, 0, 5);
   StringToLower(nome);
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(nome, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt)
{
   ResetStrategy();
   string original = prompt;
   StringToLower(prompt);

   // Parâmetros globais
   p_riskPercent = ExtraiValorApos(prompt, "risco de");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = ExtraiValorApos(prompt, "stop de");
   p_takePoints = ExtraiValorApos(prompt, "take de");
   p_maxTrades = (int)ExtraiValorApos(prompt, "máximo");
   if(p_maxTrades == 0) p_maxTrades = 3;

   p_beStart = ExtraiValorApos(prompt, "atingir +");
   p_bePlus = ExtraiValorApos(prompt, "entrada +");

   p_trailingStart = ExtraiValorApos(prompt, "trailing de");

   if(StringFind(prompt, "martingale") >= 0) p_useMartingale = true;

   int hPos = StringFind(prompt, "depois das ");
   if(hPos >= 0)
   {
      int hora = (int)ExtraiNumero(prompt, hPos + 11);
      p_startTimeSeconds = hora * 3600;
   }

   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(prompt);

   // Quebra em regras
   string partes[];
   ushort sep = StringGetCharacter("|", 0);
   string limpo = prompt;
   StringReplace(limpo, " e ", "|");
   StringReplace(limpo, ". ", "|");
   StringReplace(limpo, ", ", "|");
   StringSplit(limpo, sep, partes);

   Signal currentIntent = NONE;

   for(int i=0; i<ArraySize(partes); i++)
   {
      string s = partes[i];
      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      if(StringFind(s, "vende") >= 0)  currentIntent = SELL;

      if(nRules >= 30) break;
      Rule r;
      ZeroMemory(r);
      r.p1_handle = INVALID_HANDLE;
      r.p2_handle = INVALID_HANDLE;
      r.active = false;
      r.intent = currentIntent;
      r.tf = p_frequency;

      if(StringFind(s, "média") >= 0)
      {
         r.active = true;
         r.type = RT_MA_CROSS;
         r.p1 = (int)ExtraiNumero(s);
         if(r.p1 == 0) r.p1 = 20;
         r.p2 = 1; // Dummy slow for price cross
         r.p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
         r.p2_handle = INVALID_HANDLE; // Price is handled in AvaliaRegra logic expansion or by using iMA period 1
         // Simplificação: Cruzamento com preço -> MA vs MA de 1 período
         r.p2_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1, 0, MODE_SMA, PRICE_CLOSE);
      }
      else if(StringFind(s, "rsi") >= 0)
      {
         r.active = true;
         r.type = RT_RSI;
         r.p1 = (int)ExtraiNumero(s);
         if(r.p1 == 0) r.p1 = 14;
         r.d1 = ExtraiValorApos(s, "acima de");
         r.d2 = ExtraiValorApos(s, "abaixo de");
         if(r.d1 == 0 && currentIntent == BUY) r.d1 = 55; // Default if omitted
         if(r.d2 == 0 && currentIntent == SELL) r.d2 = 45; // Default if omitted
         r.p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
      }
      else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0)
      {
         r.active = true;
         r.type = RT_STOCH;
         r.p1 = (int)ExtraiNumero(s);
         if(r.p1 == 0) r.p1 = 5;
         r.p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 3, 3, MODE_SMA, STO_LOWHIGH);
      }
      else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bandas") >= 0)
      {
         r.active = true;
         r.type = RT_BB;
         r.p1 = (int)ExtraiNumero(s);
         if(r.p1 == 0) r.p1 = 20;
         r.d1 = 2.0; // Desvio padrão default
         r.p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
      }
      else if(StringFind(s, "delta") >= 0)
      {
         r.active = true;
         r.type = RT_DELTA;
         r.p1 = 60; // 60 segundos default
         r.p2 = (int)ExtraiValorApos(s, "maior que");
         if(r.p2 == 0) r.p2 = 300;
      }
      else if(StringFind(s, "volume") >= 0)
      {
         r.active = true;
         r.type = RT_VOL_CYCLE;
         r.p1 = (int)ExtraiNumero(s);
         if(r.p1 == 0) r.p1 = 12;
      }
      else if(StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0)
      {
         r.active = true;
         r.type = RT_AMA;
         r.p1 = (int)ExtraiNumero(s);
         if(r.p1 == 0) r.p1 = 10;
         r.p1_handle = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 2, 30, 0, PRICE_CLOSE);
      }
      else if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0)
      {
         r.active = true;
         r.type = RT_AI_PRED;
         r.p1_handle = iATR(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14);
      }
      else if(StringFind(s, "rompimento diário") >= 0)
      {
         r.active = true;
         r.type = RT_DAILY_BREAK;
      }
      else if(StringFind(s, "padrão barras") >= 0)
      {
         r.active = true;
         r.type = RT_BAR2;
      }
      else if(StringFind(s, "força relativa") >= 0)
      {
         r.active = true;
         r.type = RT_RELATIVE;
         r.s1 = "US30"; // Default benchmark
         r.p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
         r.p2_handle = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
      }

      if(r.active)
      {
         rules[nRules] = r;
         nRules++;
      }
   }
   GravaLog("Estratégia interpretada: " + (string)nRules + " regras ativas.");
}

// ---------- 5. EXECUÇÃO E GESTÃO ----------

double CalculaLote(double riscoPercent)
{
   double balance = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = balance * (riscoPercent / 100.0);
   double stopLoss = p_stopPoints;
   if(stopLoss <= 0) stopLoss = 500;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pointsPerTick = tickSize / _Point;

   if(tickValue == 0 || tickSize == 0) return 0.01;

   // Formula: Lote = Risco Financeiro / (Stop em Pontos * Valor de 1 Ponto)
   // Valor de 1 Ponto = TickValue / (TickSize / _Point)
   double pointValue = tickValue / pointsPerTick;
   double lot = riskAmount / (stopLoss * pointValue);

   if(p_useMartingale)
   {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
         {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) lot *= 2;
            break;
         }
      }
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void EnviaOrdem(Signal s)
{
   if(s == NONE) return;
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) return;

   double lot = CalculaLote(p_riskPercent);
   double sl = 0, tp = 0;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(s == BUY)
   {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
      trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor BUY");
   }
   else
   {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
      trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor SELL");
   }

   if(trade.ResultRetcode() != TRADE_RETCODE_DONE)
      GravaLog("Erro ao enviar ordem: " + trade.ResultComment());
}

void GerenciaPosicoes()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol)
      {
         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();
         double diffPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

         // Break-even
         if(p_beStart > 0 && diffPoints >= p_beStart)
         {
            double targetSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
            if((posInfo.PositionType() == POSITION_TYPE_BUY && currentSL < targetSL) || (posInfo.PositionType() == POSITION_TYPE_SELL && (currentSL > targetSL || currentSL == 0)))
            {
               trade.PositionModify(posInfo.Ticket(), targetSL, posInfo.TakeProfit());
            }
         }

         // Trailing Stop
         if(p_trailingStart > 0 && diffPoints >= p_trailingStart)
         {
            double targetSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
            if((posInfo.PositionType() == POSITION_TYPE_BUY && targetSL > currentSL + p_trailingStep * _Point) || (posInfo.PositionType() == POSITION_TYPE_SELL && (targetSL < currentSL - p_trailingStep * _Point || currentSL == 0)))
            {
               trade.PositionModify(posInfo.Ticket(), targetSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

bool AguardaNoticias()
{
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      string val = FileReadString(handle);
      FileClose(handle);
      if(val == "1") return true;
      datetime newsTime = StringToTime(val);
      if(newsTime > 0 && MathAbs(TimeCurrent() - newsTime) < 1200) return true;
   }
   return false;
}

// ---------- 6. LOGS E ESTATÍSTICAS ----------

void GravaLog(string texto)
{
   Print(texto);
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, TimeToString(TimeCurrent()) + ": " + texto + "\n");
      FileClose(handle);
   }
}

void GravaCSV()
{
   if(TimeCurrent() - lastCSVWrite < 5) return;
   lastCSVWrite = TimeCurrent();

   int handle = FileOpen("positions_state.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Price", "SL", "TP", "Profit");
      for(int i=0; i<PositionsTotal(); i++)
      {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC)
         {
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
         }
      }
      FileClose(handle);
   }
}

void CalculaEstatisticas()
{
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   double profit = 0;
   int wins = 0, losses = 0;

   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
      {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += p;
         if(p > 0) wins++;
         else if(p < 0) losses++;
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100 : 0;
   GravaLog(StringFormat("Estatísticas: Profit Total: %.2f | Win Rate: %.1f%% | Trades: %d", profit, winRate, wins + losses));
}

// ---------- 7. LOOP PRINCIPAL ----------

void OnTick()
{
   GerenciaPosicoes();
   GravaCSV();

   if(TimeCurrent() < (datetime)((TimeCurrent()/86400)*86400 + p_startTimeSeconds)) return;

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime)
   {
      lastBarTime = currentBar;
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
   }
}

void OnTimer()
{
   static datetime lastAI = 0;
   if(TimeCurrent() - lastAI > 3600) // Roda a cada hora
   {
      AIOptimizer();
      lastAI = TimeCurrent();
   }

   int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      string prompt = FileReadString(handle);
      FileClose(handle);
      if(StringLen(prompt) > 5)
      {
         InterpretaPrompt(prompt);
         // Limpa o arquivo para não re-interpretar no próximo segundo
         int hWrite = FileOpen("prompt.txt", FILE_WRITE | FILE_TXT | FILE_COMMON);
         if(hWrite != INVALID_HANDLE) { FileWriteString(hWrite, ""); FileClose(hWrite); }
      }
   }
}


// ---------- 8. IA OPTIMIZER ----------

void AIOptimizer()
{
   HistorySelect(TimeCurrent() - 7 * 86400, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0;

   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
      {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += p;
         if(p > 0) wins++;
         else if(p < 0) losses++;
      }
   }

   double winRate = (wins + losses > 10) ? (double)wins / (wins + losses) : 0.5;

   // Heurística de IA: Ajusta risco com base na performance
   if(winRate < 0.4)
   {
      p_riskPercent *= 0.9; // Reduz risco se estiver perdendo muito
      GravaLog("IA: Reduzindo risco devido a baixa taxa de acerto.");
   }
   else if(winRate > 0.6 && profit > 0)
   {
      p_riskPercent = MathMin(p_riskPercent * 1.1, 2.0); // Aumenta risco se estiver performando bem
      GravaLog("IA: Aumentando risco devido a alta performance.");
   }

   // Sugestão de filtro de horário (IA)
   if(profit < 0 && wins + losses > 20)
   {
      GravaLog("IA Suggestion: Considere mudar o horário de início ou o ativo.");
   }
}
