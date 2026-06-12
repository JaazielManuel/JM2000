//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Procedural Natural Language Strategy Executor
//========================================================================

#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Constants ---
#define EA_MAGIC 123456

// --- Enums ---
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

// --- Structs ---
struct Rule {
   bool     active;
   int      type;       // 1: MA Cross, 2: RSI, 3: Stoch, etc.
   int      intent;     // SIGNAL_BUY or SIGNAL_SELL
   int      tf;         // Timeframe
   int      p1, p2, p3; // Integer parameters (periods, etc)
   double   d1, d2;     // Double parameters (thresholds, etc)
   string   s1;         // String parameter (symbol, etc)
   int      handle1, handle2;

   void Reset() {
      active = false;
      type = 0;
      intent = SIGNAL_NONE;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
   }
};

// --- Global Variables ---
Rule rules[100];
int nRules = 0;

// Strategy Parameters (Parsed from Prompt)
double p_risk = 1.0;          // % Risk
int    p_sl = 0;              // SL in points
int    p_tp = 0;              // TP in points
int    p_maxTrades = 3;       // Max concurrent trades
int    p_breakeven = 0;       // Breakeven trigger points
int    p_breakevenPlus = 0;   // Breakeven profit points
int    p_trailingStop = 0;    // Trailing stop trigger/distance points
int    p_trailingStep = 0;    // Trailing stop step points
bool   p_martingale = false;  // Martingale logic
int    p_newsVeto = 20;       // Minutes to veto around news
string p_startTime = "00:00"; // Start time (HH:MM)
ENUM_TIMEFRAMES p_frequency = PERIOD_M15; // Execution frequency

// Global State
datetime lastBarTime = 0;
datetime lastPromptCheck = 0;
datetime lastAI = 0;
datetime lastCSVUpdate = 0;
int currentIntent = SIGNAL_NONE;

// MQL5 Objects
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// Function prototypes
void InterpretaPrompt(string prompt);
void AddRule(string txt);
int  PeriodoTexto(string nome);
double ExtraiNumero(string txt, int &cursor);
void ResetStrategy();
ENUM_SIGNAL AvaliaTudo();
int  AvaliaRegra(Rule &r);
void EnviaOrdem(ENUM_SIGNAL s, string reason);
double CalculaLote(double riscoPercent, int slPoints);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string texto);
void GravaCSV();
double GetBufferValue(int handle, int buffer_num, int shift);
void CalculaStats();
bool AIPredict();
void AIOptimizer();

// --- Utility Functions ---

void GravaLog(string texto) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(h);
   }
   Print(texto);
}

void GravaCSV() {
   if(TimeCurrent() - lastCSVUpdate < 5) return;
   lastCSVUpdate = TimeCurrent();

   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Price", "SL", "TP", "Profit");
      for(int i=0; i<PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
            FileWrite(h, ticket, PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_TYPE),
                      PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL),
                      PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT));
         }
      }
      FileClose(h);
   }
}

int PeriodoTexto(string nome) {
   string s = nome;
   StringToLower(s);
   if(StringFind(s, "m15") >= 0) return PERIOD_M15; // Order matters to avoid collision
   if(StringFind(s, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(s, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(s, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(s, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(s, "d1") >= 0)  return PERIOD_D1;
   if(StringFind(s, "minutos") >= 0 || StringFind(s, "min") >= 0) {
      int c = 0; double n = ExtraiNumero(s, c);
      if(n == 1) return PERIOD_M1;
      if(n == 5) return PERIOD_M5;
      if(n == 15) return PERIOD_M15;
   }
   return PERIOD_CURRENT;
}

double ExtraiNumero(string txt, int &cursor) {
   string res = "";
   bool found = false;
   for(int i = cursor; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') c = '.';
         res += ShortToString(c);
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
      if(i == StringLen(txt)-1) cursor = i + 1;
   }
   return StringToDouble(res);
}

double GetBufferValue(int handle, int buffer_num, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer_num, shift, 1, val) > 0) return val[0];
   return 0;
}

// --- NLP Parser ---

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string p = prompt;
   StringToLower(p);
   StringReplace(p, " e ", ".");

   string segments[];
   int n = StringSplit(p, '.', segments);

   for(int i=0; i<n; i++) {
      string s = segments[i];
      StringTrimLeft(s); StringTrimRight(s);

      // Global parameters
      int cursor = 0;
      if(StringFind(s, "risco") >= 0) { cursor = StringFind(s, "risco"); p_risk = ExtraiNumero(s, cursor); }
      if(StringFind(s, "stop") >= 0 && StringFind(s, "move") < 0) { cursor = StringFind(s, "stop"); p_sl = (int)ExtraiNumero(s, cursor); }
      if(StringFind(s, "take") >= 0) { cursor = StringFind(s, "take"); p_tp = (int)ExtraiNumero(s, cursor); }
      if(StringFind(s, "máximo") >= 0) { cursor = StringFind(s, "máximo"); p_maxTrades = (int)ExtraiNumero(s, cursor); }
      if(StringFind(s, "martingale") >= 0) p_martingale = true;
      if(StringFind(s, "notícias") >= 0) { cursor = StringFind(s, "notícias"); p_newsVeto = (int)ExtraiNumero(s, cursor); if(p_newsVeto == 0) p_newsVeto = 20; }

      if(StringFind(s, "breakeven") >= 0 || (StringFind(s, "move") >= 0 && StringFind(s, "stop") >= 0)) {
         cursor = StringFind(s, "move") >= 0 ? StringFind(s, "move") : StringFind(s, "breakeven");
         p_breakeven = (int)ExtraiNumero(s, cursor);
         p_breakevenPlus = (int)ExtraiNumero(s, cursor);
      }

      if(StringFind(s, "trailing") >= 0) {
         cursor = StringFind(s, "trailing");
         p_trailingStop = (int)ExtraiNumero(s, cursor);
         p_trailingStep = (int)ExtraiNumero(s, cursor);
         if(p_trailingStep == 0) p_trailingStep = 10;
      }

      if(StringFind(s, "início") >= 0 || StringFind(s, "começar") >= 0 || StringFind(s, "depois das") >= 0) {
         int h=0, m=0; cursor = 0;
         if(StringFind(s, "depois das") >= 0) cursor = StringFind(s, "depois das");
         else if(StringFind(s, "início") >= 0) cursor = StringFind(s, "início");
         else cursor = StringFind(s, "começar");
         h = (int)ExtraiNumero(s, cursor);
         m = (int)ExtraiNumero(s, cursor);
         p_startTime = StringFormat("%02d:%02d", h, m);
      }

      if(StringFind(s, "cada") >= 0 || StringFind(s, "frequência") >= 0) {
         p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(s);
      }

      // Intent detection
      if(StringFind(s, "compra") >= 0) currentIntent = SIGNAL_BUY;
      if(StringFind(s, "venda") >= 0) currentIntent = SIGNAL_SELL;

      AddRule(s);
   }
   GravaLog("Estratégia interpretada. Regras: " + IntegerToString(nRules));
}

void ResetStrategy() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
      rules[i].Reset();
   }
   nRules = 0;
   currentIntent = SIGNAL_NONE;
}

void AddRule(string txt) {
   if(nRules >= 100) return;
   Rule r; r.Reset();
   r.intent = currentIntent;
   r.tf = PeriodoTexto(txt);

   static int lastMA = 20;
   static int lastRSI = 14;

   int cursor = 0;

   // 1. MA Cross
   if(StringFind(txt, "média") >= 0 || StringFind(txt, "ma") >= 0) {
      r.type = 1;
      cursor = StringFind(txt, "média") >= 0 ? StringFind(txt, "média") : StringFind(txt, "ma");
      r.p1 = (int)ExtraiNumero(txt, cursor);
      if(r.p1 == 0) r.p1 = lastMA; else lastMA = r.p1;
      r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; return; }
   }

   // 2. RSI
   if(StringFind(txt, "rsi") >= 0) {
      r.type = 2;
      cursor = StringFind(txt, "rsi");
      r.p1 = (int)ExtraiNumero(txt, cursor);
      if(r.p1 == 0) r.p1 = lastRSI; else lastRSI = r.p1;
      r.d1 = ExtraiNumero(txt, cursor); // threshold
      r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; return; }
   }

   // 3. Stoch
   if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
      r.type = 3;
      r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; return; }
   }

   // 4. Bollinger Bands
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bb") >= 0) {
      r.type = 4;
      r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; return; }
   }

   // 5. Daily Breakout
   if(StringFind(txt, "breakout") >= 0 || StringFind(txt, "rompimento") >= 0) {
      r.type = 5;
      r.active = true; rules[nRules++] = r; return;
   }

   // 6. Delta Aggression
   if(StringFind(txt, "delta") >= 0 || StringFind(txt, "agressão") >= 0) {
      r.type = 6;
      r.active = true; rules[nRules++] = r; return;
   }

   // 7. Volume Cycle
   if(StringFind(txt, "volume") >= 0) {
      r.type = 7;
      r.active = true; rules[nRules++] = r; return;
   }

   // 8. AMA
   if(StringFind(txt, "ama") >= 0) {
      r.type = 8;
      r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, 10, 2, 30, 0, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; return; }
   }

   // 9. 2-Bar Patterns
   if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "candle") >= 0) {
      r.type = 9;
      r.active = true; rules[nRules++] = r; return;
   }

   // 10. Relative Strength
   if(StringFind(txt, "força relativa") >= 0 || StringFind(txt, "rs") >= 0) {
      r.type = 10;
      r.s1 = "US30"; // Benchmark
      r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
      r.handle2 = iRSI(r.s1, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE && r.handle2 != INVALID_HANDLE) { r.active = true; rules[nRules++] = r; return; }
   }
}

// --- Signal Engine ---

ENUM_SIGNAL AvaliaTudo() {
   int buyVotos = 0, buyRules = 0;
   int sellVotos = 0, sellRules = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      int res = AvaliaRegra(rules[i]);
      if(rules[i].intent == SIGNAL_BUY) { buyRules++; if(res == 1) buyVotos++; }
      if(rules[i].intent == SIGNAL_SELL) { sellRules++; if(res == -1) sellVotos++; }
   }

   if(buyRules > 0 && buyVotos == buyRules) return SIGNAL_BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SIGNAL_SELL;

   return SIGNAL_NONE;
}

int AvaliaRegra(Rule &r) {
   double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
   double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);

   switch(r.type) {
      case 1: { // MA Cross
         double ma1 = GetBufferValue(r.handle1, 0, 1);
         double ma2 = GetBufferValue(r.handle1, 0, 2);
         if(close2 < ma2 && close1 > ma1) return 1;
         if(close2 > ma2 && close1 < ma1) return -1;
         break;
      }
      case 2: { // RSI
         double rsi1 = GetBufferValue(r.handle1, 0, 1);
         double rsi2 = GetBufferValue(r.handle1, 0, 2);
         if(r.intent == SIGNAL_BUY && rsi2 <= r.d1 && rsi1 > r.d1) return 1;
         if(r.intent == SIGNAL_SELL && rsi2 >= r.d1 && rsi1 < r.d1) return -1;
         break;
      }
      case 3: { // Stoch
         double k1 = GetBufferValue(r.handle1, 0, 1);
         double d1 = GetBufferValue(r.handle1, 1, 1);
         double k2 = GetBufferValue(r.handle1, 0, 2);
         double d2 = GetBufferValue(r.handle1, 1, 2);
         if(k2 < d2 && k1 > d1) return 1;
         if(k2 > d2 && k1 < d1) return -1;
         break;
      }
      case 4: { // Bollinger Bands
         double upper1 = GetBufferValue(r.handle1, 1, 1);
         double lower1 = GetBufferValue(r.handle1, 2, 1);
         if(close1 < lower1) return 1;
         if(close1 > upper1) return -1;
         break;
      }
      case 5: { // Daily Breakout
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         if(close1 > hi) return 1;
         if(close1 < lo) return -1;
         break;
      }
      case 6: { // Delta
         return 0; // Placeholder
      }
      case 7: { // Volume
         return 0; // Placeholder
      }
      case 8: { // AMA
         double ama1 = GetBufferValue(r.handle1, 0, 1);
         double ama2 = GetBufferValue(r.handle1, 0, 2);
         if(ama2 < ama1) return 1;
         if(ama2 > ama1) return -1;
         break;
      }
      case 9: { // 2-Bar Patterns
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double h2 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         double l2 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         double o1 = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double c1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         if(h1 < h2 && l1 > l2) return (c1 > o1) ? 1 : -1; // Inside
         if(h1 > h2 && l1 < l2) return (c1 > o1) ? -1 : 1; // Outside
         break;
      }
      case 10: { // Relative Strength
         double rs1 = GetBufferValue(r.handle1, 0, 1);
         double rs2 = GetBufferValue(r.handle2, 0, 1);
         if(rs1 > rs2 + 5) return 1;
         if(rs1 < rs2 - 5) return -1;
         break;
      }
   }
   return 0;
}

// --- Trade Management ---

void EnviaOrdem(ENUM_SIGNAL s, string reason) {
   if(s == SIGNAL_NONE) return;
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) return;

   double lote = CalculaLote(p_risk, p_sl);
   double price = (s == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(p_sl > 0) sl = (s == SIGNAL_BUY) ? price - p_sl * _Point : price + p_sl * _Point;
   if(p_tp > 0) tp = (s == SIGNAL_BUY) ? price + p_tp * _Point : price - p_tp * _Point;

   trade.SetExpertMagicNumber(EA_MAGIC);
   bool res = false;
   if(s == SIGNAL_BUY) res = trade.Buy(lote, _Symbol, price, sl, tp, reason);
   else res = trade.Sell(lote, _Symbol, price, sl, tp, reason);

   if(res) {
      GravaLog(StringFormat("Ordem enviada: %s, Lote: %.2f, Motivo: %s", (s == SIGNAL_BUY ? "BUY" : "SELL"), lote, reason));
      SendNotification("Trade Executado: " + reason);
      SendMail("Trade Executado", reason);
   } else {
      GravaLog("Erro ao enviar ordem: " + IntegerToString(trade.ResultRetcode()));
   }
}

double CalculaLote(double riscoPercent, int slPoints) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;

   if(p_martingale) {
      HistorySelect(TimeCurrent()-86400*7, TimeCurrent());
      for(int i=HistoryDealsTotal()-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riscoAbs *= 2;
            break;
         }
      }
   }

   if(slPoints <= 0) slPoints = 300; // Default if not specified

   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double lote = riscoAbs / (slPoints * _Point * (tickVal / tickSize));
   lote = MathFloor(lote / lotStep) * lotStep;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lote < minLot) lote = minLot;
   if(lote > maxLot) lote = maxLot;

   return NormalizeDouble(lote, 2);
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
         double profitPoints = PositionGetDouble(POSITION_PROFIT) / SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) / _Point;
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentSL = PositionGetDouble(POSITION_SL);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         // Breakeven
         if(p_breakeven > 0 && profitPoints >= p_breakeven) {
            double targetSL = (type == POSITION_TYPE_BUY) ? openPrice + p_breakevenPlus * _Point : openPrice - p_breakevenPlus * _Point;
            if((type == POSITION_TYPE_BUY && currentSL < targetSL) || (type == POSITION_TYPE_SELL && (currentSL > targetSL || currentSL == 0))) {
               trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double targetSL = (type == POSITION_TYPE_BUY) ? bid - p_trailingStop * _Point : ask + p_trailingStop * _Point;

            if(type == POSITION_TYPE_BUY && targetSL > currentSL + p_trailingStep * _Point) {
               trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
            } else if(type == POSITION_TYPE_SELL && (targetSL < currentSL - p_trailingStep * _Point || currentSL == 0)) {
               trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

bool AguardaNoticias() {
   // news_veto.txt binary flag
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string content = FileReadString(h);
      FileClose(h);
      if(content == "1") return true;
   }

   // calendar.txt scan
   h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      while(!FileIsEnding(h)) {
         string line = FileReadString(h);
         if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            string parts[]; StringSplit(line, ';', parts);
            if(ArraySize(parts) > 0) {
               datetime newsTime = StringToTime(parts[0]);
               if(MathAbs(TimeCurrent() - newsTime) < p_newsVeto * 60) {
                  FileClose(h);
                  return true;
               }
            }
         }
      }
      FileClose(h);
   }

   return false;
}

// --- MQL5 Event Handlers ---

int OnInit() {
   EventSetTimer(1);
   trade.SetExpertMagicNumber(EA_MAGIC);
   GravaLog("MT-LiveExecutor Iniciado.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
   GravaLog("MT-LiveExecutor Finalizado.");
}

void OnTick() {
   GerenciaPosicoes();
   GravaCSV();

   datetime currentTime = iTime(_Symbol, p_frequency, 0);
   if(currentTime != lastBarTime) {
      lastBarTime = currentTime;

      // Check start time
      if(TimeToString(TimeCurrent(), TIME_MINUTES) < p_startTime) return;

      ENUM_SIGNAL s = AvaliaTudo();
      if(s != SIGNAL_NONE) {
         if(AIPredict()) {
            EnviaOrdem(s, "Sinal Estratégia + IA");
         }
      }
   }
}

void OnTimer() {
   // Check for new prompt
   if(TimeCurrent() - lastPromptCheck > 5) {
      lastPromptCheck = TimeCurrent();
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string prompt = FileReadString(h);
         static string lastPrompt = "";
         if(prompt != lastPrompt && prompt != "") {
            lastPrompt = prompt;
            InterpretaPrompt(prompt);
         }
         FileClose(h);
      }
   }

   // AI Optimizer
   if(TimeCurrent() - lastAI > 3600) {
      lastAI = TimeCurrent();
      AIOptimizer();
      CalculaStats();
   }
}

// --- AI & Stats Placeholders ---

void CalculaStats() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   GravaLog(StringFormat("Stats: Balance: %.2f", balance));
}

bool AIPredict() {
   return true; // Placeholder for advanced IA logic
}

void AIOptimizer() {
   GravaLog("IA Optimizer rodando...");
}
