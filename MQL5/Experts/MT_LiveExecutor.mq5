//=========================  MT5-LIVE-EXECUTOR  =========================
// Integrando modelos avançados de IA para previsão e otimização de estratégias
//========================================================================

#property copyright "MT-LiveExecutor"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

#define EA_MAGIC 123456

// ---------- 1. BIBLIOTECA COMPLETA DE ENTRADAS ----------
enum ENUM_SIGNAL {SIGNAL_BUY=1, SIGNAL_SELL=-1, SIGNAL_NONE=0};

// 1.1 MÉDIAS & CRUZAMENTOS
ENUM_SIGNAL CruzamentoMA(int fast=9,int slow=21,uint timeframe=PERIOD_CURRENT,int shift=1)
{
   double f=iMA(NULL,timeframe,fast,0,MODE_EMA,PRICE_CLOSE,shift);
   double s=iMA(NULL,timeframe,slow,0,MODE_EMA,PRICE_CLOSE,shift);
   double fp=iMA(NULL,timeframe,fast,0,MODE_EMA,PRICE_CLOSE,shift+1);
   double sp=iMA(NULL,timeframe,slow,0,MODE_EMA,PRICE_CLOSE,shift+1);
   if(fp<sp && f>s) return SIGNAL_BUY;
   if(fp>sp && f<s) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// 1.2 RSI
ENUM_SIGNAL RSIThreshold(int period=14,double over=70,double under=30,uint tf=PERIOD_CURRENT,int shift=0)
{
   double v=iRSI(NULL,tf,period,PRICE_CLOSE,shift);
   if(v>over) return SIGNAL_SELL;
   if(v<under) return SIGNAL_BUY;
   return SIGNAL_NONE;
}

// 1.3 ESTOCÁSTICO
// Helper for Stochastic
void GetStochastic(uint tf, int k, int d, int slowing, int mode, int shift, double &val)
{
    int handle = iStochastic(NULL, tf, k, d, slowing, MODE_SMA, STO_LOWHIGH);
    double buffer[];
    ArraySetAsSeries(buffer, true);
    if(CopyBuffer(handle, mode, shift, 1, buffer) > 0) val = buffer[0];
    IndicatorRelease(handle);
}

ENUM_SIGNAL StochCross(uint tf=PERIOD_CURRENT,int k=5,int d=3,int slowing=3,int shift=0)
{
   double k1, d1;
   GetStochastic(tf, k, d, slowing, 0, shift, k1);
   GetStochastic(tf, k, d, slowing, 1, shift, d1);
   double k2, d2;
   GetStochastic(tf, k, d, slowing, 0, shift+1, k2);
   GetStochastic(tf, k, d, slowing, 1, shift+1, d2);

   if(k2<d2 && k1>d1) return SIGNAL_BUY;
   if(k2>d2 && k1<d1) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// 1.4 BOLLINGER BOUNCE
ENUM_SIGNAL BBounce(int period=20,double desv=2,uint tf=PERIOD_CURRENT,int shift=0)
{
   int h=iBands(NULL,tf,period,0,desv,PRICE_CLOSE);
   double upper[], lower[], close;
   ArraySetAsSeries(upper, true);
   ArraySetAsSeries(lower, true);
   CopyBuffer(h, 1, shift, 1, upper);
   CopyBuffer(h, 2, shift, 1, lower);
   close = iClose(NULL, tf, shift);
   IndicatorRelease(h);

   if(close<lower[0]) return SIGNAL_BUY;
   if(close>upper[0]) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// 1.5 BREAKOUT DIÁRIO
ENUM_SIGNAL DailyBreak(int shift=0)
{
   static datetime today=0;
   static double hi=0,lo=0;
   if(iTime(NULL,PERIOD_D1,0)!=today)
   {  today=iTime(NULL,PERIOD_D1,0);
      hi=iHigh(NULL,PERIOD_D1,1);
      lo=iLow(NULL,PERIOD_D1,1);
   }
   double close=iClose(NULL,PERIOD_M1,shift);
   if(close>hi+SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)) return SIGNAL_BUY;
   if(close<lo-SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE)) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// 1.6 MICROESTRUTURA: DELTA DE AGRESSÃO
ENUM_SIGNAL DeltaAggression(int seconds=60,int deltaTrigger=300)
{
   static int last=0; datetime now=iTime(NULL,PERIOD_M1,0);
   if(now==last) return SIGNAL_NONE; last=(int)now;
   MqlTick arr[]; int n=CopyTicksRange(_Symbol,arr,COPY_TICKS_TRADE,
                                       TimeCurrent()-seconds,TimeCurrent());
   long buy=0,sell=0;
   for(int i=0;i<n;i++) if((arr[i].flags&TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++; else if((arr[i].flags&TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   long delta=buy-sell;
   if(delta> deltaTrigger) return SIGNAL_BUY;
   if(delta<-deltaTrigger) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// 1.7 CICLO DE VOLUME (Williams)
ENUM_SIGNAL VolumeCycle(int len=12,uint tf=PERIOD_CURRENT,int shift=0)
{
   long vol[]; ArraySetAsSeries(vol,true);
   CopyVolume(_Symbol,tf,shift,len,vol);
   int maxIdx = ArrayMaximum(vol);
   int minIdx = ArrayMinimum(vol);
   long high=vol[maxIdx];
   long low =vol[minIdx];
   long now =vol[0];
   if(now==high) return SIGNAL_SELL;
   if(now==low)  return SIGNAL_BUY;
   return SIGNAL_NONE;
}

// 1.8 MÉDIA MÓVEL ADAPTATIVA (Kaufman)
ENUM_SIGNAL AMA(int len=10,int fast=2,int slow=30,uint tf=PERIOD_CURRENT,int shift=0)
{
   int h = iAMA(NULL,tf,len,fast,slow,0,PRICE_CLOSE);
   double buffer[]; ArraySetAsSeries(buffer, true);
   CopyBuffer(h, 0, shift, 2, buffer);
   double ama=buffer[0];
   double p  =buffer[1];
   IndicatorRelease(h);
   if(p<ama) return SIGNAL_BUY;
   if(p>ama) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// 1.9 PADRÃO DE 2 BARRAS (inside / outside)
ENUM_SIGNAL Bar2Pattern(uint tf=PERIOD_CURRENT,int shift=0)
{
   double h0=iHigh(NULL,tf,shift);
   double l0=iLow(NULL,tf,shift);
   double h1=iHigh(NULL,tf,shift+1);
   double l1=iLow(NULL,tf,shift+1);
   if(h0<h1 && l0>l1) return (iClose(NULL,tf,shift)>iOpen(NULL,tf,shift))? SIGNAL_BUY : SIGNAL_SELL;
   if(h0>h1 && l0<l1) return (iClose(NULL,tf,shift)>iOpen(NULL,tf,shift))? SIGNAL_SELL: SIGNAL_BUY;
   return SIGNAL_NONE;
}

// 1.10 FORÇA RELATIVA ENTRE ATIVOS
ENUM_SIGNAL RSRelative(string bench="US30",int len=14,uint tf=PERIOD_CURRENT,int shift=0)
{
   int h1 = iRSI(_Symbol ,tf,len,PRICE_CLOSE);
   int h2 = iRSI(bench   ,tf,len,PRICE_CLOSE);
   double b1[], b2[];
   ArraySetAsSeries(b1, true); ArraySetAsSeries(b2, true);
   CopyBuffer(h1, 0, shift, 1, b1);
   CopyBuffer(h2, 0, shift, 1, b2);
   double r1=b1[0];
   double r2=b2[0];
   IndicatorRelease(h1);
   IndicatorRelease(h2);
   if(r1>r2+5) return SIGNAL_BUY;
   if(r1<r2-5) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// 1.11 PREVISÃO IA
ENUM_SIGNAL AIPredict()
{
   if(FileIsExist("signal_ai.txt", FILE_COMMON)) {
      int h = FileOpen("signal_ai.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string s = FileReadString(h);
         FileClose(h);
         if(s == "BUY") return SIGNAL_BUY;
         if(s == "SELL") return SIGNAL_SELL;
      }
   }
   return SIGNAL_NONE;
}

// ---------- 2. MOTOR DE INTERPRETAÇÃO DE PROMPT ----------
struct Rule {
   bool          active;
   int           type; // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Volume, 8: AMA, 9: Pattern, 10: RS
   int           handle;
   int           handle2;
   uint          tf;
   int           p1, p2, p3;
   double        d1, d2;
   string        s1;
   ENUM_SIGNAL   intent; // SIGNAL_BUY or SIGNAL_SELL
   string        op; // ">", "<", "cross_above", "cross_below"
};

Rule g_rulesBuy[20];
Rule g_rulesSell[20];
int g_nRulesBuy = 0;
int g_nRulesSell = 0;

// Global Parameters
double g_risk = 1.0;
int    g_slPoints = 0;
int    g_tpPoints = 0;
int    g_maxTrades = 3;
int    g_startHour = 10;
int    g_newsVetoMinutes = 20;
int    g_breakevenTrigger = 0;
int    g_breakevenOffset = 0;
int    g_trailingStop = 0;
uint   g_frequency = PERIOD_M15;

void ResetStrategy()
{
   for(int i=0; i<20; i++) {
      if(g_rulesBuy[i].handle != INVALID_HANDLE) { IndicatorRelease(g_rulesBuy[i].handle); g_rulesBuy[i].handle = INVALID_HANDLE; }
      if(g_rulesBuy[i].handle2 != INVALID_HANDLE) { IndicatorRelease(g_rulesBuy[i].handle2); g_rulesBuy[i].handle2 = INVALID_HANDLE; }
      if(g_rulesSell[i].handle != INVALID_HANDLE) { IndicatorRelease(g_rulesSell[i].handle); g_rulesSell[i].handle = INVALID_HANDLE; }
      if(g_rulesSell[i].handle2 != INVALID_HANDLE) { IndicatorRelease(g_rulesSell[i].handle2); g_rulesSell[i].handle2 = INVALID_HANDLE; }
   }
   ZeroMemory(g_rulesBuy);
   ZeroMemory(g_rulesSell);
   g_nRulesBuy = 0;
   g_nRulesSell = 0;
}

double ExtraiNumero(string txt, int startPos)
{
   if(startPos < 0) return 0.0;
   string res = "";
   bool found = false;
   for(int i=startPos; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+') {
         res += StringSubstr(txt, i, 1);
         found = true;
      } else if(found) break;
   }
   return StringToDouble(res);
}

int PeriodoTexto(string nome)
{
   if(StringFind(nome, "m1") >= 0 || StringFind(nome, "1 min") >= 0) return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0 || StringFind(nome, "5 min") >= 0) return PERIOD_M5;
   if(StringFind(nome, "m15") >= 0 || StringFind(nome, "15 min") >= 0) return PERIOD_M15;
   if(StringFind(nome, "h1") >= 0 || StringFind(nome, "1 hora") >= 0) return PERIOD_H1;
   if(StringFind(nome, "d1") >= 0 || StringFind(nome, "diário") >= 0) return PERIOD_D1;
   return (int)g_frequency;
}

void AddRuleSpecific(string seg, ENUM_SIGNAL intent)
{
   Rule r;
   ZeroMemory(r);
   r.intent = intent;
   r.tf = (uint)PeriodoTexto(seg);
   r.handle = INVALID_HANDLE;
   r.handle2 = INVALID_HANDLE;

   bool added = false;

   // Moving Average
   if(StringFind(seg, "média") >= 0) {
      r.type = 1;
      int keyPos = StringFind(seg, "média");
      r.p1 = (int)ExtraiNumero(seg, keyPos);
      if(r.p1 == 0) r.p1 = 20;
      r.handle = iMA(NULL, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);

      if(StringFind(seg, "cruzar acima") >= 0) r.op = "cross_above";
      else if(StringFind(seg, "cruzar abaixo") >= 0) r.op = "cross_below";
      else if(StringFind(seg, "acima") >= 0) r.op = ">";
      else if(StringFind(seg, "abaixo") >= 0) r.op = "<";

      // Check for MA vs MA
      int p2pos = StringFind(seg, "/", keyPos);
      if(p2pos < 0) p2pos = StringFind(seg, " e ", keyPos);
      if(p2pos >= 0) {
         r.p2 = (int)ExtraiNumero(seg, p2pos);
         if(r.p2 > 0) r.handle2 = iMA(NULL, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_EMA, PRICE_CLOSE);
      }
      added = true;
   }

   // RSI
   if(StringFind(seg, "rsi") >= 0) {
      r.type = 2;
      int keyPos = StringFind(seg, "rsi");
      r.p1 = (int)ExtraiNumero(seg, keyPos);
      if(r.p1 == 0) r.p1 = 14;
      r.handle = iRSI(NULL, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);

      if(StringFind(seg, "subir acima") >= 0 || StringFind(seg, "acima") >= 0) { r.op = ">"; r.d1 = ExtraiNumero(seg, StringFind(seg, "acima", keyPos)); }
      else if(StringFind(seg, "cair abaixo") >= 0 || StringFind(seg, "abaixo") >= 0) { r.op = "<"; r.d1 = ExtraiNumero(seg, StringFind(seg, "abaixo", keyPos)); }
      added = true;
   }

   // Pattern
   if(StringFind(seg, "padrão") >= 0 || StringFind(seg, "inside") >= 0 || StringFind(seg, "outside") >= 0) {
       r.type = 9;
       added = true;
   }

   if(added) {
      if(intent == SIGNAL_BUY && g_nRulesBuy < 20) g_rulesBuy[g_nRulesBuy++] = r;
      if(intent == SIGNAL_SELL && g_nRulesSell < 20) g_rulesSell[g_nRulesSell++] = r;
   }
}

void InterpretaPrompt(string prompt)
{
   ResetStrategy();
   string work = prompt;
   StringToLower(work);
   StringReplace(work, " e o ", ".");
   StringReplace(work, " e a ", ".");
   StringReplace(work, " e ", ".");

   // Global parameters parsing
   if(StringFind(work, "risco de ") >= 0) g_risk = ExtraiNumero(work, StringFind(work, "risco de "));
   if(StringFind(work, "stop de ") >= 0) g_slPoints = (int)ExtraiNumero(work, StringFind(work, "stop de "));
   if(StringFind(work, "take de ") >= 0) g_tpPoints = (int)ExtraiNumero(work, StringFind(work, "take de "));
   if(StringFind(work, "máximo ") >= 0 && StringFind(work, " trades") >= 0) g_maxTrades = (int)ExtraiNumero(work, StringFind(work, "máximo "));
   if(StringFind(work, "depois das ") >= 0) g_startHour = (int)ExtraiNumero(work, StringFind(work, "depois das "));
   if(StringFind(work, "a cada ") >= 0) g_frequency = PeriodoTexto(work);

   // Breakeven
   int bePos = StringFind(work, "ao atingir ");
   if(bePos >= 0) {
      g_breakevenTrigger = (int)ExtraiNumero(work, bePos);
      int entPos = StringFind(work, "entrada", bePos);
      if(entPos >= 0) g_breakevenOffset = (int)ExtraiNumero(work, entPos);
   }

   // Trailing
   if(StringFind(work, "trailing") >= 0 || StringFind(work, "rastreio") >= 0) {
       int tPos = StringFind(work, "trailing");
       if(tPos < 0) tPos = StringFind(work, "rastreio");
       g_trailingStop = (int)ExtraiNumero(work, tPos);
   }

   // Split by intent
   string segments[];
   StringSplit(work, '.', segments);

   ENUM_SIGNAL currentIntent = SIGNAL_NONE;
   for(int i=0; i<ArraySize(segments); i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = SIGNAL_BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SIGNAL_SELL;

      if(currentIntent != SIGNAL_NONE) AddRuleSpecific(seg, currentIntent);
   }
}

// ---------- 3. DECISÃO FINAL ----------
bool AvaliaRegra(Rule &r)
{
   if(r.type == 0) return false;

   double val[], val2[];
   ArraySetAsSeries(val, true);
   ArraySetAsSeries(val2, true);

   if(r.type == 1) { // MA
      if(CopyBuffer(r.handle, 0, 0, 3, val) <= 0) return false;
      double price = iClose(NULL, (ENUM_TIMEFRAMES)r.tf, 0);
      double pricePrev = iClose(NULL, (ENUM_TIMEFRAMES)r.tf, 1);

      if(r.handle2 == INVALID_HANDLE) {
         if(r.op == "cross_above") return (pricePrev <= val[1] && price > val[0]);
         if(r.op == "cross_below") return (pricePrev >= val[1] && price < val[0]);
         if(r.op == ">") return (price > val[0]);
         if(r.op == "<") return (price < val[0]);
      } else {
         if(CopyBuffer(r.handle2, 0, 0, 3, val2) <= 0) return false;
         if(r.op == "cross_above") return (val[1] <= val2[1] && val[0] > val2[0]);
         if(r.op == "cross_below") return (val[1] >= val2[1] && val[0] < val2[0]);
         if(r.op == ">") return (val[0] > val2[0]);
         if(r.op == "<") return (val[0] < val2[0]);
      }
   }

   if(r.type == 2) { // RSI
      if(CopyBuffer(r.handle, 0, 0, 2, val) <= 0) return false;
      if(r.op == ">") return (val[0] > r.d1);
      if(r.op == "<") return (val[0] < r.d1);
   }

   if(r.type == 9) { // Bar Pattern
       ENUM_SIGNAL s = Bar2Pattern((uint)r.tf, 0);
       return (s == r.intent);
   }

   return false;
}

ENUM_SIGNAL AvaliaTudo()
{
   // Evaluate BUY
   bool buyMet = (g_nRulesBuy > 0);
   for(int i=0; i<g_nRulesBuy; i++) {
      if(!AvaliaRegra(g_rulesBuy[i])) { buyMet = false; break; }
   }

   // Evaluate SELL
   bool sellMet = (g_nRulesSell > 0);
   for(int i=0; i<g_nRulesSell; i++) {
      if(!AvaliaRegra(g_rulesSell[i])) { sellMet = false; break; }
   }

   if(buyMet) return SIGNAL_BUY;
   if(sellMet) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// ---------- 4. EXECUTOR DE ORDEM ----------
CTrade g_trade;

void EnviaOrdem(string tipo, double preco, double sl, double tp, double lote)
{
    if(tipo == "BUY") {
        if(g_trade.Buy(lote, _Symbol, preco, sl, tp)) {
            GravaLog("Compra executada a " + DoubleToString(preco, _Digits));
            GravaEstadoCSV(g_trade.ResultOrder(), preco, sl, tp, "Prompt Order");
        }
    } else if(tipo == "SELL") {
        if(g_trade.Sell(lote, _Symbol, preco, sl, tp)) {
            GravaLog("Venda executada a " + DoubleToString(preco, _Digits));
            GravaEstadoCSV(g_trade.ResultOrder(), preco, sl, tp, "Prompt Order");
        }
    }
}

void EnviaOrdem(ENUM_SIGNAL s, double lote, double slPoints, double tpPoints)
{
   if(s == SIGNAL_NONE) return;

   double price = (s == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(s == SIGNAL_BUY) {
      if(slPoints > 0) sl = price - slPoints * _Point;
      if(tpPoints > 0) tp = price + tpPoints * _Point;
      for(int i=0; i<3; i++) {
         if(g_trade.Buy(lote, _Symbol, price, sl, tp)) {
            GravaLog("Compra executada a " + DoubleToString(price, _Digits));
            GravaEstadoCSV(g_trade.ResultOrder(), price, sl, tp, "Signal " + (string)s);
            break;
         }
         price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      }
   } else {
      if(slPoints > 0) sl = price + slPoints * _Point;
      if(tpPoints > 0) tp = price - tpPoints * _Point;
      for(int i=0; i<3; i++) {
         if(g_trade.Sell(lote, _Symbol, price, sl, tp)) {
            GravaLog("Venda executada a " + DoubleToString(price, _Digits));
            GravaEstadoCSV(g_trade.ResultOrder(), price, sl, tp, "Signal " + (string)s);
            break;
         }
         price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      }
   }
}

double CalculaLote(double riscoPercent, double slPoints)
{
   if(slPoints <= 0) slPoints = 300; // Default if not specified
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double lot = riscoAbs / (slPoints * _Point * (tickVal / tickSize));
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}

// ---------- 5. GESTÃO DE POSIÇÕES ----------
void GerenciaPosicoes()
{
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double curPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         double sl = PositionGetDouble(POSITION_SL);
         double tp = PositionGetDouble(POSITION_TP);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

         // Breakeven
         if(g_breakevenTrigger > 0) {
            double profitPoints = (type == POSITION_TYPE_BUY) ? (curPrice - openPrice)/_Point : (openPrice - curPrice)/_Point;
            if(profitPoints >= g_breakevenTrigger) {
               double newSl = (type == POSITION_TYPE_BUY) ? openPrice + g_breakevenOffset*_Point : openPrice - g_breakevenOffset*_Point;
               if((type == POSITION_TYPE_BUY && (sl < openPrice || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > openPrice || sl == 0))) {
                  if(g_trade.PositionModify(ticket, newSl, tp)) {
                     GravaLog("Breakeven acionado para ticket " + (string)ticket);
                     GravaEstadoCSV(ticket, curPrice, newSl, tp, "Breakeven");
                  }
               }
            }
         }

         // Trailing Stop
         if(g_trailingStop > 0) {
            double profitPoints = (type == POSITION_TYPE_BUY) ? (curPrice - openPrice)/_Point : (openPrice - curPrice)/_Point;
            if(profitPoints >= g_trailingStop) {
               double newSl = (type == POSITION_TYPE_BUY) ? curPrice - g_trailingStop*_Point : curPrice + g_trailingStop*_Point;
               if((type == POSITION_TYPE_BUY && newSl > sl) || (type == POSITION_TYPE_SELL && (newSl < sl || sl == 0))) {
                  if(g_trade.PositionModify(ticket, newSl, tp)) {
                     GravaLog("Trailing Stop ajustado para ticket " + (string)ticket);
                     GravaEstadoCSV(ticket, curPrice, newSl, tp, "Trailing");
                  }
               }
            }
         }
      }
   }
}

// ---------- 6. FILTRO DE NOTÍCIAS ----------
bool AguardaNoticias()
{
   if(FileIsExist("news_veto.txt", FILE_COMMON)) {
      int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string content = FileReadString(h);
         FileClose(h);
         if(StringFind(content, "VETO") >= 0) return true;
      }
   }

   if(FileIsExist("calendar.txt", FILE_COMMON)) {
       int h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
       if(h != INVALID_HANDLE) {
           FileClose(h);
           // Placeholder for complex logic
       }
   }

   return false;
}

// ---------- 7. LOGS E ESTATÍSTICAS ----------
void GravaLog(string texto)
{
   Print("MT-LiveExecutor: ", texto);
}

void GravaEstadoCSV(ulong ticket, double preco, double sl, double tp, string motivo)
{
   int h = FileOpen("states.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, ticket, TimeToString(TimeCurrent()), preco, sl, tp, motivo);
      FileClose(h);
   }
}

double g_peakEquity = 0;
double g_maxDrawdown = 0;
int g_winCount = 0;
int g_lossCount = 0;
double g_totalProfit = 0;

void CalculaStats()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity) g_peakEquity = equity;
   double dd = (g_peakEquity > 0) ? (g_peakEquity - equity) / g_peakEquity * 100.0 : 0;
   if(dd > g_maxDrawdown) g_maxDrawdown = dd;

   GravaLog("Stats - Equity: " + (string)equity + " MaxDD: " + DoubleToString(g_maxDrawdown, 2) + "%");
}

// ---------- 8. EVENT HANDLERS ----------
int OnInit()
{
   g_trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(3600);
   g_peakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ResetStrategy();
   CalculaStats();
   EventKillTimer();
}

void OnTick()
{
   if(FileIsExist("prompt.txt", FILE_COMMON)) {
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string prompt = FileReadString(h);
         FileClose(h);
         FileDelete("prompt.txt", FILE_COMMON);
         InterpretaPrompt(prompt);
         GravaLog("Nova estratégia carregada: " + prompt);
      }
   }

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < g_startHour) return;

   if(AguardaNoticias()) return;

   GerenciaPosicoes();

   static datetime lastBar = 0;
   datetime currentBar = iTime(NULL, (ENUM_TIMEFRAMES)g_frequency, 0);
   if(currentBar != lastBar) {
      int openTrades = 0;
      for(int i=0; i<PositionsTotal(); i++) {
         if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) openTrades++;
      }

      if(openTrades < g_maxTrades) {
         ENUM_SIGNAL s = AvaliaTudo();
         if(s == SIGNAL_NONE) s = AIPredict();

         if(s != SIGNAL_NONE) {
            double lot = CalculaLote(g_risk, (double)g_slPoints);
            EnviaOrdem(s, lot, (double)g_slPoints, (double)g_tpPoints);
         }
      }
      lastBar = currentBar;
   }
}

void OnTimer()
{
   CalculaStats();
}

void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest& request,
                        const MqlTradeResult& result)
{
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD) {
        if(HistoryDealSelect(trans.deal)) {
            long magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);
            if(magic == EA_MAGIC) {
                double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
                if(profit > 0) g_winCount++;
                else if(profit < 0) g_lossCount++;
                g_totalProfit += profit;
                CalculaStats();
            }
        }
    }
}
