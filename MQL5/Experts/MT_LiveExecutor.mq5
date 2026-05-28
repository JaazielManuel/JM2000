//=========================  MT-LiveExecutor  =========================
// Optimized state persistence, NLP interpretation, and trade execution.
// EA_MAGIC: 123456
//========================================================================

#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://github.com/MT-LiveExecutor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- DEFINES & ENUMS ----------
#define EA_MAGIC 123456

enum Signal {BUY=1, SELL=-1, NONE=0};

// ---------- STRUCTS ----------
struct Rule {
   int      type;       // 1: MA, 2: RSI, 3: STOCH, 4: BB, etc.
   int      intent;     // Signal (BUY or SELL)
   int      tf;         // Timeframe
   int      p1, p2, p3; // Integer parameters (period, etc.)
   double   d1, d2;     // Double parameters (thresholds)
   string   s1;         // String parameter (symbol/bench)
   int      handle1;    // Indicator handle 1
   int      handle2;    // Indicator handle 2

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      type = 0;
      intent = NONE;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
   }
};

// ---------- GLOBALS ----------
Rule     g_rules[20];
int      g_nRules = 0;
string   g_lastPrompt = "";
datetime g_lastPromptTime = 0;

// Strategy Parameters (Parsed from Prompt)
double   p_riskPercent  = 1.0;
int      p_maxTrades    = 3;
int      p_stopLoss     = 300;
int      p_takeProfit   = 500;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
int      p_beStart      = 0;
int      p_bePlus       = 0;
string   p_startTime    = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
int      p_newsVeto     = 20; // minutes

// State Tracking
datetime g_lastBarTime = 0;
datetime g_lastStateSave = 0;
datetime g_lastAI = 0;

// Trade Objects
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

// ---------- FORWARD DECLARATIONS ----------
void InterpretaPrompt(string prompt);
void ResetStrategy();
void AddRule(string txt, int currentIntent);
double ExtraiNumero(string txt, int &cursor, int &endPos);
int  PeriodoTexto(string nome);
Signal AvaliaTudo();
bool AvaliaRegra(Rule &r);
void EnviaOrdem(int tipo, double volume, double sl, double tp, string motivo);
void GerenciaPosicoes();
double CalculaLote(double riscoPercent);
bool AguardaNoticias();
bool IsTimeAllowed();
void GravaLog(string texto);
void GravaCSV();
void CalculaStats();
void AIOptimizer();
double GetBufferValue(int handle, int buffer, int shift);

// =======================================================================
// NLP & PARSING
// =======================================================================

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string work = prompt;
   StringToLower(work);
   StringReplace(work, " e ", "."); // Replace conjunction for segmenting

   // Parse parameters
   if(StringFind(work, "risco de") >= 0) {
      int c = StringFind(work, "risco de") + 8;
      int dummy;
      p_riskPercent = ExtraiNumero(work, c, dummy);
   }
   if(StringFind(work, "máximo") >= 0) {
      int c = StringFind(work, "máximo") + 6;
      int dummy;
      p_maxTrades = (int)ExtraiNumero(work, c, dummy);
   }

   // Stop Loss / Take Profit
   if(StringFind(work, "stop de") >= 0) {
      int c = StringFind(work, "stop de") + 7;
      int dummy;
      p_stopLoss = (int)ExtraiNumero(work, c, dummy);
   }
   if(StringFind(work, "take de") >= 0) {
      int c = StringFind(work, "take de") + 7;
      int dummy;
      p_takeProfit = (int)ExtraiNumero(work, c, dummy);
   }

   // Timeframe / Frequency
   if(StringFind(work, "a cada") >= 0) {
      int c = StringFind(work, "a cada") + 6;
      int dummy;
      int val = (int)ExtraiNumero(work, c, dummy);
      string unit = "minutos";
      if(StringFind(work, "min") >= 0) unit = "min";
      if(val > 0) p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(IntegerToString(val) + unit);
   }

   // Start Time
   int startKw = StringFind(work, "depois das");
   if(startKw < 0) startKw = StringFind(work, "início");
   if(startKw < 0) startKw = StringFind(work, "começar");
   if(startKw >= 0) {
      int cursor = startKw + 10;
      int dummy;
      int hh = (int)ExtraiNumero(work, cursor, dummy);
      int mm = 0;
      if(StringGetCharacter(work, cursor) == ':' || StringGetCharacter(work, cursor) == 'h') {
         cursor++;
         mm = (int)ExtraiNumero(work, cursor, dummy);
      }
      p_startTime = StringFormat("%02d:%02d", hh, mm);
   }

   if(StringFind(work, "notícias") >= 0) {
      int c = StringFind(work, "notícias") - 10;
      if(c<0) c=0;
      int dummy;
      p_newsVeto = (int)ExtraiNumero(work, c, dummy);
      if(p_newsVeto == 0) p_newsVeto = 20;
   }
   if(StringFind(work, "atingir") >= 0) {
      int c = StringFind(work, "atingir") + 7;
      int dummy;
      p_beStart = (int)ExtraiNumero(work, c, dummy);
      c = StringFind(work, "entrada +");
      if(c >= 0) {
         c += 9;
         p_bePlus = (int)ExtraiNumero(work, c, dummy);
      }
   }

   // Split into segments by period
   string segments[];
   ushort sep = StringGetCharacter(".", 0);
   int nSeg = StringSplit(work, sep, segments);

   int currentIntent = NONE;
   for(int i=0; i<nSeg; i++) {
      string seg = segments[i];
      StringTrimLeft(seg);
      StringTrimRight(seg);

      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent != NONE) {
         AddRule(seg, currentIntent);
      }
   }

   GravaLog("Prompt interpretado: " + prompt);
   g_lastPrompt = prompt;
   g_lastPromptTime = TimeCurrent();
}

void ResetStrategy() {
   for(int i=0; i<20; i++) g_rules[i].Reset();
   g_nRules = 0;
   p_riskPercent = 1.0;
   p_maxTrades = 3;
   p_stopLoss = 300;
   p_takeProfit = 500;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStop = 0;
   p_trailingStep = 0;
   p_startTime = "00:00";
   p_frequency = PERIOD_M15;
}

void AddRule(string txt, int currentIntent) {
   if(g_nRules >= 20) return;

   int tf = PeriodoTexto(txt);

   // MA Rule
   if(StringFind(txt, "média") >= 0) {
      int cursor = StringFind(txt, "média") + 5;
      int dummy;
      int period = (int)ExtraiNumero(txt, cursor, dummy);
      if(period == 0) period = 20;

      g_rules[g_nRules].type = 1;
      g_rules[g_nRules].intent = currentIntent;
      g_rules[g_nRules].p1 = period;
      g_rules[g_nRules].tf = tf;
      g_rules[g_nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, period, 0, MODE_SMA, PRICE_CLOSE);
      if(g_rules[g_nRules].handle1 != INVALID_HANDLE) g_nRules++;
   }

   // RSI Rule
   if(StringFind(txt, "rsi") >= 0) {
      int cursor = StringFind(txt, "rsi") + 3;
      int endPos;
      double val1 = ExtraiNumero(txt, cursor, endPos);
      double val2 = ExtraiNumero(txt, cursor, endPos);

      int period = 14;
      double threshold = 50;

      if(val1 > 0 && val2 > 0) { period = (int)val1; threshold = val2; }
      else if(val1 >= 40) { threshold = val1; }
      else if(val1 > 0) { period = val1; }

      g_rules[g_nRules].type = 2;
      g_rules[g_nRules].intent = currentIntent;
      g_rules[g_nRules].p1 = period;
      g_rules[g_nRules].d1 = threshold;
      g_rules[g_nRules].tf = tf;
      g_rules[g_nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)tf, period, PRICE_CLOSE);
      if(g_rules[g_nRules].handle1 != INVALID_HANDLE) g_nRules++;
   }

   // Stochastic Rule
   if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
      int cursor = (StringFind(txt, "stoch") >= 0) ? StringFind(txt, "stoch") + 5 : StringFind(txt, "estocástico") + 11;
      int dummy;
      int k = (int)ExtraiNumero(txt, cursor, dummy); if(k == 0) k = 5;
      int d = (int)ExtraiNumero(txt, cursor, dummy); if(d == 0) d = 3;
      int slowing = (int)ExtraiNumero(txt, cursor, dummy); if(slowing == 0) slowing = 3;

      g_rules[g_nRules].type = 3;
      g_rules[g_nRules].intent = currentIntent;
      g_rules[g_nRules].p1 = k; g_rules[g_nRules].p2 = d; g_rules[g_nRules].p3 = slowing;
      g_rules[g_nRules].tf = tf;
      g_rules[g_nRules].handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)tf, k, d, slowing, MODE_SMA, STO_LOWHIGH);
      if(g_rules[g_nRules].handle1 != INVALID_HANDLE) g_nRules++;
   }

   // Bollinger Rule
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0) {
      int cursor = (StringFind(txt, "bollinger") >= 0) ? StringFind(txt, "bollinger") + 9 : StringFind(txt, "bandas") + 6;
      int dummy;
      int period = (int)ExtraiNumero(txt, cursor, dummy); if(period == 0) period = 20;
      double dev = ExtraiNumero(txt, cursor, dummy); if(dev == 0) dev = 2.0;

      g_rules[g_nRules].type = 4;
      g_rules[g_nRules].intent = currentIntent;
      g_rules[g_nRules].p1 = period; g_rules[g_nRules].d1 = dev;
      g_rules[g_nRules].tf = tf;
      g_rules[g_nRules].handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)tf, period, 0, dev, PRICE_CLOSE);
      if(g_rules[g_nRules].handle1 != INVALID_HANDLE) g_nRules++;
   }
}

double ExtraiNumero(string txt, int &cursor, int &endPos) {
   string res = "";
   bool found = false;
   int i = cursor;
   for(; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') res += "."; else res += CharToString((uchar)c);
         found = true;
      } else if(found) break;
   }
   cursor = i;
   endPos = i;
   return StringToDouble(res);
}

int PeriodoTexto(string nome) {
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   return PERIOD_CURRENT;
}

// =======================================================================
// SIGNAL EVALUATION
// =======================================================================

Signal AvaliaTudo() {
   int buyConfirmations = 0;
   int sellConfirmations = 0;
   int buyRules = 0;
   int sellRules = 0;

   for(int i=0; i<g_nRules; i++) {
      bool signal = AvaliaRegra(g_rules[i]);
      if(g_rules[i].intent == BUY) {
         buyRules++;
         if(signal) buyConfirmations++;
      } else if(g_rules[i].intent == SELL) {
         sellRules++;
         if(signal) sellConfirmations++;
      }
   }

   if(buyRules > 0 && buyConfirmations == buyRules) return BUY;
   if(sellRules > 0 && sellConfirmations == sellRules) return SELL;

   return NONE;
}

bool AvaliaRegra(Rule &r) {
   double val1, val2, p1, p2;

   switch(r.type) {
      case 1: // MA vs Price
         val1 = GetBufferValue(r.handle1, 0, 1); // MA Bar 1
         val2 = GetBufferValue(r.handle1, 0, 2); // MA Bar 2
         p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         p2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);

         if(r.intent == BUY) return (p2 < val2 && p1 > val1); // Cross above
         if(r.intent == SELL) return (p2 > val2 && p1 < val1); // Cross below
         break;

      case 2: // RSI
         val1 = GetBufferValue(r.handle1, 0, 1);
         val2 = GetBufferValue(r.handle1, 0, 2);

         if(r.intent == BUY) return (val2 < r.d1 && val1 > r.d1); // Cross above threshold
         if(r.intent == SELL) return (val2 > r.d1 && val1 < r.d1); // Cross below threshold
         break;

      case 3: // Stochastic (K vs D cross)
      {
         double k1 = GetBufferValue(r.handle1, 0, 1);
         double d1 = GetBufferValue(r.handle1, 1, 1);
         double k2 = GetBufferValue(r.handle1, 0, 2);
         double d2 = GetBufferValue(r.handle1, 1, 2);

         if(r.intent == BUY) return (k2 < d2 && k1 > d1); // K cross above D
         if(r.intent == SELL) return (k2 > d2 && k1 < d1); // K cross below D
         break;
      }

      case 4: // Bollinger Bands (Price vs Bands)
      {
         double upper1 = GetBufferValue(r.handle1, 1, 1);
         double lower1 = GetBufferValue(r.handle1, 2, 1);
         double price1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);

         if(r.intent == BUY) return (price1 < lower1); // Price break lower band
         if(r.intent == SELL) return (price1 > upper1); // Price break upper band
         break;
      }
   }

   return false;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) <= 0) return 0;
   return arr[0];
}

// =======================================================================
// TRADE & POSITION MANAGEMENT
// =======================================================================

void EnviaOrdem(int tipo, double volume, double sl, double tp, string motivo) {
   if(PositionsTotal() >= p_maxTrades) return;

   // Margin Check
   double marginReq;
   if(!OrderCalcMargin((ENUM_ORDER_TYPE)tipo, _Symbol, volume, SymbolInfoDouble(_Symbol, SYMBOL_ASK), marginReq)) {
      GravaLog("Erro ao calcular margem.");
      return;
   }
   if(marginReq > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
      GravaLog("Margem insuficiente: " + DoubleToString(marginReq, 2) + " necessária.");
      return;
   }

   bool success = false;
   for(int i=0; i<3; i++) {
      if(tipo == ORDER_TYPE_BUY) success = trade.Buy(volume, _Symbol, 0, sl, tp, motivo);
      else success = trade.Sell(volume, _Symbol, 0, sl, tp, motivo);

      if(success) {
         uint retcode = trade.ResultRetcode();
         if(retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED) {
            GravaLog("Ordem executada: " + motivo + " Lote: " + DoubleToString(volume, 2));
            SendNotification("Trade Executado: " + motivo);
            break;
         } else if(retcode == TRADE_RETCODE_REQUOTES || retcode == TRADE_RETCODE_OFFQUOTES) {
            Sleep(100);
            continue;
         } else {
            GravaLog("Erro na execução: " + trade.ResultComment());
            break;
         }
      }
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Magic() != EA_MAGIC || posInfo.Symbol() != _Symbol) continue;

         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();
         double profitPoints = MathAbs(currentPrice - openPrice) / _Point;

         // Breakeven
         if(p_beStart > 0 && profitPoints >= p_beStart) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
            if(currentSL == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > currentSL) || (posInfo.PositionType() == POSITION_TYPE_SELL && newSL < currentSL)) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
            if(currentSL == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > currentSL + p_trailingStep * _Point) || (posInfo.PositionType() == POSITION_TYPE_SELL && newSL < currentSL - p_trailingStep * _Point)) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

double CalculaLote(double riscoPercent) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAbs = equity * (riscoPercent / 100.0);
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double slPoints = (double)p_stopLoss;
   if(slPoints <= 0) slPoints = 300;

   double lot = riskAbs / (slPoints * tickVal);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

// =======================================================================
// AUXILIARY FEATURES
// =======================================================================

bool AguardaNoticias() {
   // Binary news veto
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string val = FileReadString(handle);
      FileClose(handle);
      if(val == "1") return true;
   }

   // Calendar-based news veto
   handle = FileOpen("calendar.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      while(!FileIsEnding(handle)) {
         string line = FileReadString(handle);
         if(StringFind(line, "high-impact") >= 0) {
            // Extract time from line (assuming format: "HH:MM high-impact ...")
            int c = 0, dummy;
            int hh = (int)ExtraiNumero(line, c, dummy);
            if(StringGetCharacter(line, c) == ':') c++;
            int mm = (int)ExtraiNumero(line, c, dummy);

            MqlDateTime dt;
            TimeToStruct(TimeCurrent(), dt);
            dt.hour = hh; dt.min = mm; dt.sec = 0;
            datetime newsTime = StructToTime(dt);

            long diff = MathAbs(TimeCurrent() - newsTime) / 60; // difference in minutes
            if(diff <= p_newsVeto) {
               FileClose(handle);
               return true;
            }
         }
      }
      FileClose(handle);
   }
   return false;
}

bool IsTimeAllowed() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string now = StringFormat("%02d:%02d", dt.hour, dt.min);
   return (now >= p_startTime);
}

void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(handle);
   }
   Print(texto);
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Profit");
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() == EA_MAGIC) {
               FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Profit());
            }
         }
      }
      FileClose(handle);
   }
}

void CalculaStats() {
   // Simulated calculation
   GravaLog("Estatísticas atualizadas.");
}

void AIOptimizer() {
   if(TimeCurrent() - g_lastAI < 3600) return;
   g_lastAI = TimeCurrent();

   // Analyze win rate (simulated)
   double winRate = 0.5; // placeholder
   if(winRate < 0.4) p_riskPercent *= 0.9;
   GravaLog("AI Optimizer executado.");
}

// =======================================================================
// EVENT HANDLERS
// =======================================================================

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);

   // Initial prompt check
   int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle);
      FileClose(handle);
      InterpretaPrompt(prompt);
   } else {
      // Default prompt for testing
      InterpretaPrompt("A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45.");
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   for(int i=0; i<20; i++) g_rules[i].Reset();
}

void OnTick() {
   GerenciaPosicoes();

   // Throttled CSV save
   if(TimeCurrent() - g_lastStateSave >= 5) {
      GravaCSV();
      g_lastStateSave = TimeCurrent();
   }

   // Check for new bar
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != g_lastBarTime) {
      g_lastBarTime = currentBar;

      if(IsTimeAllowed() && !AguardaNoticias()) {
         Signal s = AvaliaTudo();
         if(s != NONE) {
            double lote = CalculaLote(p_riskPercent);
            double sl = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) - p_stopLoss * _Point : SymbolInfoDouble(_Symbol, SYMBOL_ASK) + p_stopLoss * _Point;
            double tp = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) + p_takeProfit * _Point : SymbolInfoDouble(_Symbol, SYMBOL_BID) - p_takeProfit * _Point;
            EnviaOrdem((s == BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, lote, sl, tp, "Sinal validado");
         }
      }
   }
}

void OnTimer() {
   // Check for updated prompt
   int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      datetime modTime = (datetime)FileGetInteger(handle, FILE_MODIFY_DATE);
      if(modTime > g_lastPromptTime) {
         string prompt = FileReadString(handle);
         InterpretaPrompt(prompt);
      }
      FileClose(handle);
   }

   AIOptimizer();
}
