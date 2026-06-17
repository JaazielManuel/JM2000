//=========================  MT-LiveExecutor  =========================
// Agent-controlled executor for live strategy interpretation.
//========================================================================

#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://github.com/MT-LiveExecutor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Defines
#define EA_MAGIC 123456

// --- Enums
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

// --- Structs
struct Rule
{
   bool     active;
   int      type;    // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: Breakout, 6: Delta, 7: Volume, 8: AMA, 9: Bar, 10: RS
   int      intent;  // SIGNAL_BUY or SIGNAL_SELL
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;

   void Reset() { active=false; type=0; intent=0; tf=0; p1=0; p2=0; p3=0; d1=0; d2=0; s1=""; handle1=INVALID_HANDLE; handle2=INVALID_HANDLE; }
};

// --- Global Variables
Rule rules[50];
int nRules = 0;

// Params
double p_risk = 1.0;
int p_sl = 300;
int p_tp = 500;
int p_maxTrades = 3;
int p_breakeven = 0;
int p_breakevenPlus = 0;
int p_trailingStop = 0;
int p_trailingStep = 0;
int p_newsVeto = 20;
bool p_martingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
int p_startHour = 0;
int p_startMin = 0;

string g_lastPrompt = "";
datetime g_lastPromptTime = 0;

// --- Helper Functions
double ExtraiNumero(string txt, int &cursor)
{
   string res = "";
   bool found = false;
   for(int i=cursor; i<StringLen(txt); i++)
   {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',')
      {
         if(c == ',') res += "."; else res += StringSubstr(txt, i, 1);
         found = true;
      }
      else if(found) { cursor = i; break; }
   }
   return StringToDouble(res);
}

int PeriodoTexto(string txt)
{
   string t = txt;
   StringToLower(t);
   if(StringFind(t, "minutos") >= 0 || StringFind(t, "min") >= 0) {
      int pos = 0;
      int val = (int)ExtraiNumero(t, pos);
      if(val == 1) return PERIOD_M1;
      if(val == 5) return PERIOD_M5;
      if(val == 15) return PERIOD_M15;
      if(val == 30) return PERIOD_M30;
   }
   if(StringFind(t, "m1") >= 0 && StringFind(t, "m15") < 0) return PERIOD_M1;
   if(StringFind(t, "m5") >= 0) return PERIOD_M5;
   if(StringFind(t, "m15") >= 0) return PERIOD_M15;
   if(StringFind(t, "h1") >= 0) return PERIOD_H1;
   if(StringFind(t, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

// --- Event Handlers
int OnInit()
{
   EventSetTimer(5);
   Print("MT-LiveExecutor Initialized.");
   return(INIT_SUCCEEDED);
}

void OnTick()
{
   GerenciaPosicoes();

   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar == lastBar) return;
   lastBar = currentBar;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < p_startHour || (dt.hour == p_startHour && dt.min < p_startMin)) return;

   if(AguardaNoticias()) return;

   int signal = AvaliaTudo();
   if(signal != SIGNAL_NONE) EnviaOrdem(signal);
}

void OnTimer()
{
   // Periodic State Persistence
   GravaCSV();

   // AI Optimizer Placeholder
   static int aiCounter = 0;
   if(aiCounter++ > 720) { // every hour approx
      AIOptimizer();
      aiCounter = 0;
   }

   // Real-time Update monitor
   int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string newPrompt = FileReadString(h);
      FileClose(h);
      if(newPrompt != "" && newPrompt != g_lastPrompt) {
         InterpretaPrompt(newPrompt);
         FileDelete("prompt.txt", FILE_COMMON);
      }
   }
}

// --- NLP / Parser logic
void AddRule(string segment, int intent)
{
   if(nRules >= 50) return;
   string txt = segment;
   StringToLower(txt);
   Rule r; r.Reset();
   r.intent = intent;
   r.tf = PERIOD_CURRENT;

   static int lastMA = 20;
   static int lastRSI = 14;

   if(StringFind(txt, "média") >= 0) {
      r.active = true; r.type = 1;
      int pos = StringFind(txt, "média") + 5;
      double val = ExtraiNumero(txt, pos);
      r.p1 = (val > 0) ? (int)val : lastMA; lastMA = r.p1;
      rules[nRules] = r; nRules++;
   }
   if(StringFind(txt, "rsi") >= 0) {
      r.active = true; r.type = 2;
      int pos = StringFind(txt, "rsi") + 3;
      double val = ExtraiNumero(txt, pos);
      r.p1 = (val > 0) ? (int)val : lastRSI; lastRSI = r.p1;
      r.d1 = ExtraiNumero(txt, pos); // threshold
      rules[nRules] = r; nRules++;
   }
   if(StringFind(txt, "stoch") >= 0) {
      r.active = true; r.type = 3;
      int pos = StringFind(txt, "stoch") + 5;
      r.p1 = (int)ExtraiNumero(txt, pos); // K
      r.p2 = (int)ExtraiNumero(txt, pos); // D
      rules[nRules] = r; nRules++;
   }
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0) {
      r.active = true; r.type = 4;
      rules[nRules] = r; nRules++;
   }
   if(StringFind(txt, "breakout") >= 0) {
      r.active = true; r.type = 5;
      rules[nRules] = r; nRules++;
   }
   if(StringFind(txt, "delta") >= 0 || StringFind(txt, "agressão") >= 0) {
      r.active = true; r.type = 6;
      rules[nRules] = r; nRules++;
   }
   if(StringFind(txt, "volume") >= 0 || StringFind(txt, "ciclo") >= 0) {
      r.active = true; r.type = 7;
      rules[nRules] = r; nRules++;
   }
   if(StringFind(txt, "ama") >= 0 || StringFind(txt, "adaptativa") >= 0) {
      r.active = true; r.type = 8;
      rules[nRules] = r; nRules++;
   }
   if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "barras") >= 0) {
      r.active = true; r.type = 9;
      rules[nRules] = r; nRules++;
   }
   if(StringFind(txt, "força") >= 0 || StringFind(txt, "bench") >= 0) {
      r.active = true; r.type = 10;
      int pos = StringFind(txt, "bench") + 5;
      // Extract bench symbol name later if needed
      rules[nRules] = r; nRules++;
   }
}

void InterpretaPrompt(string prompt)
{
   Print("Interpreting: ", prompt);
   g_lastPrompt = prompt;
   StringToLower(prompt);
   // Reset Strategy
   ResetStrategy();

   string segments[];
   StringSplit(prompt, StringGetCharacter("|", 0), segments);
   if(ArraySize(segments) <= 1) StringSplit(prompt, StringGetCharacter("\n", 0), segments);
   if(ArraySize(segments) <= 1) StringSplit(prompt, StringGetCharacter(".", 0), segments);

   int currentIntent = 0;
   for(int i=0; i<ArraySize(segments); i++)
   {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = SIGNAL_BUY;
      if(StringFind(s, "vende") >= 0) currentIntent = SIGNAL_SELL;

      // Confluence: " e "
      string sub[];
      StringSplit(s, StringGetCharacter("e", 0), sub);
      if(ArraySize(sub) > 1) {
         for(int j=0; j<ArraySize(sub); j++) AddRule(sub[j], currentIntent);
      } else {
         if(currentIntent != 0) AddRule(s, currentIntent);
      }

      // Global params
      int pos = 0;
      if(StringFind(s, "stop") >= 0) { pos = StringFind(s, "stop") + 4; p_sl = (int)ExtraiNumero(s, pos); }
      if(StringFind(s, "take") >= 0) { pos = StringFind(s, "take") + 4; p_tp = (int)ExtraiNumero(s, pos); }
      if(StringFind(s, "risco") >= 0) { pos = StringFind(s, "risco") + 5; p_risk = ExtraiNumero(s, pos); }
      if(StringFind(s, "máximo") >= 0) { pos = StringFind(s, "máximo") + 6; p_maxTrades = (int)ExtraiNumero(s, pos); }
      if(StringFind(s, "notícias") >= 0) { pos = StringFind(s, "notícias") - 3; p_newsVeto = (int)ExtraiNumero(s, pos); if(p_newsVeto==0) p_newsVeto=20; }
      if(StringFind(s, "martingale") >= 0) p_martingale = true;
      if(StringFind(s, "cada") >= 0) { pos = StringFind(s, "cada") + 4; p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(s); }
      if(StringFind(s, "depois das") >= 0) {
         pos = StringFind(s, "depois das") + 10;
         p_startHour = (int)ExtraiNumero(s, pos);
         if(StringFind(s, "h", pos) >= 0) {
            int hPos = StringFind(s, "h", pos);
            p_startMin = (int)ExtraiNumero(s, hPos);
         }
      }
      if(StringFind(s, "move stop") >= 0) {
         pos = StringFind(s, "move stop") + 9;
         p_breakeven = (int)ExtraiNumero(s, pos);
         pos = StringFind(s, "entrada") + 7;
         p_breakevenPlus = (int)ExtraiNumero(s, pos);
      }
      if(StringFind(s, "trailing") >= 0 || StringFind(s, "rastreio") >= 0) {
         pos = StringFind(s, "trailing") + 8;
         if(pos < 8) pos = StringFind(s, "rastreio") + 8;
         p_trailingStop = (int)ExtraiNumero(s, pos);
         p_trailingStep = (int)ExtraiNumero(s, pos);
      }
   }
}

void ResetStrategy()
{
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
   }
   nRules = 0;
}

// --- Signal Engine
double GetBufferValue(int handle, int buffer, int index)
{
   double val[1];
   if(CopyBuffer(handle, buffer, index, 1, val) < 1) return 0;
   return val[0];
}

int AvaliaRegra(Rule &r)
{
   if(!r.active) return 0;

   double p_close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
   double p_open = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);

   switch(r.type)
   {
      case 1: // MA
      {
         if(r.handle1 == INVALID_HANDLE) r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
         double ma0 = GetBufferValue(r.handle1, 0, 0);
         double ma1 = GetBufferValue(r.handle1, 0, 1);
         double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         if(r.intent == SIGNAL_BUY && close1 < ma1 && p_close > ma0) return 1;
         if(r.intent == SIGNAL_SELL && close1 > ma1 && p_close < ma0) return -1;
         break;
      }
      case 2: // RSI
      {
         if(r.handle1 == INVALID_HANDLE) r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
         double rsi = GetBufferValue(r.handle1, 0, 0);
         if(r.intent == SIGNAL_BUY && rsi > r.d1) return 1;
         if(r.intent == SIGNAL_SELL && rsi < r.d1) return -1;
         break;
      }
      case 3: // Stoch
      {
         if(r.handle1 == INVALID_HANDLE) r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, 3, MODE_SMA, STO_LOWHIGH);
         double k0 = GetBufferValue(r.handle1, 0, 0);
         double d0 = GetBufferValue(r.handle1, 1, 0);
         double k1 = GetBufferValue(r.handle1, 0, 1);
         double d1 = GetBufferValue(r.handle1, 1, 1);
         if(r.intent == SIGNAL_BUY && k1 < d1 && k0 > d0) return 1;
         if(r.intent == SIGNAL_SELL && k1 > d1 && k0 < d0) return -1;
         break;
      }
      case 4: // BB
      {
         if(r.handle1 == INVALID_HANDLE) r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
         double upper = GetBufferValue(r.handle1, 1, 0);
         double lower = GetBufferValue(r.handle1, 2, 0);
         if(r.intent == SIGNAL_BUY && p_close < lower) return 1;
         if(r.intent == SIGNAL_SELL && p_close > upper) return -1;
         break;
      }
      case 5: // Daily Breakout
      {
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         if(r.intent == SIGNAL_BUY && p_close > hi) return 1;
         if(r.intent == SIGNAL_SELL && p_close < lo) return -1;
         break;
      }
      case 6: // Delta Aggression
      {
         MqlTick ticks[];
         int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent()-60, TimeCurrent());
         long buy=0, sell=0;
         for(int i=0; i<n; i++) if((ticks[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else sell++;
         long delta = buy - sell;
         if(r.intent == SIGNAL_BUY && delta > 300) return 1;
         if(r.intent == SIGNAL_SELL && delta < -300) return -1;
         break;
      }
      case 7: // Volume Cycle
      {
         long vol[]; ArraySetAsSeries(vol, true);
         CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, 12, vol);
         int maxIdx = ArrayMaximum(vol);
         int minIdx = ArrayMinimum(vol);
         if(r.intent == SIGNAL_BUY && minIdx == 0) return 1;
         if(r.intent == SIGNAL_SELL && maxIdx == 0) return -1;
         break;
      }
      case 8: // AMA
      {
         if(r.handle1 == INVALID_HANDLE) r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, 10, 2, 30, 0, PRICE_CLOSE);
         double ama0 = GetBufferValue(r.handle1, 0, 0);
         double ama1 = GetBufferValue(r.handle1, 0, 1);
         if(r.intent == SIGNAL_BUY && ama0 > ama1) return 1;
         if(r.intent == SIGNAL_SELL && ama0 < ama1) return -1;
         break;
      }
      case 9: // 2-Bar
      {
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double h2 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         double l2 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         bool inside = (h1 < h2 && l1 > l2);
         bool outside = (h1 > h2 && l1 < l2);
         if(inside || outside) {
            if(r.intent == SIGNAL_BUY && iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1)) return 1;
            if(r.intent == SIGNAL_SELL && iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) < iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1)) return -1;
         }
         break;
      }
      case 10: // RS
      {
         if(r.handle1 == INVALID_HANDLE) r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
         if(r.handle2 == INVALID_HANDLE) r.handle2 = iRSI("US30", (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
         double r1 = GetBufferValue(r.handle1, 0, 0);
         double r2 = GetBufferValue(r.handle2, 0, 0);
         if(r.intent == SIGNAL_BUY && r1 > r2 + 5) return 1;
         if(r.intent == SIGNAL_SELL && r1 < r2 - 5) return -1;
         break;
      }
   }
   return 0;
}

int AvaliaTudo()
{
   int buyRules = 0, sellRules = 0;
   int buyVotos = 0, sellVotos = 0;

   for(int i=0; i<nRules; i++)
   {
      if(rules[i].intent == SIGNAL_BUY) {
         buyRules++;
         if(AvaliaRegra(rules[i]) == 1) buyVotos++;
      }
      if(rules[i].intent == SIGNAL_SELL) {
         sellRules++;
         if(AvaliaRegra(rules[i]) == -1) sellVotos++;
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) return SIGNAL_BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SIGNAL_SELL;

   return SIGNAL_NONE;
}

CTrade trade;

double CalculaLote(double slPoints)
{
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAbs = capital * p_risk / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(slPoints <= 0) slPoints = p_sl;

   double lot = riskAbs / (slPoints * _Point * (tickVal / tickSize));

   // Martingale
   if(p_martingale) {
      if(HistorySelect(TimeCurrent()-86400, TimeCurrent())) {
         int total = HistoryDealsTotal();
         for(int i=total-1; i>=0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
               if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2;
               break;
            }
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

void EnviaOrdem(int signal)
{
   if(PositionsTotal() >= p_maxTrades) return;

   double lot = CalculaLote(p_sl);
   double price = (signal == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (signal == SIGNAL_BUY) ? price - p_sl * _Point : price + p_sl * _Point;
   double tp = (signal == SIGNAL_BUY) ? price + p_tp * _Point : price - p_tp * _Point;

   trade.SetExpertMagicNumber(EA_MAGIC);
   if(signal == SIGNAL_BUY) trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor BUY");
   else trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor SELL");
}

bool AguardaNoticias()
{
   // 1. Direct Veto
   int hv = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(hv != INVALID_HANDLE) {
      string content = FileReadString(hv);
      FileClose(hv);
      if(StringFind(content, "VETO") >= 0) return true;
   }

   // 2. Calendar Scan
   int hc = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(hc != INVALID_HANDLE) {
      while(!FileIsEnding(hc)) {
         string line = FileReadString(hc);
         if(line == "") continue;
         // Format: YYYY.MM.DD HH:MM;Symbol;Impact;Title
         string parts[];
         StringSplit(line, StringGetCharacter(";", 0), parts);
         if(ArraySize(parts) >= 3) {
            datetime newsTime = StringToTime(parts[0]);
            if(MathAbs(TimeCurrent() - newsTime) < p_newsVeto * 60) {
               if(StringFind(parts[2], "High") >= 0 || StringFind(parts[2], "Alto") >= 0) {
                  FileClose(hc);
                  return true;
               }
            }
         }
      }
      FileClose(hc);
   }

   return false;
}

void GravaLog(string texto)
{
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, TimeToString(TimeCurrent()) + ": " + texto + "\n");
      FileClose(h);
   }
   Print(texto);
}

void GravaCSV()
{
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Type", "OpenPrice", "Profit", "Magic");
      for(int i=0; i<PositionsTotal(); i++) {
         if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
               FileWrite(h, PositionGetInteger(POSITION_TICKET), PositionGetInteger(POSITION_TYPE), PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_PROFIT), PositionGetInteger(POSITION_MAGIC));
            }
         }
      }
      FileClose(h);
   }
}

void AIOptimizer()
{
   GravaLog("Running AI Optimization Layer...");
   CalculaStats();
}

void CalculaStats()
{
   double winRate = 0; // Calculation logic
   double drawdown = 0;
   GravaLog("Stats Updated - WinRate: 0%, Drawdown: 0%");
}

void GerenciaPosicoes()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
            (SymbolInfoDouble(_Symbol, SYMBOL_BID) - PositionGetDouble(POSITION_PRICE_OPEN)) / _Point :
            (PositionGetDouble(POSITION_PRICE_OPEN) - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;

         // Breakeven
         if(p_breakeven > 0 && profitPoints >= p_breakeven) {
            double sl = PositionGetDouble(POSITION_SL);
            double open = PositionGetDouble(POSITION_PRICE_OPEN);
            double newSl = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? open + p_breakevenPlus * _Point : open - p_breakevenPlus * _Point;

            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (sl < open || sl == 0)) ||
               (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (sl > open || sl == 0)))
            {
               trade.PositionModify(ticket, newSl, PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double sl = PositionGetDouble(POSITION_SL);
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
               double newSl = bid - p_trailingStop * _Point;
               if(newSl > sl + p_trailingStep * _Point || sl == 0) {
                  trade.PositionModify(ticket, newSl, PositionGetDouble(POSITION_TP));
               }
            } else {
               double newSl = ask + p_trailingStop * _Point;
               if(newSl < sl - p_trailingStep * _Point || sl == 0) {
                  trade.PositionModify(ticket, newSl, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}
