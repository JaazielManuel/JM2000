//=========================  MT5-LIVE-EXECUTOR  =========================
// Agent-controlled MQL5 script for real-time natural language strategies.
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Properties ---
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://github.com/MT-LiveExecutor"
#property version   "1.00"
#property strict

// --- Defines ---
#define EA_MAGIC 123456
#define MAX_RULES 20

// --- Enums ---
enum Signal { BUY = 1, SELL = -1, NONE = 0 };

enum RuleType {
   RT_MA,         // Moving Average
   RT_RSI,        // RSI
   RT_STOCH,      // Stochastic
   RT_BB,         // Bollinger Bands
   RT_DAILYBREAK, // Daily Breakout
   RT_DELTA,      // Aggression Delta
   RT_VOL,        // Volume
   RT_AMA,        // Adaptive MA
   RT_BAR2,       // Bar patterns
   RT_RS          // Relative Strength
};

// --- Structs ---
struct Rule {
   RuleType type;
   Signal   intent;
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
   bool     active;

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      type = RT_MA;
      intent = NONE;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
      active = false;
   }
};

// --- Globals ---
Rule     rules[MAX_RULES];
int      nRules = 0;
CTrade   trade;
CPositionInfo m_pos;

// Strategy parameters
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
int      p_maxTrades = 3;
bool     p_useMartingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
string   p_startTime = "00:00";
int      p_newsVetoMin = 20;

datetime lastPromptUpdate = 0;
datetime lastCSVUpdate = 0;
datetime lastAIUpdate = 0;

// Placeholder for remaining functions to be implemented in subsequent steps

// --- NLP Parser Functions ---

double ExtraiNumero(string txt, int &cursor, int &endPos) {
   string s = "";
   bool found = false;
   int len = StringLen(txt);
   for(int i = cursor; i < len; i++) {
      uchar c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') s += "."; else s += CharToString(c);
         found = true;
      } else if(found) {
         endPos = i;
         cursor = i;
         return StringToDouble(s);
      }
   }
   cursor = len;
   endPos = len;
   return (found) ? StringToDouble(s) : 0;
}

double ExtraiValorApos(string txt, string chave) {
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   int cursor = pos + StringLen(chave);
   int end;
   return ExtraiNumero(txt, cursor, end);
}

int PeriodoTexto(string txt) {
   string work = txt;
   StringToLower(work);
   if(StringFind(work, "m15") >= 0) return PERIOD_M15;
   if(StringFind(work, "m1") >= 0) return PERIOD_M1;
   if(StringFind(work, "m5") >= 0) return PERIOD_M5;
   if(StringFind(work, "h1") >= 0) return PERIOD_H1;
   if(StringFind(work, "d1") >= 0) return PERIOD_D1;
   if(StringFind(work, "minutos") >= 0 || StringFind(work, "min") >= 0) {
      int c = 0, e;
      double v = ExtraiNumero(work, c, e);
      if(v == 1) return PERIOD_M1;
      if(v == 5) return PERIOD_M5;
      if(v == 15) return PERIOD_M15;
      if(v == 30) return PERIOD_M30;
   }
   return PERIOD_CURRENT;
}

void AddRule(string txt, Signal intent) {
   if(nRules >= MAX_RULES) return;
   string work = txt;
   StringToLower(work);
   Rule r;
   r.Reset();
   r.intent = intent;
   r.active = true;
   r.tf = PeriodoTexto(work);
   if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;

   if(StringFind(work, "média") >= 0 || StringFind(work, "ma") >= 0) {
      r.type = RT_MA;
      int c = StringFind(work, "média");
      if(c < 0) c = StringFind(work, "ma");
      int end;
      r.p1 = (int)ExtraiNumero(work, c, end);
      if(r.p1 == 0) r.p1 = 20;
      r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
      // Check for second MA
      r.p2 = (int)ExtraiNumero(work, c, end);
      if(r.p2 > 0) {
         r.handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_EMA, PRICE_CLOSE);
      }
   }
   else if(StringFind(work, "rsi") >= 0) {
      r.type = RT_RSI;
      int c = StringFind(work, "rsi") + 3;
      int end;
      double v1 = ExtraiNumero(work, c, end);
      double v2 = ExtraiNumero(work, c, end);
      if(v2 == 0) {
         r.p1 = 14; r.d1 = v1;
      } else {
         r.p1 = (int)v1; r.d1 = v2;
      }
      if(r.d1 == 0) r.d1 = (intent == BUY) ? 30 : 70;
      r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
   }
   else if(StringFind(work, "estocástico") >= 0 || StringFind(work, "stoch") >= 0) {
      r.type = RT_STOCH;
      r.p1 = 5; r.p2 = 3; r.p3 = 3;
      r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
   }
   else if(StringFind(work, "bollinger") >= 0 || StringFind(work, "bandas") >= 0) {
      r.type = RT_BB;
      r.p1 = 20; r.d1 = 2.0;
      r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
   }
   else if(StringFind(work, "breakout") >= 0 || StringFind(work, "diário") >= 0) {
      r.type = RT_DAILYBREAK;
   }
   else if(StringFind(work, "delta") >= 0 || StringFind(work, "agressão") >= 0) {
      r.type = RT_DELTA;
      r.p1 = 60; r.p2 = 300;
   }
   else if(StringFind(work, "volume") >= 0) {
      r.type = RT_VOL;
      r.p1 = 12;
   }

   if(r.handle1 == INVALID_HANDLE) {
      Print("Error creating handle for rule ", nRules);
      return;
   }
   rules[nRules] = r;
   nRules++;
}

void InterpretaPrompt() {
   string path = "prompt.txt";
   int h = FileOpen(path, FILE_READ|FILE_TXT|FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   string prompt = FileReadString(h);
   FileClose(h);
   if(prompt == "") return;

   for(int i=0; i<nRules; i++) rules[i].Reset();
   nRules = 0;

   string work = prompt;
   StringToLower(work);

   // Global params
   double r = ExtraiValorApos(work, "risco de");
   if(r > 0) p_riskPercent = r;

   double stop = ExtraiValorApos(work, "stop de");
   if(stop > 0) p_stopPoints = (int)stop;

   double take = ExtraiValorApos(work, "take de");
   if(take > 0) p_takePoints = (int)take;

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(work);

   p_beStart = (int)ExtraiValorApos(work, "atingir +");
   p_bePlus = (int)ExtraiValorApos(work, "entrada +");

   p_trailingStop = (int)ExtraiValorApos(work, "trailing");
   if(p_trailingStop > 0) p_trailingStep = 10;

   int maxT = (int)ExtraiValorApos(work, "máximo");
   if(maxT > 0) p_maxTrades = maxT;

   p_newsVetoMin = (int)ExtraiValorApos(work, "notícias");
   if(p_newsVetoMin == 0) p_newsVetoMin = 20;

   // Start time
   int startPos = StringFind(work, "depois das");
   if(startPos < 0) startPos = StringFind(work, "começar");
   if(startPos >= 0) {
      int c = startPos + 10; int e;
      int hh = (int)ExtraiNumero(work, c, e);
      p_startTime = IntegerToString(hh) + ":00";
   }

   // Split logic
   string segments[];
   StringSplit(work, '.', segments);
   Signal currentIntent = NONE;

   for(int i=0; i<ArraySize(segments); i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent != NONE) {
         AddRule(seg, currentIntent);
      }
   }
   Print("Rules loaded: ", nRules);
}

// --- Trading and Utility Logic ---

double GetBufferValue(int handle, int buffer, int shift) {
   double val[];
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

int AvaliaRegra(Rule &r) {
   double val1, val2, p1, p2;
   switch(r.type) {
      case RT_MA:
         if(r.handle2 != INVALID_HANDLE) { // MA vs MA
            val1 = GetBufferValue(r.handle1, 0, 1);
            val2 = GetBufferValue(r.handle2, 0, 1);
            double p_val1 = GetBufferValue(r.handle1, 0, 2);
            double p_val2 = GetBufferValue(r.handle2, 0, 2);
            if(p_val1 < p_val2 && val1 > val2) return (r.intent == BUY) ? 1 : 0;
            if(p_val1 > p_val2 && val1 < val2) return (r.intent == SELL) ? 1 : 0;
         } else { // Price vs MA
            val1 = GetBufferValue(r.handle1, 0, 1);
            p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double p_val1 = GetBufferValue(r.handle1, 0, 2);
            double p_p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            if(p_p1 < p_val1 && p1 > val1) return (r.intent == BUY) ? 1 : 0;
            if(p_p1 > p_val1 && p1 < val1) return (r.intent == SELL) ? 1 : 0;
         }
         break;
      case RT_RSI:
         val1 = GetBufferValue(r.handle1, 0, 1);
         val2 = GetBufferValue(r.handle1, 0, 2);
         if(r.intent == BUY && val2 < r.d1 && val1 > r.d1) return 1;
         if(r.intent == SELL && val2 > r.d1 && val1 < r.d1) return 1;
         break;
      case RT_STOCH:
         val1 = GetBufferValue(r.handle1, 0, 1); // K
         val2 = GetBufferValue(r.handle1, 1, 1); // D
         p1 = GetBufferValue(r.handle1, 0, 2);
         p2 = GetBufferValue(r.handle1, 1, 2);
         if(p1 < p2 && val1 > val2) return (r.intent == BUY) ? 1 : 0;
         if(p1 > p2 && val1 < val2) return (r.intent == SELL) ? 1 : 0;
         break;
      case RT_BB:
         p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         val1 = GetBufferValue(r.handle1, 2, 1); // Lower
         val2 = GetBufferValue(r.handle1, 1, 1); // Upper
         if(p1 < val1) return (r.intent == BUY) ? 1 : 0;
         if(p1 > val2) return (r.intent == SELL) ? 1 : 0;
         break;
      case RT_DAILYBREAK:
         p1 = iClose(_Symbol, PERIOD_M1, 0);
         val1 = iHigh(_Symbol, PERIOD_D1, 1);
         val2 = iLow(_Symbol, PERIOD_D1, 1);
         if(p1 > val1) return (r.intent == BUY) ? 1 : 0;
         if(p1 < val2) return (r.intent == SELL) ? 1 : 0;
         break;
      case RT_DELTA:
         MqlTick ticks[];
         int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
         long b = 0, s = 0;
         for(int i=0; i<n; i++) if((ticks[i].flags & TICK_FLAG_BUY) != 0) b++; else s++;
         if(b - s > r.p2) return (r.intent == BUY) ? 1 : 0;
         if(b - s < -r.p2) return (r.intent == SELL) ? 1 : 0;
         break;
      case RT_VOL:
         double v1 = (double)iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double v2 = (double)iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         if(v1 > v2 * 1.5) return 1;
         break;
      case RT_BAR2:
         double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         if(h0 < h1 && l0 > l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0)) ? ((r.intent == BUY)?1:0) : ((r.intent == SELL)?1:0);
         break;
      case RT_RS:
         val1 = GetBufferValue(r.handle1, 0, 0);
         val2 = GetBufferValue(r.handle2, 0, 0);
         if(val1 > val2 + 5) return (r.intent == BUY) ? 1 : 0;
         if(val1 < val2 - 5) return (r.intent == SELL) ? 1 : 0;
         break;
   }
   return 0;
}

Signal AvaliaTudo() {
   int buyVotes = 0, sellVotes = 0;
   int buyRules = 0, sellRules = 0;
   for(int i=0; i<nRules; i++) {
      if(rules[i].intent == BUY) {
         buyRules++;
         buyVotes += AvaliaRegra(rules[i]);
      } else if(rules[i].intent == SELL) {
         sellRules++;
         sellVotes += AvaliaRegra(rules[i]);
      }
   }
   if(buyRules > 0 && buyVotes == buyRules) return BUY;
   if(sellRules > 0 && sellVotes == sellRules) return SELL;
   return NONE;
}

double CalculaLote(double risco) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * risco / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(p_stopPoints == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double pointsInCash = p_stopPoints * (tickVal / (tickSize / _Point));
   double lot = riskMoney / pointsInCash;

   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2;
            break;
         }
      }
   }
   return NormalizeDouble(lot, 2);
}

void EnviaOrdem(Signal s) {
   if(PositionsTotal() >= p_maxTrades) return;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (s == BUY) ? price - p_stopPoints * _Point : price + p_stopPoints * _Point;
   double tp = (s == BUY) ? price + p_takePoints * _Point : price - p_takePoints * _Point;
   double lot = CalculaLote(p_riskPercent);

   for(int i=0; i<3; i++) {
      trade.SetExpertMagicNumber(EA_MAGIC);
      bool res = (s == BUY) ? trade.Buy(lot, _Symbol, price, sl, tp) : trade.Sell(lot, _Symbol, price, sl, tp);
      if(res) {
         GravaLog("Trade executed: " + EnumToString(s));
         SendNotification("MT-LiveExecutor: Trade " + EnumToString(s));
         return;
      }
      int ret = trade.ResultRetcode();
      if(ret != TRADE_RETCODE_REQUOTES && ret != TRADE_RETCODE_OFFQUOTES) break;
      Sleep(100);
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(m_pos.SelectByIndex(i) && m_pos.Magic() == EA_MAGIC && m_pos.Symbol() == _Symbol) {
         double price = m_pos.PriceCurrent();
         double open = m_pos.PriceOpen();
         double sl = m_pos.StopLoss();
         int type = (int)m_pos.PositionType();
         double profitPoints = (type == POSITION_TYPE_BUY) ? (price - open)/_Point : (open - price)/_Point;

         // Breakeven
         if(p_beStart > 0 && profitPoints >= p_beStart) {
            double newSL = (type == POSITION_TYPE_BUY) ? open + p_bePlus * _Point : open - p_bePlus * _Point;
            if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
               trade.PositionModify(m_pos.Ticket(), newSL, m_pos.TakeProfit());
            }
         }

         // Trailing
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (type == POSITION_TYPE_BUY) ? price - p_trailingStop * _Point : price + p_trailingStop * _Point;
            if((type == POSITION_TYPE_BUY && newSL > sl + p_trailingStep * _Point) || (type == POSITION_TYPE_SELL && (newSL < sl - p_trailingStep * _Point || sl == 0))) {
               trade.PositionModify(m_pos.Ticket(), newSL, m_pos.TakeProfit());
            }
         }
      }
   }
}

bool AguardaNoticias() {
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
   if(h != INVALID_HANDLE) {
      string v = FileReadString(h);
      FileClose(h);
      if(v == "1") return true;
   }
   return false;
}

void GravaLog(string txt) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, TimeToString(TimeCurrent()) + ": " + txt + "\r\n");
      FileClose(h);
   }
}

void GravaCSV() {
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Profit", "SL", "TP");
      for(int i=0; i<PositionsTotal(); i++) {
         if(m_pos.SelectByIndex(i) && m_pos.Magic() == EA_MAGIC) {
            FileWrite(h, m_pos.Ticket(), m_pos.Symbol(), m_pos.PositionType(), m_pos.Profit(), m_pos.StopLoss(), m_pos.TakeProfit());
         }
      }
      FileClose(h);
   }
}

bool IsTimeAllowed() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string now = StringFormat("%02d:%02d", dt.hour, dt.min);
   return (now >= p_startTime);
}

// --- MQL5 Event Handlers ---

int OnInit() {
   InterpretaPrompt();
   EventSetTimer(1);
   lastPromptUpdate = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   for(int i=0; i<nRules; i++) rules[i].Reset();
}

void OnTimer() {
   // Check prompt update
   datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(mod > lastPromptUpdate) {
      lastPromptUpdate = mod;
      InterpretaPrompt();
      GravaLog("Strategy updated from prompt.txt");
   }

   // AI Optimizer (Hourly)
   if(TimeCurrent() - lastAIUpdate > 3600) {
      lastAIUpdate = TimeCurrent();
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      int wins = 0, counts = 0;
      for(int i=total-1; i>=0 && counts < 10; i--) {
         ulong t = HistoryDealGetTicket(i);
         if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(t, DEAL_PROFIT) > 0) wins++;
            counts++;
         }
      }
      if(counts >= 5 && (double)wins/counts < 0.4) {
         p_riskPercent *= 0.8;
         GravaLog("AI Optimizer: Reducing risk due to low win rate.");
      }
   }
}

void OnTick() {
   GerenciaPosicoes();

   if(TimeCurrent() - lastCSVUpdate > 5) {
      lastCSVUpdate = TimeCurrent();
      GravaCSV();
   }

   if(!IsTimeAllowed()) return;
   if(AguardaNoticias()) return;

   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBar) {
      lastBar = currentBar;
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
   }
}
