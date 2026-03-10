//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, Jules AI Agent |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, Jules AI Agent"
#property link      "https://www.mql5.com"
#property version   "9.10"
#property strict

//=========================  MT5-KNOWLEDGE-CORE  =========================
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- 1. BIBLIOTECA COMPLETA DE ENTRADAS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};
enum RuleType { RT_MA, RT_RSI, RT_STOCH, RT_BANDS, RT_NONE };

struct Rule {
   bool      active;
   RuleType  type;
   int       tf;
   int       p1,p2,p3;
   double    d1,d2;
   string    s1;
   int       h1, h2; // Indicator handles
};

Rule rules[30];
int nRules=0;

// Pre-cached indicator handles to prevent leaks
int h_ma_fast = INVALID_HANDLE;
int h_ma_slow = INVALID_HANDLE;
int h_rsi = INVALID_HANDLE;
int h_stoch = INVALID_HANDLE;
int h_bands = INVALID_HANDLE;
int h_ama = INVALID_HANDLE;
int h_atr = INVALID_HANDLE; // Used by AIOptimizer

// Helper to release handles
void ReleaseHandles() {
   for(int i=0; i<30; i++) {
      if(rules[i].h1 != INVALID_HANDLE) { IndicatorRelease(rules[i].h1); rules[i].h1 = INVALID_HANDLE; }
      if(rules[i].h2 != INVALID_HANDLE) { IndicatorRelease(rules[i].h2); rules[i].h2 = INVALID_HANDLE; }
   }
   if(h_atr != INVALID_HANDLE) { IndicatorRelease(h_atr); h_atr = INVALID_HANDLE; }
}

// 1.1 MÉDIAS & CRUZAMENTOS
Signal CruzamentoMA(int h_fast, int h_slow, int shift=1)
{
   if(h_slow == INVALID_HANDLE) { // Price vs MA mode
      double ma = GetValue(h_fast, 0, shift);
      double close = iClose(NULL, PERIOD_CURRENT, shift);
      double p_close = iClose(NULL, PERIOD_CURRENT, shift+1);
      double p_ma = GetValue(h_fast, 0, shift+1);
      if(p_close < p_ma && close > ma) return BUY;
      if(p_close > p_ma && close < ma) return SELL;
      return NONE;
   }
   double f=GetValue(h_fast, 0, shift);
   double s=GetValue(h_slow, 0, shift);
   double fp=GetValue(h_fast, 0, shift+1);
   double sp=GetValue(h_slow, 0, shift+1);
   if(fp<sp && f>s) return BUY;
   if(fp>sp && f<s) return SELL;
   return NONE;
}

// 1.2 RSI
Signal RSIThreshold(int h_rsi_local, double over=70, double under=30, int shift=0)
{
   double v = GetValue(h_rsi_local, 0, shift);
   if(over > under) {
      if(v>over) return BUY;
      if(v<under) return SELL;
   } else {
      if(v<over) return BUY;
      if(v>under) return SELL;
   }
   return NONE;
}

// 1.3 ESTOCÁSTICO
Signal StochCross(uint tf=PERIOD_CURRENT,int k=5,int d=3,int slowing=3,int shift=0)
{
   double k1 = iStochastic(NULL,tf,k,d,slowing,MODE_SMA,STO_LOWHIGH,0,shift);
   double d1 = iStochastic(NULL,tf,k,d,slowing,MODE_SMA,STO_LOWHIGH,1,shift);
   double k2 = iStochastic(NULL,tf,k,d,slowing,MODE_SMA,STO_LOWHIGH,0,shift+1);
   double d2 = iStochastic(NULL,tf,k,d,slowing,MODE_SMA,STO_LOWHIGH,1,shift+1);
   if(k2<d2 && k1>d1) return BUY;
   if(k2>d2 && k1<d1) return SELL;
   return NONE;
}

// 1.4 BOLLINGER BOUNCE
Signal BBounce(int period=20,double desv=2,uint tf=PERIOD_CURRENT,int shift=0)
{
   double upper = iBands(NULL,tf,period,desv,0,PRICE_CLOSE,1,shift);
   double lower = iBands(NULL,tf,period,desv,0,PRICE_CLOSE,2,shift);
   double close = iClose(NULL,tf,shift);
   if(close<lower) return BUY;
   if(close>upper) return SELL;
   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal DailyBreak(int shift=0)
{
   static datetime today=0;
   static double hi=0,lo=0;
   if(iTime(NULL,PERIOD_D1,0)!=today)
   {  today=iTime(NULL,PERIOD_D1,0);
      hi=iHigh(NULL,PERIOD_D1,1);
      lo=iLow(NULL,PERIOD_D1,1);
   }
   double close=iClose(NULL,PERIOD_M1,shift);
   if(close>hi) return BUY;
   if(close<lo) return SELL;
   return NONE;
}

// 1.6 MICROESTRUTURA: DELTA DE AGRESSÃO
Signal DeltaAggression(int seconds=60,int deltaTrigger=300)
{
   MqlTick arr[]; int n=CopyTicksRange(_Symbol,arr,COPY_TICKS_TRADE,
                                       TimeCurrent()-seconds,TimeCurrent());
   long buy=0,sell=0;
   for(int i=0;i<n;i++) if(arr[i].flags&TICK_FLAG_BUY) buy++; else if(arr[i].flags&TICK_FLAG_SELL) sell++;
   long delta=buy-sell;
   if(delta> deltaTrigger) return BUY;
   if(delta<-deltaTrigger) return SELL;
   return NONE;
}

// 1.7 CICLO DE VOLUME (Williams)
Signal VolumeCycle(int len=12,uint tf=PERIOD_CURRENT,int shift=0)
{
   long vol[]; ArraySetAsSeries(vol,true);
   CopyVolume(_Symbol,tf,shift,len,vol);
   int high_idx = ArrayMaximum(vol);
   int low_idx = ArrayMinimum(vol);
   if(high_idx == 0) return SELL;
   if(low_idx == 0)  return BUY;
   return NONE;
}

// 1.8 MÉDIA MÓVEL ADAPTATIVA (Kaufman)
Signal AMA(int len=10,int fast=2,int slow=30,uint tf=PERIOD_CURRENT,int shift=0)
{
   double ama=iAMA(NULL,tf,len,fast,slow,0,PRICE_CLOSE,shift);
   double p   =iAMA(NULL,tf,len,fast,slow,0,PRICE_CLOSE,shift+1);
   if(p<ama) return BUY;
   if(p>ama) return SELL;
   return NONE;
}

// Wrapper functions for MQL4 compatibility and readability
double iClose(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[1];
   if(CopyClose(symbol,tf,shift,1,res)>0) return res[0];
   return 0;
}
double iHigh(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[1];
   if(CopyHigh(symbol,tf,shift,1,res)>0) return res[0];
   return 0;
}
double iLow(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[1];
   if(CopyLow(symbol,tf,shift,1,res)>0) return res[0];
   return 0;
}
double iOpen(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[1];
   if(CopyOpen(symbol,tf,shift,1,res)>0) return res[0];
   return 0;
}
datetime iTime(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   datetime res[1];
   if(CopyTime(symbol,tf,shift,1,res)>0) return res[0];
   return 0;
}
double GetValue(int handle, int buffer, int shift) {
   double res[1];
   if(handle == INVALID_HANDLE) return 0;
   if(CopyBuffer(handle, buffer, shift, 1, res) > 0) return res[0];
   return 0;
}
double iAMA(string symbol, ENUM_TIMEFRAMES tf, int period, int fast_pow, int slow_pow, int shift_ama, ENUM_APPLIED_PRICE price, int shift) {
   int handle = iAMA(symbol,tf,period,fast_pow,slow_pow,shift_ama,price);
   double res[1];
   CopyBuffer(handle,0,shift,1,res);
   return res[0];
}
double iBands(string symbol, ENUM_TIMEFRAMES tf, int period, double deviation, int shift_bands, ENUM_APPLIED_PRICE price, int buffer, int shift) {
   int handle = iBands(symbol,tf,period,deviation,shift_bands,price);
   double res[1];
   CopyBuffer(handle,buffer,shift,1,res);
   return res[0];
}
double iStochastic(string symbol, ENUM_TIMEFRAMES tf, int Kperiod, int Dperiod, int slowing, ENUM_MA_METHOD method, ENUM_STOCH_PRICE price, int buffer, int shift) {
   int handle = iStochastic(symbol,tf,Kperiod,Dperiod,slowing,method,price);
   double res[1];
   CopyBuffer(handle,buffer,shift,1,res);
   return res[0];
}

// ---------- 2. MOTOR DE INTERPRETAÇÃO DE PROMPT ----------
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

// Strategy Global Parameters
int p_frequency = 0; // minutes
int p_startHour = 0;
int p_stopPoints = 0;
int p_takePoints = 0;
double p_riskPercent = 1.0;
int p_beTrigger = 0;
int p_beOffset = 0;
int p_maxTrades = 100;
bool p_newsVeto = false;

void InterpretaPrompt(string prompt) {
   for(int i=0; i<30; i++) {
      rules[i].active = false;
      rules[i].h1 = INVALID_HANDLE;
      rules[i].h2 = INVALID_HANDLE;
   }
   nRules = 0;
   ReleaseHandles();

   // Reset parameters
   p_frequency = 0; p_startHour = 0; p_stopPoints = 30; p_takePoints = 50;
   p_riskPercent = 1.0; p_beTrigger = 0; p_beOffset = 0; p_newsVeto = false;

   string segments[];
   ushort sep = StringGetCharacter(" +",0);
   if(StringFind(prompt," e ") > 0) prompt = StringReplace(prompt, " e ", "+");
   StringSplit(prompt, sep, segments);

   // Parse Frequency
   if(StringFind(prompt, "cada ") >= 0) {
      p_frequency = ExtraiNumero(prompt, "cada ");
   }

   // Parse Start Hour
   if(StringFind(prompt, "depois das ") >= 0) {
      p_startHour = ExtraiNumero(prompt, "depois das ");
   }

   // Parse Risk
   if(StringFind(prompt, "risco de ") >= 0) {
      p_riskPercent = ExtraiNumero(prompt, "risco de ");
   }

   // Parse Stop/Take
   if(StringFind(prompt, "stop de ") >= 0) p_stopPoints = ExtraiNumero(prompt, "stop de ");
   if(StringFind(prompt, "take de ") >= 0) p_takePoints = ExtraiNumero(prompt, "take de ");

   // Parse Break-even
   if(StringFind(prompt, "atingir +") >= 0) {
      p_beTrigger = ExtraiNumero(prompt, "atingir +");
      if(StringFind(prompt, "entrada +") >= 0) p_beOffset = ExtraiNumero(prompt, "entrada +");
   }

   // News Veto
   if(StringFind(prompt, "notícias") >= 0) p_newsVeto = true;

   // Max Trades
   if(StringFind(prompt, "Máximo ") >= 0) p_maxTrades = ExtraiNumero(prompt, "Máximo ");

   // Indicator Rules
   ENUM_TIMEFRAMES tf = MinutesToTimeframe(p_frequency);
   if(StringFind(prompt, "média de ") >= 0) {
      int p = ExtraiNumero(prompt, "média de ");
      rules[nRules].active = true;
      rules[nRules].type = RT_MA;
      rules[nRules].p1 = p;
      rules[nRules].tf = tf;
      rules[nRules].h1 = iMA(NULL, tf, p, 0, MODE_EMA, PRICE_CLOSE);
      nRules++;
   }

   if(StringFind(prompt, "RSI") >= 0 || StringFind(prompt, "rsi") >= 0) {
      int p = ExtraiNumero(prompt, "RSI (");
      if(p == 0) p = ExtraiNumero(prompt, "rsi (");
      if(p == 0) p = 14;
      rules[nRules].active = true;
      rules[nRules].type = RT_RSI;
      rules[nRules].p1 = p;

      // Attempt to extract dynamic RSI levels
      int up = ExtraiNumero(prompt, "acima de ");
      int dn = ExtraiNumero(prompt, "abaixo de ");
      rules[nRules].d1 = (up > 0) ? up : 55;
      rules[nRules].d2 = (dn > 0) ? dn : 45;

      rules[nRules].tf = tf;
      rules[nRules].h1 = iRSI(NULL, tf, p, PRICE_CLOSE);
      nRules++;
   }

   PrintFormat("Prompt interpretado: %d regras, Risco %.2f%%, SL %d, TP %d", nRules, p_riskPercent, p_stopPoints, p_takePoints);
}

int ExtraiNumero(string txt, string chave) {
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   string sub = StringSubstr(txt, pos + StringLen(chave));
   return (int)StringToInteger(sub);
}

ENUM_TIMEFRAMES MinutesToTimeframe(int min) {
   if(min <= 1) return PERIOD_M1;
   if(min <= 5) return PERIOD_M5;
   if(min <= 15) return PERIOD_M15;
   if(min <= 30) return PERIOD_M30;
   if(min <= 60) return PERIOD_H1;
   if(min <= 240) return PERIOD_H4;
   return PERIOD_CURRENT;
}

int PeriodoTexto(string nome) {
   nome = StringToLower(nome);
   if(nome=="m1" || nome=="1") return PERIOD_M1;
   if(nome=="m5" || nome=="5") return PERIOD_M5;
   if(nome=="m15" || nome=="15") return PERIOD_M15;
   if(nome=="h1" || nome=="60") return PERIOD_H1;
   if(nome=="d1" || nome=="1440") return PERIOD_D1;
   return PERIOD_CURRENT;
}

// ---------- 3. DECISÃO FINAL E EXECUÇÃO ----------
MqlTick lastTick;
int dynamicSafetyPoints = 0;

void UpdatePriceCache() {
   if(!SymbolInfoTick(_Symbol, lastTick)) {
      Print("Erro ao atualizar cache de preço");
   }
}

double NS(double price) {
   return NormalizeDouble(price, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
}

double NV(double volume) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double min_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_vol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double res = NormalizeDouble(MathFloor(volume/step)*step, 2);
   return MathMin(max_vol, MathMax(min_vol, res));
}

bool IsPriceSafe(double price, Signal side) {
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   double buffer = stopsLevel + (dynamicSafetyPoints + 2) * _Point;
   if(side == BUY) return (price > lastTick.ask + buffer);
   if(side == SELL) return (price < lastTick.bid - buffer);
   return true;
}

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;
   int consensus = 0;
   // Use shift 1 for bar-aligned signal validation (checking the candle that just closed)
   int shift = 1;
   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      Signal s = NONE;
      if(rules[i].type == RT_MA) s = CruzamentoMA(rules[i].h1, rules[i].h2, shift);
      else if(rules[i].type == RT_RSI) s = RSIThreshold(rules[i].h1, rules[i].d1, rules[i].d2, shift);

      if(s == NONE) return NONE;
      consensus += (int)s;
   }
   if(consensus == nRules) return BUY;
   if(consensus == -nRules) return SELL;
   return NONE;
}

CTrade trade;
void executaSignal(Signal s) {
   if(s == NONE) return;
   if(p_newsVeto && AguardaNoticias()) return;
   if(PositionsTotal() >= p_maxTrades) return;

   double lote = CalculaLote(p_riskPercent);
   double sl=0, tp=0;
   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double safety = (stopsLevel + dynamicSafetyPoints + 2) * _Point;

   if(s == BUY) {
      sl = NS(lastTick.bid - MathMax(p_stopPoints * _Point, safety));
      tp = NS(lastTick.ask + MathMax(p_takePoints * _Point, safety));
      if(trade.Buy(lote, _Symbol, lastTick.ask, sl, tp)) {
         GravaLog(StringFormat("COMPRA Executada: Lote %.2f, SL %.5f, TP %.5f", lote, sl, tp));
      } else {
         uint ret = trade.ResultRetcode();
         if(ret == 10015 || ret == 10016 || ret == 10026) {
            if(dynamicSafetyPoints < 100) dynamicSafetyPoints += 5;
         }
      }
   } else {
      sl = NS(lastTick.ask + MathMax(p_stopPoints * _Point, safety));
      tp = NS(lastTick.bid - MathMax(p_takePoints * _Point, safety));
      if(trade.Sell(lote, _Symbol, lastTick.bid, sl, tp)) {
         GravaLog(StringFormat("VENDA Executada: Lote %.2f, SL %.5f, TP %.5f", lote, sl, tp));
      } else {
         uint ret = trade.ResultRetcode();
         if(ret == 10015 || ret == 10016 || ret == 10026) {
            if(dynamicSafetyPoints < 100) dynamicSafetyPoints += 5;
         }
      }
   }
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoMoney = capital * (riscoPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double stop_pts = MathMax(p_stopPoints, 1);
   double lot = riscoMoney / ((stop_pts * _Point) * (tickValue / tickSize));
   return NV(lot);
}

// ---------- 4. GESTÃO E AUXILIARES ----------
CPositionInfo posInfo;

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(posInfo.SelectByTicket(ticket)) {
         if(posInfo.Symbol() != _Symbol) continue;

         double price = posInfo.PriceCurrent();
         double open = posInfo.PriceOpen();
         double sl = posInfo.StopLoss();
         double tp = posInfo.TakeProfit();

         // Breakeven logic
         if(p_beTrigger > 0) {
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               if(price >= open + p_beTrigger * _Point && sl < open) {
                  trade.PositionModify(ticket, NS(open + p_beOffset * _Point), tp);
                  GravaLog(StringFormat("Breakeven acionado para COMPRA #%d", ticket));
               }
            } else {
               if(price <= open - p_beTrigger * _Point && (sl > open || sl == 0)) {
                  trade.PositionModify(ticket, NS(open - p_beOffset * _Point), tp);
                  GravaLog(StringFormat("Breakeven acionado para VENDA #%d", ticket));
               }
            }
         }
      }
   }
}

bool AguardaNoticias() {
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - 20 * 60;
   datetime to = TimeCurrent() + 20 * 60;
   if(CalendarValueHistory(values, from, to)) {
      for(int i=0; i<ArraySize(values); i++) {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event)) {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
         }
      }
   }
   return false;
}

void SynchronizeClusterSL(Signal side, double newSL) {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(posInfo.SelectByTicket(ticket)) {
         if(posInfo.Symbol() == _Symbol) {
            if((side == BUY && posInfo.PositionType() == POSITION_TYPE_BUY) ||
               (side == SELL && posInfo.PositionType() == POSITION_TYPE_SELL)) {
               trade.PositionModify(posInfo.Ticket(), NS(newSL), posInfo.TakeProfit());
            }
         }
      }
   }
}

void AIOptimizer() {
   // Heuristic risk optimization based on ATR
   if(h_atr == INVALID_HANDLE) h_atr = iATR(_Symbol, PERIOD_H1, 14);
   double res[1];
   if(CopyBuffer(h_atr, 0, 0, 1, res) > 0) {
      double atr = res[0];
      // Suggest adjustment if ATR is high (volatile)
      if(atr > 100 * _Point) {
         PrintFormat("AIOptimizer: Volatilidade alta detectada (ATR: %.5f). Sugerindo redução de risco.", atr);
      }
   }
}

void GravaLog(string texto) {
   string filename = "MT_LiveExecutor_Log.csv";
   int handle = FileOpen(filename, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, TimeToString(TimeCurrent()), texto);
      FileClose(handle);
   }
   Print(texto);
}

// ---------- 5. HANDLERS DE CICLO DE VIDA ----------
string lastPrompt = "";
datetime lastBarTime = 0;

int OnInit() {
   EventSetTimer(60);
   InterpretaPrompt(InpPrompt);
   lastPrompt = InpPrompt;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ReleaseHandles();
}

void OnTick() {
   // Dynamic prompt update
   if(InpPrompt != lastPrompt) {
      InterpretaPrompt(InpPrompt);
      lastPrompt = InpPrompt;
      lastBarTime = 0;
   }

   UpdatePriceCache();
   GerenciaPosicoes();

   // Frequency check (bar alignment)
   datetime currentBar = iTime(_Symbol, MinutesToTimeframe(p_frequency), 0);
   if(currentBar != lastBarTime) {
      // Start hour check
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour >= p_startHour) {
         Signal s = AvaliaTudo();
         if(s != NONE) {
            executaSignal(s);
            lastBarTime = currentBar;
         }
      }
   }
}

void OnTimer() {
   AIOptimizer();
   if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& request, const MqlTradeResult& result) {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
      // Synchronize SL for cluster if needed
      // Logic for SynchronizeClusterSL call could go here
   }
}
