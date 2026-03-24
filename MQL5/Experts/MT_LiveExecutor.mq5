//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MT-LiveExecutor |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "8.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- Enums
enum Signal { BUY=1, SELL=-1, NONE=0 };

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI_THRESHOLD,
   RULE_STOCH_CROSS,
   RULE_BB_BOUNCE,
   RULE_DAILY_BREAK,
   RULE_DELTA_AGG,
   RULE_VOL_CYCLE,
   RULE_AMA,
   RULE_BAR_PATTERN
};

//--- Structs
struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   int       p1_handle, p2_handle, p3_handle;
   bool      is_cross;
   Signal    last_signal;
};

//--- Global Variables
Rule rules[30];
int nRules = 0;

// Operational Parameters
double p_riskPercent = 1.0;
int    p_stopPoints = 300;
int    p_takePoints = 500;
int    p_trailingStopPoints = 0;
int    p_breakEvenPoints = 0;
int    p_breakEvenLock = 50;
int    p_maxSimultaneousTrades = 3;
int    p_newsVetoMinutes = 20;
int    p_startHour = 0;
bool   p_martingale = false;
bool   p_hedge = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// State Variables
datetime lastBarTime = 0;
int dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;

// Trade Objects
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

// Cache
double currentBid, currentAsk, currentTickSize, currentTickValue;

// Forward declarations
void CheckForPromptUpdate();
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
void EnviaOrdem(Signal s);
void GerenciaPosicoes();
bool AguardaNoticias();
void AIOptimizer();
void GravaCSV(ulong ticket, string motivo);
double CalculaLote(double risco);
void UpdateSafety();
void UpdatePriceCache();
ENUM_TIMEFRAMES MinutesToTimeframe(int mins);
void AddRule(RuleType type, ENUM_TIMEFRAMES tf, int p1, int p2, int p3, double d1, double d2, string s1);
Signal CheckMA(Rule &rule, int shift);
Signal CheckRSI(Rule &rule, int shift);
Signal CheckStoch(Rule &rule, int shift);
Signal CheckBB(Rule &rule, int shift);
Signal CheckDaily(Rule &rule, int shift);
Signal CheckDelta(Rule &rule, int seconds);
Signal CheckAMA(Rule &rule, int shift);
Signal CheckBarPattern(Rule &rule, int shift);
Signal CheckVolCycle(Rule &rule, int shift);

//+------------------------------------------------------------------+
//| Expert lifecycle                                                 |
//+------------------------------------------------------------------+
int OnInit() {
   EventSetTimer(1);
   if(!symInfo.Name(_Symbol)) return INIT_FAILED;
   UpdatePriceCache();
   CheckForPromptUpdate();
   Print("MT-LiveExecutor v8.0 pronto.");
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
}

void OnTick() {
   UpdatePriceCache();
   datetime barTime = iTime(_Symbol, p_frequency, 0);
   if(barTime == lastBarTime) return;
   if(TimeHour(TimeCurrent()) < p_startHour) return;
   if(AguardaNoticias()) return;
   Signal s = AvaliaTudo();
   if(s != NONE) { EnviaOrdem(s); lastBarTime = barTime; }
}

void OnTimer() {
   CheckForPromptUpdate();
   GerenciaPosicoes();
   AIOptimizer();
   UpdateSafety();
}

//+------------------------------------------------------------------+
//| NLP Parser                                                       |
//+------------------------------------------------------------------+
void InterpretaPrompt(string prompt) {
   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
      rules[i].active = false;
   }
   nRules = 0; lastBarTime = 0;

   string work = prompt; StringToLower(work);
   StringReplace(work, " e ", "|"); StringReplace(work, " + ", "|");
   StringReplace(work, ".", "|"); StringReplace(work, ",", "|");
   string segments[]; int count = StringSplit(work, '|', segments);

   for(int i=0; i<count; i++) {
      string seg = segments[i]; StringTrimLeft(seg); StringTrimRight(seg);
      if(StringLen(seg) == 0) continue;

      if(StringFind(seg, "depois das ") >= 0) p_startHour = (int)StringToInteger(StringSubstr(seg, StringFind(seg, "depois das ") + 11));
      if(StringFind(seg, "stop de ") >= 0) p_stopPoints = (int)StringToInteger(StringSubstr(seg, StringFind(seg, "stop de ") + 8));
      if(StringFind(seg, "take de ") >= 0) p_takePoints = (int)StringToInteger(StringSubstr(seg, StringFind(seg, "take de ") + 8));
      if(StringFind(seg, "risco de ") >= 0) p_riskPercent = StringToDouble(StringSubstr(seg, StringFind(seg, "risco de ") + 9));
      if(StringFind(seg, "notícias") >= 0) p_newsVetoMinutes = 20;
      if(StringFind(seg, "máximo ") >= 0) p_maxSimultaneousTrades = (int)StringToInteger(StringSubstr(seg, StringFind(seg, "máximo ") + 7));
      if(StringFind(seg, "trailing stop") >= 0) p_trailingStopPoints = (int)StringToInteger(StringSubstr(seg, StringFind(seg, "trailing stop") + 14));
      if(StringFind(seg, "atingir +") >= 0) {
         p_breakEvenPoints = (int)StringToInteger(StringSubstr(seg, StringFind(seg, "atingir +") + 9));
         if(StringFind(seg, "entrada +") >= 0) p_breakEvenLock = (int)StringToInteger(StringSubstr(seg, StringFind(seg, "entrada +") + 9));
      }
      if(StringFind(seg, "cada ") >= 0 && StringFind(seg, "minutos") >= 0) p_frequency = MinutesToTimeframe((int)StringToInteger(StringSubstr(seg, StringFind(seg, "cada ") + 5)));
      if(StringFind(seg, "martingale") >= 0) p_martingale = true;
      if(StringFind(seg, "hedge") >= 0) p_hedge = true;

      if(StringFind(seg, "média de ") >= 0) AddRule(RULE_MA_CROSS, p_frequency, (int)StringToInteger(StringSubstr(seg, StringFind(seg, "média de ") + 9)), 21, 0, 0, 0, "");
      if(StringFind(seg, "rsi") >= 0) {
         int per = (int)StringToInteger(StringSubstr(seg, StringFind(seg, "rsi (") + 5)); if(per==0) per=14;
         double over = 70, under = 30;
         if(StringFind(seg, "acima de ") >= 0) over = StringToDouble(StringSubstr(seg, StringFind(seg, "acima de ") + 9));
         if(StringFind(seg, "abaixo de ") >= 0) under = StringToDouble(StringSubstr(seg, StringFind(seg, "abaixo de ") + 10));
         AddRule(RULE_RSI_THRESHOLD, p_frequency, per, 0, 0, over, under, "");
         if(StringFind(seg, "subir") >= 0 || StringFind(seg, "cair") >= 0) rules[nRules-1].is_cross = true;
      }
      if(StringFind(seg, "estocástico") >= 0) AddRule(RULE_STOCH_CROSS, p_frequency, 5, 3, 3, 0, 0, "");
      if(StringFind(seg, "bollinger") >= 0) AddRule(RULE_BB_BOUNCE, p_frequency, 20, 0, 0, 2.0, 0, "");
   }
   Print("Prompts aplicados.");
}

//+------------------------------------------------------------------+
//| Indicators & Confluence                                          |
//+------------------------------------------------------------------+
void AddRule(RuleType type, ENUM_TIMEFRAMES tf, int p1, int p2, int p3, double d1, double d2, string s1) {
   if(nRules >= 30) return;
   rules[nRules].active = true; rules[nRules].type = type; rules[nRules].tf = tf;
   rules[nRules].p1 = p1; rules[nRules].p2 = p2; rules[nRules].p3 = p3;
   rules[nRules].d1 = d1; rules[nRules].d2 = d2; rules[nRules].is_cross = false;
   if(type == RULE_MA_CROSS) { rules[nRules].p1_handle = iMA(_Symbol, tf, p1, 0, MODE_EMA, PRICE_CLOSE); rules[nRules].p2_handle = iMA(_Symbol, tf, p2 == 0 ? 21 : p2, 0, MODE_EMA, PRICE_CLOSE); }
   if(type == RULE_RSI_THRESHOLD) rules[nRules].p1_handle = iRSI(_Symbol, tf, p1, PRICE_CLOSE);
   if(type == RULE_STOCH_CROSS) rules[nRules].p1_handle = iStochastic(_Symbol, tf, p1, p2, p3, MODE_SMA, STO_LOWHIGH);
   if(type == RULE_BB_BOUNCE) rules[nRules].p1_handle = iBands(_Symbol, tf, p1, 0, d1, PRICE_CLOSE);
   if(type == RULE_AMA) rules[nRules].p1_handle = iAMA(_Symbol, tf, p1, p2, p3, 0, PRICE_CLOSE);
   nRules++;
}

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;
   Signal res = NONE;
   for(int i=0; i<nRules; i++) {
      Signal s = NONE;
      switch(rules[i].type) {
         case RULE_MA_CROSS: s = CheckMA(rules[i], 1); break;
         case RULE_RSI_THRESHOLD: s = CheckRSI(rules[i], 1); break;
         case RULE_STOCH_CROSS: s = CheckStoch(rules[i], 1); break;
         case RULE_BB_BOUNCE: s = CheckBB(rules[i], 1); break;
         case RULE_AMA: s = CheckAMA(rules[i], 1); break;
         case RULE_DAILY_BREAK: s = CheckDaily(rules[i], 1); break;
         case RULE_BAR_PATTERN: s = CheckBarPattern(rules[i], 1); break;
         case RULE_VOL_CYCLE: s = CheckVolCycle(rules[i], 1); break;
      }
      if(s == NONE) return NONE;
      if(res == NONE) res = s; else if(res != s) return NONE;
   }
   return res;
}

Signal CheckMA(Rule &r, int s) {
   double f[], l[]; ArraySetAsSeries(f,1); ArraySetAsSeries(l,1);
   if(CopyBuffer(r.p1_handle,0,s,2,f)<=0 || CopyBuffer(r.p2_handle,0,s,2,l)<=0) return NONE;
   if(f[1]<l[1] && f[0]>l[0]) return BUY; if(f[1]>l[1] && f[0]<l[0]) return SELL; return NONE;
}
Signal CheckRSI(Rule &r, int s) {
   double v[]; ArraySetAsSeries(v,1); if(CopyBuffer(r.p1_handle,0,s,2,v)<=0) return NONE;
   if(r.is_cross) { if(v[1]<r.d2 && v[0]>=r.d2) return BUY; if(v[1]>r.d1 && v[0]<=r.d1) return SELL; }
   else { if(v[0]<r.d2) return BUY; if(v[0]>r.d1) return SELL; } return NONE;
}
Signal CheckStoch(Rule &r, int s) {
   double k[], d[]; ArraySetAsSeries(k,1); ArraySetAsSeries(d,1);
   if(CopyBuffer(r.p1_handle,0,s,2,k)<=0 || CopyBuffer(r.p1_handle,1,s,2,d)<=0) return NONE;
   if(k[1]<d[1] && k[0]>d[0]) return BUY; if(k[1]>d[1] && k[0]<d[0]) return SELL; return NONE;
}
Signal CheckBB(Rule &r, int s) {
   double u[], l[], c[]; ArraySetAsSeries(u,1); ArraySetAsSeries(l,1); ArraySetAsSeries(c,1);
   if(CopyBuffer(r.p1_handle,1,s,1,u)<=0 || CopyBuffer(r.p1_handle,2,s,1,l)<=0) return NONE; CopyClose(_Symbol,r.tf,s,1,c);
   if(c[0]<l[0]) return BUY; if(c[0]>u[0]) return SELL; return NONE;
}
Signal CheckDaily(Rule &r, int s) {
   double h=iHigh(_Symbol,PERIOD_D1,1), l=iLow(_Symbol,PERIOD_D1,1), c=iClose(_Symbol,PERIOD_M1,s);
   if(c>h+currentTickSize) return BUY; if(c<l-currentTickSize) return SELL; return NONE;
}
Signal CheckAMA(Rule &r, int s) {
   double v[]; ArraySetAsSeries(v,1); if(CopyBuffer(r.p1_handle,0,s,2,v)<=0) return NONE;
   if(v[1]<v[0]) return BUY; if(v[1]>v[0]) return SELL; return NONE;
}
Signal CheckBarPattern(Rule &r, int s) {
   double h0=iHigh(_Symbol,r.tf,s), l0=iLow(_Symbol,r.tf,s), h1=iHigh(_Symbol,r.tf,s+1), l1=iLow(_Symbol,r.tf,s+1);
   if(h0<h1 && l0>l1) return (iClose(_Symbol,r.tf,s)>iOpen(_Symbol,r.tf,s))?BUY:SELL; return NONE;
}
Signal CheckVolCycle(Rule &r, int s) {
   long v[]; ArraySetAsSeries(v,1); CopyVolume(_Symbol,r.tf,s,r.p1,v);
   if(v[0]==v[ArrayMinimum(v)]) return BUY; if(v[0]==v[ArrayMaximum(v)]) return SELL; return NONE;
}
Signal CheckDelta(Rule &r, int sec) {
   MqlTick a[]; int n=CopyTicksRange(_Symbol,a,COPY_TICKS_TRADE,TimeCurrent()-sec,TimeCurrent());
   long b=0, s=0; for(int i=0; i<n; i++) if(a[i].flags & TICK_FLAG_BUY) b++; else s++;
   if(b-s>r.p1) return BUY; if(b-s<-r.p1) return SELL; return NONE;
}

//+------------------------------------------------------------------+
//| Trade Engine                                                     |
//+------------------------------------------------------------------+
double CalculaLote(double risk) {
   double cap = AccountInfoDouble(ACCOUNT_EQUITY); double rAbs = cap * risk / 100.0;
   if(p_martingale) { HistorySelect(TimeCurrent()-86400,TimeCurrent()); int t=HistoryDealsTotal(); if(t>0) { ulong tk=HistoryDealGetTicket(t-1); if(HistoryDealGetDouble(tk,DEAL_PROFIT)<0) rAbs*=2; } }
   double v = rAbs / (p_stopPoints * (SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE)/(SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)/_Point)));
   return NormalizeDouble(v, 2);
}

void EnviaOrdem(Signal s) {
   if(PositionsTotal() >= p_maxSimultaneousTrades) return;
   if(!p_hedge) { for(int i=PositionsTotal()-1; i>=0; i--) if(posInfo.SelectByIndex(i) && posInfo.Symbol()==_Symbol && ((s==BUY && posInfo.PositionType()==POSITION_TYPE_SELL) || (s==SELL && posInfo.PositionType()==POSITION_TYPE_BUY))) trade.PositionClose(posInfo.Ticket()); }
   double floor = (SymbolInfoInteger(_Symbol,SYMBOL_TRADE_STOPS_LEVEL)+dynamicSafetyPoints+1)*_Point;
   double lote = CalculaLote(p_riskPercent);
   double sl = (s==BUY)?currentBid-MathMax(p_stopPoints*_Point,floor):currentAsk+MathMax(p_stopPoints*_Point,floor);
   double tp = (s==BUY)?currentAsk+MathMax(p_takePoints*_Point,floor):currentBid-MathMax(p_takePoints*_Point,floor);
   if(s==BUY) { if(trade.Buy(lote,_Symbol,currentAsk,sl,tp)) GravaCSV(trade.ResultOrder(),"BUY"); else dynamicSafetyPoints+=10; }
   else { if(trade.Sell(lote,_Symbol,currentBid,sl,tp)) GravaCSV(trade.ResultOrder(),"SELL"); else dynamicSafetyPoints+=10; }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol()==_Symbol) {
         double open=posInfo.PriceOpen(), cur=(posInfo.PositionType()==POSITION_TYPE_BUY)?currentBid:currentAsk;
         double pts=(posInfo.PositionType()==POSITION_TYPE_BUY)?(cur-open)/_Point:(open-cur)/_Point;
         if(p_trailingStopPoints>0 && pts>=p_trailingStopPoints) {
            double nSL=(posInfo.PositionType()==POSITION_TYPE_BUY)?currentBid-p_trailingStopPoints*_Point:currentAsk+p_trailingStopPoints*_Point;
            if((posInfo.PositionType()==POSITION_TYPE_BUY && nSL>posInfo.StopLoss()) || (posInfo.PositionType()==POSITION_TYPE_SELL && (nSL<posInfo.StopLoss() || posInfo.StopLoss()==0))) trade.PositionModify(posInfo.Ticket(),nSL,posInfo.TakeProfit());
         }
         if(p_breakEvenPoints>0 && pts>=p_breakEvenPoints) {
            double nSL=(posInfo.PositionType()==POSITION_TYPE_BUY)?open+p_breakEvenLock*_Point:open-p_breakEvenLock*_Point;
            if((posInfo.PositionType()==POSITION_TYPE_BUY && (posInfo.StopLoss()<nSL || posInfo.StopLoss()==0)) || (posInfo.PositionType()==POSITION_TYPE_SELL && (posInfo.StopLoss()>nSL || posInfo.StopLoss()==0))) trade.PositionModify(posInfo.Ticket(),nSL,posInfo.TakeProfit());
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
void UpdatePriceCache() { MqlTick t; if(SymbolInfoTick(_Symbol,t)) { currentBid=t.bid; currentAsk=t.ask; } currentTickSize=SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE); }
void UpdateSafety() { if(TimeCurrent()-lastSafetyDecay>=60) { if(dynamicSafetyPoints>0) dynamicSafetyPoints--; lastSafetyDecay=TimeCurrent(); } }
bool AguardaNoticias() { int h=FileOpen("news_veto.txt",FILE_READ|FILE_ANSI|FILE_COMMON); if(h!=INVALID_HANDLE) { string c=FileReadString(h); FileClose(h); if(c=="1") return true; } return false; }
void AIOptimizer() { HistorySelect(TimeCurrent()-86400*30,TimeCurrent()); double w=0, l=0; for(int i=0; i<HistoryDealsTotal(); i++) { ulong tk=HistoryDealGetTicket(i); if(HistoryDealGetDouble(tk,DEAL_PROFIT)>0) w++; else if(HistoryDealGetDouble(tk,DEAL_PROFIT)<0) l++; }
   double wr=(w+l>0)?(w/(w+l))*100:0; if(wr<40 && p_riskPercent>0.5) p_riskPercent*=0.9; if(wr>60 && p_riskPercent<2.0) p_riskPercent*=1.1; }
void GravaCSV(ulong t, string m) { int h=FileOpen("MT_LiveExecutor_State.csv",FILE_WRITE|FILE_READ|FILE_CSV|FILE_COMMON|FILE_ANSI); if(h!=INVALID_HANDLE) { FileSeek(h,0,SEEK_END); FileWrite(h,t,_Symbol,currentBid,TimeCurrent(),m); FileClose(h); } }
void CheckForPromptUpdate() { if(GlobalVariableCheck("MT_Executor_Prompt_Update")) { int h=FileOpen("MT_LiveExecutor_Prompt.txt",FILE_READ|FILE_ANSI|FILE_COMMON); if(h!=INVALID_HANDLE) { InterpretaPrompt(FileReadString(h)); FileClose(h); GlobalVariableDel("MT_Executor_Prompt_Update"); } } }
ENUM_TIMEFRAMES MinutesToTimeframe(int m) { if(m<=1) return PERIOD_M1; if(m<=5) return PERIOD_M5; if(m<=15) return PERIOD_M15; if(m<=30) return PERIOD_M30; return PERIOD_H1; }
