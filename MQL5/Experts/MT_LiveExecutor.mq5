//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, Jules AI Agent |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules AI Agent"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

//=========================  MT5-KNOWLEDGE-CORE  =========================
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- 1. BIBLIOTECA COMPLETA DE ENTRADAS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

// Rule types for the internal parser
enum ENUM_RULE_TYPE {
   RULE_MA_CROSS,
   RULE_RSI,
   RULE_STOCH,
   RULE_BB,
   RULE_DAILY_BREAK,
   RULE_DELTA,
   RULE_VOLUME,
   RULE_AMA,
   RULE_BAR2,
   RULE_RELATIVE
};

struct Rule {
   bool            active;
   ENUM_RULE_TYPE  type;
   Signal          intent; // BUY or SELL context from prompt
   int             tf;
   int             p1, p2, p3;
   double          d1, d2;
   string          s1;
   int             handle1, handle2;

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      active = false;
      type = RULE_MA_CROSS;
      intent = NONE;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
   }
};

// Global variables
Rule     rules[20];
int      nRules = 0;
CTrade   trade;
int      EA_MAGIC = 123456;

// Strategy parameters
double   p_riskPercent = 1.0;
int      p_stopPoints = 0;
int      p_takePoints = 0;
int      p_maxTrades = 3;
int      p_frequency = PERIOD_M15;
string   p_startTime = "00:00";
bool     p_useMartingale = false;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
int      p_newsVetoMinutes = 20;

// Internal state
datetime lastBarTime = 0;
datetime lastAI = 0;
datetime lastCSV = 0;

// Prototypes
void InterpretaPrompt(string prompt);
void AddRule(string txt, Signal currentIntent);
Signal AvaliaTudo();
Signal AvaliaRegra(Rule &r);
double CalculaLote(double riscoPercent);
void EnviaOrdem(Signal s, double risco);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string texto);
void GravaCSV();
void ResetStrategy();
int PeriodoTexto(string nome);
double GetBufferValue(int handle, int buffer, int shift);
bool IsTimeAllowed();
void AIOptimizer();
double ExtraiNumero(string txt, int &cursor);
double ExtraiValorApos(string txt, string keyword);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   lastBarTime = 0;
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

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   GerenciaPosicoes();

   if(TimeCurrent() - lastCSV >= 5) {
      GravaCSV();
      lastCSV = TimeCurrent();
   }

   datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_frequency, 0);
   if(currentBar != lastBarTime) {
      if(IsTimeAllowed() && !AguardaNoticias() && PositionsTotal() < p_maxTrades) {
         Signal s = AvaliaTudo();
         if(s != NONE) EnviaOrdem(s, p_riskPercent);
      }
      lastBarTime = currentBar;
   }
}

//+------------------------------------------------------------------+
//| Timer function                                                   |
//+------------------------------------------------------------------+
void OnTimer()
{
   // Check for new prompt
   string filename = "prompt.txt";
   if(FileIsExist(filename)) {
      int h = FileOpen(filename, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string prompt = "";
         while(!FileIsEnding(h)) prompt += FileReadString(h);
         FileClose(h);
         FileDelete(filename, FILE_COMMON);

         if(prompt != "") {
            InterpretaPrompt(prompt);
         }
      }
   }

   if(TimeCurrent() - lastAI >= 3600) {
      AIOptimizer();
      lastAI = TimeCurrent();
   }
}

// --- IMPLEMENTATION SKELETONS (to be filled in subsequent steps) ---

void InterpretaPrompt(string prompt) {
   string work = prompt;
   StringToLower(work);
   StringReplace(work, " e ", ".");

   ResetStrategy();
   GravaLog("Interpretando: " + prompt);

   // Extract global parameters
   double val = ExtraiValorApos(work, "risco");
   if(val > 0) p_riskPercent = val;

   val = ExtraiValorApos(work, "stop");
   if(val > 0) p_stopPoints = (int)val;

   val = ExtraiValorApos(work, "take");
   if(val > 0) p_takePoints = (int)val;

   val = ExtraiValorApos(work, "máximo");
   if(val > 0) p_maxTrades = (int)val;

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   // Breakeven
   val = ExtraiValorApos(work, "atingir");
   if(val > 0) p_beStart = (int)val;
   val = ExtraiValorApos(work, "entrada");
   if(val > 0) p_bePlus = (int)val;

   // Trailing
   val = ExtraiValorApos(work, "trailing");
   if(val > 0) {
      p_trailingStop = (int)val;
      p_trailingStep = (int)val / 2; // Default heuristic
   }

   // Start Time
   int pos = StringFind(work, "depois das");
   if(pos >= 0) {
      int cursor = pos + 10;
      double h = ExtraiNumero(work, cursor);
      p_startTime = IntegerToString((int)h) + ":00";
   }

   // Frequency
   if(StringFind(work, "1 minuto") >= 0 || StringFind(work, "m1") >= 0) p_frequency = PERIOD_M1;
   if(StringFind(work, "5 minuto") >= 0 || StringFind(work, "m5") >= 0) p_frequency = PERIOD_M5;
   if(StringFind(work, "15 minuto") >= 0 || StringFind(work, "m15") >= 0) p_frequency = PERIOD_M15;
   if(StringFind(work, "hora") >= 0 || StringFind(work, "h1") >= 0) p_frequency = PERIOD_H1;

   // Split rules
   string segments[];
   StringSplit(work, '.', segments);
   Signal currentIntent = NONE;

   for(int i=0; i<ArraySize(segments); i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent != NONE) AddRule(seg, currentIntent);
   }
}

void AddRule(string txt, Signal currentIntent) {
   if(nRules >= 20) return;

   bool added = false;
   Rule r; r.Reset();
   r.intent = currentIntent;
   r.tf = p_frequency;

   if(StringFind(txt, "média") >= 0 || StringFind(txt, "ma") >= 0) {
      r.type = RULE_MA_CROSS;
      int cursor = StringFind(txt, "média");
      if(cursor < 0) cursor = StringFind(txt, "ma");
      r.p1 = (int)ExtraiNumero(txt, cursor);
      if(r.p1 == 0) r.p1 = 20; // Default
      r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) added = true;
   }

   if(StringFind(txt, "rsi") >= 0) {
      r.type = RULE_RSI;
      int cursor = StringFind(txt, "rsi") + 3;
      r.p1 = (int)ExtraiNumero(txt, cursor);
      if(r.p1 < 40) { // Probably period
         r.d1 = ExtraiNumero(txt, cursor); // Probably threshold
      } else { // Probably threshold, period default
         r.d1 = r.p1;
         r.p1 = 14;
      }
      if(r.p1 == 0) r.p1 = 14;
      if(r.d1 == 0) r.d1 = (currentIntent == BUY) ? 55 : 45;

      r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) added = true;
   }

   if(added) {
      r.active = true;
      rules[nRules] = r;
      nRules++;
   }
}

Signal AvaliaTudo() {
   int buyVotes = 0, sellVotes = 0;
   int buyRules = 0, sellRules = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;

      Signal s = AvaliaRegra(rules[i]);

      if(rules[i].intent == BUY) {
         buyRules++;
         if(s == BUY) buyVotes++;
      } else if(rules[i].intent == SELL) {
         sellRules++;
         if(s == SELL) sellVotes++;
      }
   }

   if(buyRules > 0 && buyVotes == buyRules) return BUY;
   if(sellRules > 0 && sellVotes == sellRules) return SELL;

   return NONE;
}

Signal AvaliaRegra(Rule &r) {
   if(r.type == RULE_MA_CROSS) {
      double ma1 = GetBufferValue(r.handle1, 0, 1);
      double ma2 = GetBufferValue(r.handle1, 0, 2);
      double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);

      if(r.intent == BUY && close2 < ma2 && close1 > ma1) return BUY;
      if(r.intent == SELL && close2 > ma2 && close1 < ma1) return SELL;
   }

   if(r.type == RULE_RSI) {
      double rsi1 = GetBufferValue(r.handle1, 0, 1);
      double rsi2 = GetBufferValue(r.handle1, 0, 2);

      if(r.intent == BUY && rsi2 < r.d1 && rsi1 > r.d1) return BUY;
      if(r.intent == SELL && rsi2 > r.d1 && rsi1 < r.d1) return SELL;
   }

   return NONE;
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double stopDist = (p_stopPoints > 0) ? p_stopPoints : 300;

   double riskAmount = capital * (riscoPercent / 100.0);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   double pointsInCash = stopDist * (tickValue / (tickSize / _Point));
   if(pointsInCash == 0) return lotStep;

   double lot = riskAmount / pointsInCash;

   if(p_useMartingale) {
      HistorySelect(TimeCurrent()-86400*7, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= 2;
            break;
         }
      }
   }

   return NormalizeDouble(MathMax(lotStep, lot), 2);
}

void EnviaOrdem(Signal s, double risco) {
   double lot = CalculaLote(risco);
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(s == BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
   }

   for(int i=0; i<3; i++) {
      if(trade.PositionOpen(_Symbol, (s == BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), lot, price, sl, tp, "MT-LiveExecutor")) {
         GravaLog("Ordem enviada: " + EnumToString(s) + " Lote: " + DoubleToString(lot, 2));
         SendNotification("Trade Executado: " + _Symbol + " " + EnumToString(s));
         break;
      }
      int retcode = trade.ResultRetcode();
      if(retcode == TRADE_RETCODE_REQUOTES || retcode == TRADE_RETCODE_OFFQUOTES) {
         price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
         continue;
      } else {
         GravaLog("Erro ao enviar ordem: " + IntegerToString(retcode));
         break;
      }
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         double sl = PositionGetDouble(POSITION_SL);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         int points = 0;
         if(type == POSITION_TYPE_BUY) points = (int)((currentPrice - openPrice) / _Point);
         else points = (int)((openPrice - currentPrice) / _Point);

         // Breakeven
         if(p_beStart > 0 && points >= p_beStart) {
            double newSL = 0;
            if(type == POSITION_TYPE_BUY) newSL = openPrice + p_bePlus * _Point;
            else newSL = openPrice - p_bePlus * _Point;

            if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) ||
               (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && points >= p_trailingStop) {
            double newSL = 0;
            if(type == POSITION_TYPE_BUY) newSL = currentPrice - p_trailingStop * _Point;
            else newSL = currentPrice + p_trailingStop * _Point;

            if((type == POSITION_TYPE_BUY && newSL > sl + p_trailingStep * _Point) ||
               (type == POSITION_TYPE_SELL && (newSL < sl - p_trailingStep * _Point || sl == 0))) {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

bool AguardaNoticias() {
   string vetoFile = "news_veto.txt";
   if(FileIsExist(vetoFile, FILE_COMMON)) {
      int h = FileOpen(vetoFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string val = FileReadString(h);
         FileClose(h);
         if(val == "1") return true;
      }
   }

   string calFile = "calendar.txt";
   if(FileIsExist(calFile, FILE_COMMON)) {
      int h = FileOpen(calFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         while(!FileIsEnding(h)) {
            string line = FileReadString(h);
            if(StringFind(line, "high-impact") >= 0) {
               // Simple logic: if 'high-impact' is found, assume we might be in veto
               // In a real scenario, we would parse the time.
               // For now, return false to not block unless explicitly vetoed by news_veto.txt
               break;
            }
         }
         FileClose(h);
      }
   }

   return false;
}

void GravaLog(string texto) {
   string filename = "MT_LiveExecutor_Log.txt";
   int h = FileOpen(filename, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, "[" + TimeToString(TimeCurrent()) + "] " + texto + "\r\n");
      FileClose(h);
   }
}

void GravaCSV() {
   string filename = "MT_LiveExecutor_State.csv";
   int h = FileOpen(filename, FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Lots", "OpenPrice", "CurrentPrice", "Profit");
      for(int i=0; i<PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
               FileWrite(h, ticket, _Symbol, PositionGetInteger(POSITION_TYPE),
                         PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN),
                         PositionGetDouble(POSITION_PRICE_CURRENT), PositionGetDouble(POSITION_PROFIT));
            }
         }
      }
      FileClose(h);
   }
}

void ResetStrategy() {
   for(int i=0; i<20; i++) rules[i].Reset();
   nRules = 0;
}

int PeriodoTexto(string nome) {
   StringToLower(nome);
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m5") >= 0 && StringFind(nome, "m15") < 0) return PERIOD_M5;
   if(StringFind(nome, "m1") >= 0 && StringFind(nome, "m15") < 0) return PERIOD_M1;
   if(StringFind(nome, "h1") >= 0) return PERIOD_H1;
   if(StringFind(nome, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) < 0) return 0;
   return val[0];
}

bool IsTimeAllowed() {
   string currentTime = TimeToString(TimeCurrent(), TIME_MINUTES);
   if(currentTime >= p_startTime) return true;
   return false;
}

void AIOptimizer() {
   HistorySelect(TimeCurrent()-86400*7, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, count = 0;

   for(int i=total-1; i>=0 && count < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
         count++;
      }
   }

   if(count >= 5) {
      double winRate = (double)wins / count;
      if(winRate < 0.4) {
         p_riskPercent *= 0.9; // Reduce risk
         GravaLog("AI Optimizer: Win rate baixo (" + DoubleToString(winRate*100, 1) + "%). Reduzindo risco para " + DoubleToString(p_riskPercent, 2) + "%");
      }
   }
}

double ExtraiNumero(string txt, int &cursor) {
   string s = "";
   bool found = false;
   for(int i = cursor; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') s += "."; else s += CharToString((uchar)c);
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
   }
   return StringToDouble(s);
}

double ExtraiValorApos(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return 0;
   int cursor = pos + StringLen(keyword);
   return ExtraiNumero(txt, cursor);
}
