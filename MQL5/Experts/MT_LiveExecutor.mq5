//=========================  MT5-LIVE-EXECUTOR  =========================
// MetaTrader Live Executor - NLP-based Trading System
//========================================================================

#property copyright "Copyright 2024"
#property link      "https://www.metatrader5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- DEFINES & GLOBALS ----------
#define EA_MAGIC 123456
#define MAX_RULES 50

enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   bool     active;
   int      type;    // 1: MA Cross, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Volume, 8: AMA, 9: Bar2, 10: RS
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      intent;  // 1: BUY, -1: SELL
   int      handle1, handle2;

   void Reset() {
      active = false; type = 0; tf = PERIOD_CURRENT; p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0; s1 = ""; intent = 0; handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
   }
};

Rule rules[MAX_RULES];
int nRules = 0;

// Global Parameters
double p_risk = 1.0;
double p_sl = 0;
double p_tp = 0;
int    p_maxTrades = 3;
double p_breakeven = 0;
double p_beStep = 0;
double p_trailingStop = 0;
double p_trailingStep = 0;
int    p_newsVeto = 20; // minutes
int    p_startHour = -1;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool   p_martingale = false;
bool   p_exitOpposite = true;

CTrade trade;
CPositionInfo pos;

// ---------- MQL5 EVENT HANDLERS ----------

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(60);

   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();

   // Initial attempt to read strategy if prompt.txt exists
   // (Implementation will follow in next steps)

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   // Release handles
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
   }
}

void OnTick() {
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);

   if(currentBar != lastBar) {
      lastBar = currentBar;

      // Time filter
      if(p_startHour >= 0) {
         MqlDateTime dt;
         TimeToStruct(TimeCurrent(), dt);
         if(dt.hour < p_startHour) return;
      }

      // News filter
      if(AguardaNoticias()) return;

      Signal s = AvaliaTudo();
      EnviaOrdem(s);
   }

   GerenciaPosicoes();
}

void OnTimer() {
   // Check for new prompt
   int handle = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle);
      FileClose(handle);
      FileDelete("prompt.txt", FILE_COMMON);

      ResetStrategy();
      InterpretaPrompt(prompt);
      GravaLog("Estratégia atualizada via prompt.txt");
   }

   CalculaStats();
}

// ---------- NLP ENGINE ----------

void InterpretaPrompt(string prompt) {
   string lowerPrompt = prompt;
   StringToLower(lowerPrompt);

   // Normalization
   StringReplace(lowerPrompt, "|", ".");
   StringReplace(lowerPrompt, "\n", ".");

   string segments[];
   StringSplit(lowerPrompt, '.', segments);

   int currentIntent = 0; // 0: Global/Neutral, 1: BUY, -1: SELL

   for(int i=0; i<ArraySize(segments); i++) {
      string seg = segments[i];
      StringTrimLeft(seg);
      StringTrimRight(seg);
      if(seg == "") continue;

      // Global parameters
      if(StringFind(seg, "risco") >= 0) p_risk = ExtraiNumero(seg, StringFind(seg, "risco") + 5);
      if(StringFind(seg, "stop") >= 0 && StringFind(seg, "move") < 0) p_sl = ExtraiNumero(seg, StringFind(seg, "stop") + 4);
      if(StringFind(seg, "take") >= 0) p_tp = ExtraiNumero(seg, StringFind(seg, "take") + 4);
      if(StringFind(seg, "máximo") >= 0 && StringFind(seg, "trades") >= 0) p_maxTrades = (int)ExtraiNumero(seg, StringFind(seg, "máximo") + 6);

      if(StringFind(seg, "breakeven") >= 0 || StringFind(seg, "move stop para entrada") >= 0) {
         int posAtingir = StringFind(seg, "atingir");
         if(posAtingir >= 0) p_breakeven = ExtraiNumero(seg, posAtingir + 7);
         int posPlus = StringFind(seg, "+", posAtingir + 10);
         if(posPlus >= 0) p_beStep = ExtraiNumero(seg, posPlus + 1);
      }

      if(StringFind(seg, "trailing") >= 0 || StringFind(seg, "rastreio") >= 0) {
         p_trailingStop = ExtraiNumero(seg, StringFind(seg, "stop") + 4);
         p_trailingStep = ExtraiNumero(seg, StringFind(seg, "passo") + 5);
      }

      if(StringFind(seg, "notícias") >= 0) p_newsVeto = (int)ExtraiNumero(seg, StringFind(seg, "notícias") - 3);

      if(StringFind(seg, "depois das") >= 0 || StringFind(seg, "após as") >= 0) {
         p_startHour = (int)ExtraiNumero(seg, StringFind(seg, "as") + 2);
      }

      if(StringFind(seg, "cada") >= 0 && (StringFind(seg, "minutos") >= 0 || StringFind(seg, "min") >= 0)) {
         p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(seg);
      }

      if(StringFind(seg, "martingale") >= 0) p_martingale = true;

      // Intent detection
      if(StringFind(seg, "compra") >= 0) {
         currentIntent = 1;
         AddRule(seg, currentIntent);
      }
      else if(StringFind(seg, "venda") >= 0) {
         currentIntent = -1;
         AddRule(seg, currentIntent);
      }
      else if(currentIntent != 0) {
         // This segment might be a continuation (e.g., "and RSI above 55")
         AddRule(seg, currentIntent);
      }
   }
}

void AddRule(string txt, int intent) {
   static int lastMA = 20;
   static int lastRSI = 14;

   int tf = PeriodoTexto(txt);

   // 1. MA Cross / Price Cross
   if(StringFind(txt, "média") >= 0 || StringFind(txt, "cruzar") >= 0) {
      if(nRules < MAX_RULES) {
         rules[nRules].Reset();
         rules[nRules].intent = intent;
         rules[nRules].tf = tf;
         rules[nRules].type = 1;
         rules[nRules].p1 = (int)ExtraiNumero(txt, StringFind(txt, "média") + 5);
         if(rules[nRules].p1 == 0) rules[nRules].p1 = lastMA; else lastMA = rules[nRules].p1;
         rules[nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
         rules[nRules].active = true;
         nRules++;
      }
   }

   // 2. RSI
   if(StringFind(txt, "rsi") >= 0) {
      if(nRules < MAX_RULES) {
         int posRsi = StringFind(txt, "rsi");
         rules[nRules].Reset();
         rules[nRules].intent = intent;
         rules[nRules].tf = tf;
         rules[nRules].type = 2;
         rules[nRules].p1 = (int)ExtraiNumero(txt, posRsi + 3);
         if(rules[nRules].p1 == 0) rules[nRules].p1 = lastRSI; else lastRSI = rules[nRules].p1;

         int posThreshold = -1;
         int posAcima = StringFind(txt, "acima", posRsi);
         int posAbaixo = StringFind(txt, "abaixo", posRsi);
         int posSobe = StringFind(txt, "subir", posRsi);
         int posCai = StringFind(txt, "cair", posRsi);

         if(posAcima >= 0) posThreshold = posAcima + 5;
         else if(posSobe >= 0) posThreshold = posSobe + 5;
         else if(posAbaixo >= 0) posThreshold = posAbaixo + 6;
         else if(posCai >= 0) posThreshold = posCai + 4;

         if(posThreshold >= 0) rules[nRules].d1 = ExtraiNumero(txt, posThreshold);

         rules[nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)tf, rules[nRules].p1, PRICE_CLOSE);
         rules[nRules].active = true;
         nRules++;
      }
   }

   // 3. Stoch
   if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
      if(nRules < MAX_RULES) {
         rules[nRules].Reset();
         rules[nRules].intent = intent;
         rules[nRules].tf = tf;
         rules[nRules].type = 3;
         rules[nRules].p1 = 5; rules[nRules].p2 = 3; rules[nRules].p3 = 3;
         rules[nRules].handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)tf, rules[nRules].p1, rules[nRules].p2, rules[nRules].p3, MODE_SMA, STO_LOWHIGH);
         rules[nRules].active = true;
         nRules++;
      }
   }

   // 4. Bollinger Bands
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bandas") >= 0) {
      if(nRules < MAX_RULES) {
         rules[nRules].Reset();
         rules[nRules].intent = intent;
         rules[nRules].tf = tf;
         rules[nRules].type = 4;
         rules[nRules].p1 = 20; rules[nRules].d1 = 2.0;
         rules[nRules].handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)tf, rules[nRules].p1, 0, rules[nRules].d1, PRICE_CLOSE);
         rules[nRules].active = true;
         nRules++;
      }
   }

   // 5. Daily Breakout
   if(StringFind(txt, "breakout") >= 0 || StringFind(txt, "rompimento") >= 0) {
      if(nRules < MAX_RULES) {
         rules[nRules].Reset();
         rules[nRules].intent = intent;
         rules[nRules].tf = tf;
         rules[nRules].type = 5;
         rules[nRules].active = true;
         nRules++;
      }
   }

   // 9. 2-Bar Pattern
   if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "candle") >= 0) {
      if(nRules < MAX_RULES) {
         rules[nRules].Reset();
         rules[nRules].intent = intent;
         rules[nRules].tf = tf;
         rules[nRules].type = 9;
         rules[nRules].active = true;
         nRules++;
      }
   }
}

double ExtraiNumero(string txt, int start) {
   if(start < 0 || start >= StringLen(txt)) return 0;
   string res = "";
   bool found = false;
   for(int i=start; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') res += ".";
         else res += StringSubstr(txt, i, 1);
         found = true;
      } else if(found) break;
   }
   return StringToDouble(res);
}

int PeriodoTexto(string nome) {
   if(StringFind(nome, "m15") >= 0 || StringFind(nome, "15 min") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m5") >= 0  || StringFind(nome, "5 min") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "m1") >= 0  || StringFind(nome, "1 min") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "h1") >= 0  || StringFind(nome, "1 hora") >= 0) return PERIOD_H1;
   if(StringFind(nome, "d1") >= 0  || StringFind(nome, "diário") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

// ---------- SIGNAL ENGINE ----------

Signal AvaliaTudo() {
   int buyVotos = 0, sellVotos = 0;
   int buyRules = 0, sellRules = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;

      Signal s = AvaliaRegra(rules[i]);
      if(rules[i].intent == 1) {
         buyRules++;
         if(s == BUY) buyVotos++;
      } else if(rules[i].intent == -1) {
         sellRules++;
         if(s == SELL) sellVotos++;
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) return BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SELL;

   return NONE;
}

Signal AvaliaRegra(Rule &r) {
   double val1 = GetBufferValue(r.handle1, 0, 0);
   double val2 = GetBufferValue(r.handle1, 0, 1);

   switch(r.type) {
      case 1: // MA Cross / Price
         {
            double close0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            if(r.intent == 1 && close1 < val2 && close0 > val1) return BUY;
            if(r.intent == -1 && close1 > val2 && close0 < val1) return SELL;
         }
         break;

      case 2: // RSI
         if(r.intent == 1 && val1 > r.d1) return BUY;
         if(r.intent == -1 && val1 < r.d1) return SELL;
         break;

      case 3: // Stoch
         {
            double d0 = GetBufferValue(r.handle1, 1, 0);
            double d1 = GetBufferValue(r.handle1, 1, 1);
            double k0 = val1;
            double k1 = val2;
            if(r.intent == 1 && k1 < d1 && k0 > d0) return BUY;
            if(r.intent == -1 && k1 > d1 && k0 < d0) return SELL;
         }
         break;

      case 4: // BB
         {
            double upper0 = GetBufferValue(r.handle1, 1, 0);
            double lower0 = GetBufferValue(r.handle1, 2, 0);
            double close0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            if(r.intent == 1 && close0 < lower0) return BUY;
            if(r.intent == -1 && close0 > upper0) return SELL;
         }
         break;

      case 5: // Daily Breakout
         {
            double hi1 = iHigh(_Symbol, PERIOD_D1, 1);
            double lo1 = iLow(_Symbol, PERIOD_D1, 1);
            double close0 = iClose(_Symbol, PERIOD_CURRENT, 0);
            if(r.intent == 1 && close0 > hi1) return BUY;
            if(r.intent == -1 && close0 < lo1) return SELL;
         }
         break;

      case 9: // 2-Bar Pattern
         {
            double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
            double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
            bool inside = (h0 < h1 && l0 > l1);
            bool outside = (h0 > h1 && l0 < l1);
            if(inside || outside) {
               bool bull = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
               if(r.intent == 1 && bull) return BUY;
               if(r.intent == -1 && !bull) return SELL;
            }
         }
         break;
   }

   return NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
   if(handle == INVALID_HANDLE) return 0;
   double arr[];
   ArraySetAsSeries(arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, arr) > 0) return arr[0];
   return 0;
}

// ---------- TRADE MANAGEMENT ----------

void EnviaOrdem(Signal s) {
   if(s == NONE) return;

   if(PositionsTotal() >= p_maxTrades) return;

   double lote = CalculaLote(p_risk);
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(s == BUY) {
      if(p_sl > 0) sl = price - p_sl * _Point;
      if(p_tp > 0) tp = price + p_tp * _Point;
      trade.Buy(lote, _Symbol, price, sl, tp);
   } else {
      if(p_sl > 0) sl = price + p_sl * _Point;
      if(p_tp > 0) tp = price - p_tp * _Point;
      trade.Sell(lote, _Symbol, price, sl, tp);
   }

   if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
      GravaLog("Ordem enviada: " + EnumToString(s) + " Lote: " + DoubleToString(lote, 2));
   } else {
      GravaLog("Erro ao enviar ordem: " + IntegerToString(trade.ResultRetcode()));
   }
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);

   if(p_martingale) {
      // Find last closed trade
      if(HistorySelect(TimeCurrent()-86400*30, TimeCurrent())) {
         for(int i=HistoryDealsTotal()-1; i>=0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
               double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
               if(profit < 0) riscoPercent *= 2;
               break;
            }
         }
      }
   }

   double riscoAbs = capital * riscoPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slPoints = (p_sl > 0) ? p_sl : 300;

   double lot = riscoAbs / (slPoints * _Point * (tickVal / tickSize));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC || PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double sl = PositionGetDouble(POSITION_SL);
         long type = PositionGetInteger(POSITION_TYPE);
         double currentPrice = (type == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

         double diff = (type == POSITION_TYPE_BUY) ? currentPrice - openPrice : openPrice - currentPrice;
         double profitPoints = diff / _Point;

         // Breakeven
         if(p_breakeven > 0 && profitPoints >= p_breakeven) {
            double newSL = (type == POSITION_TYPE_BUY) ? openPrice + p_beStep * _Point : openPrice - p_beStep * _Point;
            if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
               trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (type == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;

            if((type == POSITION_TYPE_BUY && (sl < newSL - p_trailingStep * _Point || sl == 0)) ||
               (type == POSITION_TYPE_SELL && (sl > newSL + p_trailingStep * _Point || sl == 0))) {
               trade.PositionModify(ticket, NormalizeDouble(newSL, _Digits), PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

void CalculaStats() {
   static datetime lastUpdate = 0;
   if(TimeCurrent() - lastUpdate < 3600) return; // Update stats once an hour
   lastUpdate = TimeCurrent();

   int wins = 0, losses = 0;
   double totalProfit = 0, totalLoss = 0;

   if(HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent())) { // Last 30 days
      for(int i=0; i<HistoryDealsTotal(); i++) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(p > 0) { wins++; totalProfit += p; }
            else if(p < 0) { losses++; totalLoss += MathAbs(p); }
         }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100 : 0;
   double profitFactor = (totalLoss > 0) ? totalProfit / totalLoss : totalProfit;

   GravaLog("Stats - WinRate: " + DoubleToString(winRate, 1) + "% PF: " + DoubleToString(profitFactor, 2));
}

// ---------- AUXILIARY FUNCTIONS ----------

bool AguardaNoticias() {
   // news_veto.txt
   int hVeto = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(hVeto != INVALID_HANDLE) {
      string veto = FileReadString(hVeto);
      FileClose(hVeto);
      if(veto == "1") return true;
   }

   // calendar.txt parsing
   int hCal = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(hCal != INVALID_HANDLE) {
      while(!FileIsEnding(hCal)) {
         string line = FileReadString(hCal);
         if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            // Format: YYYY.MM.DD HH:MM;Symbol;Impact;Title
            string parts[];
            StringSplit(line, ';', parts);
            if(ArraySize(parts) >= 1) {
               datetime newsTime = StringToTime(parts[0]);
               if(MathAbs(TimeCurrent() - newsTime) < p_newsVeto * 60) {
                  FileClose(hCal);
                  return true;
               }
            }
         }
      }
      FileClose(hCal);
   }

   return false;
}

void GravaLog(string texto) {
   string time = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string log = "[" + time + "] " + texto;
   Print(log);

   int hLog = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(hLog != INVALID_HANDLE) {
      FileSeek(hLog, 0, SEEK_END);
      FileWriteString(hLog, log + "\r\n");
      FileClose(hLog);
   }

   SendNotification(log);
}

void ResetStrategy() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
      rules[i].Reset();
   }
   nRules = 0;
}
