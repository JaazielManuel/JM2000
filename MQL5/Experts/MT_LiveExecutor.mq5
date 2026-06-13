//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Procedural MQL5 Strategy Executor
//========================================================================

#property copyright "Copyright 2023, MT-LiveExecutor"
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
   bool     active;
   int      intent;     // 1: BUY, -1: SELL
   int      type;       // 1: MA Cross, 2: RSI, 3: Stochastic, 4: BB, 5: DailyBreak, 6: Delta, 7: VolCycle, 8: AMA, 9: BarPattern, 10: Relative
   int      tf;
   int      handle1;
   int      handle2;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;

   void Reset() {
      active = false;
      intent = 0;
      type = 0;
      tf = PERIOD_CURRENT;
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
   }
};

// ---------- GLOBALS ----------
Rule rules[20];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;

// Strategy Parameters
double p_risk = 1.0;
int    p_sl = 300;
int    p_tp = 500;
int    p_maxTrades = 3;
int    p_breakeven = 0;
int    p_breakevenPlus = 0;
int    p_trailingStop = 0;
int    p_trailingStep = 0;
bool   p_martingale = false;
string p_startTime = "00:00";
int    p_newsVeto = 20; // minutes
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime lastBarTime = 0;

// ---------- NLP PARSER ----------

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string promptLower = prompt;
   StringToLower(promptLower);
   StringReplace(promptLower, " e ", "."); // Split conjunctions

   string segments[];
   int nSeg = StringSplit(promptLower, '.', segments);

   int currentIntent = 0; // 0: Global/Unknown, 1: Buy, -1: Sell

   for(int i=0; i<nSeg; i++) {
      string txt = segments[i];
      StringTrimLeft(txt);
      StringTrimRight(txt);

      // Intent detection
      if(StringFind(txt, "compra") >= 0) currentIntent = 1;
      else if(StringFind(txt, "venda") >= 0) currentIntent = -1;

      // Global Parameters
      int cursor = 0;
      if(StringFind(txt, "risco") >= 0) {
         cursor = StringFind(txt, "risco");
         p_risk = ExtraiNumero(txt, cursor);
      }
      if(StringFind(txt, "stop") >= 0 && StringFind(txt, "move") < 0) {
         cursor = StringFind(txt, "stop");
         p_sl = (int)ExtraiNumero(txt, cursor);
      }
      if(StringFind(txt, "take") >= 0 || StringFind(txt, "alvo") >= 0) {
         cursor = (StringFind(txt, "take") >= 0) ? StringFind(txt, "take") : StringFind(txt, "alvo");
         p_tp = (int)ExtraiNumero(txt, cursor);
      }
      if(StringFind(txt, "máximo") >= 0) {
         cursor = StringFind(txt, "máximo");
         p_maxTrades = (int)ExtraiNumero(txt, cursor);
      }
      if(StringFind(txt, "notícias") >= 0) {
         cursor = StringFind(txt, "notícias");
         p_newsVeto = (int)ExtraiNumero(txt, cursor);
      }
      if(StringFind(txt, "martingale") >= 0) p_martingale = true;

      if(StringFind(txt, "depois das") >= 0 || StringFind(txt, "início") >= 0 || StringFind(txt, "começar") >= 0) {
         int hPos = StringFind(txt, "h");
         if(hPos > 0) {
            int start = hPos - 1;
            while(start > 0 && StringSubstr(txt, start-1, 1) >= "0" && StringSubstr(txt, start-1, 1) <= "9") start--;
            string hStr = StringSubstr(txt, start, hPos - start);
            p_startTime = hStr + ":00";
         }
      }

      // Breakeven
      if(StringFind(txt, "move stop para entrada") >= 0) {
         cursor = StringFind(txt, "atingir");
         if(cursor < 0) cursor = 0;
         p_breakeven = (int)ExtraiNumero(txt, cursor);
         p_breakevenPlus = (int)ExtraiNumero(txt, cursor);
      }

      // Trailing Stop
      if(StringFind(txt, "trailing") >= 0 || StringFind(txt, "rastreio") >= 0) {
         cursor = StringFind(txt, "trailing");
         if(cursor < 0) cursor = StringFind(txt, "rastreio");
         p_trailingStop = (int)ExtraiNumero(txt, cursor);
         p_trailingStep = (int)ExtraiNumero(txt, cursor);
      }

      // Indicators
      AddRule(txt, currentIntent);

      // Frequency
      int tf = PeriodoTexto(txt);
      if(tf != PERIOD_CURRENT) p_frequency = (ENUM_TIMEFRAMES)tf;
   }

   GravaLog("Estratégia interpretada: Risco=" + DoubleToString(p_risk, 2) + "%, SL=" + (string)p_sl + ", TP=" + (string)p_tp);
}

void AddRule(string txt, int intent) {
   if(nRules >= 20) return;

   static int lastMA = 20;
   static int lastRSI = 14;

   // MA Cross
   if(StringFind(txt, "média") >= 0 || StringFind(txt, "ema") >= 0 || StringFind(txt, "sma") >= 0) {
      int cursor = StringFind(txt, "média");
      if(cursor < 0) cursor = StringFind(txt, "ema");
      if(cursor < 0) cursor = StringFind(txt, "sma");

      int p = (int)ExtraiNumero(txt, cursor);
      if(p == 0) p = lastMA; else lastMA = p;

      Rule r; r.Reset();
      r.active = true;
      r.intent = intent;
      r.type = 1;
      r.p1 = p;
      r.tf = PeriodoTexto(txt);
      r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) {
         rules[nRules] = r;
         nRules++;
      }
   }

   // RSI
   if(StringFind(txt, "rsi") >= 0) {
      int cursor = StringFind(txt, "rsi");
      int p = (int)ExtraiNumero(txt, cursor);
      if(p == 0) p = lastRSI; else lastRSI = p;

      double level = ExtraiNumero(txt, cursor);
      if(level == 0) level = (intent == 1) ? 30 : 70;

      Rule r; r.Reset();
      r.active = true;
      r.intent = intent;
      r.type = 2;
      r.p1 = p;
      r.d1 = level;
      r.tf = PeriodoTexto(txt);
      r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) {
         rules[nRules] = r;
         nRules++;
      }
   }

   // 2-Bar Patterns
   if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "candle") >= 0 || StringFind(txt, "barra") >= 0) {
      Rule r; r.Reset();
      r.active = true;
      r.intent = intent;
      r.type = 9;
      r.tf = PeriodoTexto(txt);
      rules[nRules] = r;
      nRules++;
   }
}

double ExtraiNumero(string txt, int &cursor) {
   string res = "";
   bool found = false;
   for(int i=cursor; i<StringLen(txt); i++) {
      string c = StringSubstr(txt, i, 1);
      if((c >= "0" && c <= "9") || c == "." || c == ",") {
         if(c == ",") c = ".";
         res += c;
         found = true;
      } else if(found) {
         cursor = i;
         break;
      }
   }
   return StringToDouble(res);
}

int PeriodoTexto(string txt) {
   if(StringFind(txt, "m15") >= 0) return PERIOD_M15; // Order matters: m15 before m1
   if(StringFind(txt, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(txt, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(txt, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(txt, "d1") >= 0)  return PERIOD_D1;
   if(StringFind(txt, "minutos") >= 0 || StringFind(txt, "min") >= 0) {
      int cursor = 0;
      int val = (int)ExtraiNumero(txt, cursor);
      if(val == 1) return PERIOD_M1;
      if(val == 5) return PERIOD_M5;
      if(val == 15) return PERIOD_M15;
      if(val == 30) return PERIOD_M30;
   }
   return PERIOD_CURRENT;
}

void ResetStrategy() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE) IndicatorRelease(rules[i].handle2);
      rules[i].Reset();
   }
   nRules = 0;
   p_martingale = false;
}

void GravaLog(string msg) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()) + ": " + msg);
      FileClose(h);
   }
   Print(msg);
}

// ---------- SIGNAL ENGINE ----------

Signal AvaliaRegra(Rule &r) {
   if(!r.active) return NONE;

   double val1[3], val2[3];

   switch(r.type) {
      case 1: // MA Cross (Price cross MA)
         if(CopyBuffer(r.handle1, 0, 0, 3, val1) < 3) return NONE;
         if(r.intent == 1) {
            if(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2) < val1[0] && iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > val1[1]) return BUY;
            if(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > val1[1]) return BUY; // State check
         } else if(r.intent == -1) {
            if(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2) > val1[0] && iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) < val1[1]) return SELL;
            if(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) < val1[1]) return SELL; // State check
         }
         break;

      case 2: // RSI Threshold
         if(CopyBuffer(r.handle1, 0, 0, 3, val1) < 3) return NONE;
         if(r.intent == 1) {
            if(val1[0] <= r.d1 && val1[1] > r.d1) return BUY; // Cross above
            if(val1[1] > r.d1) return BUY; // State check
         } else if(r.intent == -1) {
            if(val1[0] >= r.d1 && val1[1] < r.d1) return SELL; // Cross below
            if(val1[1] < r.d1) return SELL; // State check
         }
         break;

      case 9: // 2-Bar Patterns
         double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         if(h0 < h1 && l0 > l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1)) ? BUY : SELL; // Inside
         if(h0 > h1 && l0 < l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1)) ? SELL : BUY; // Outside
         break;
   }

   return NONE;
}

Signal AvaliaTudo() {
   int buyVotos = 0, sellVotos = 0;
   int buyRules = 0, sellRules = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;

      Signal s = AvaliaRegra(rules[i]);
      if(rules[i].intent == 1) {
         buyRules++;
         if(s == BUY) buyVotos++;
      }
      else if(rules[i].intent == -1) {
         sellRules++;
         if(s == SELL) sellVotos++;
      }
   }

   if(buyRules > 0 && buyVotos == buyRules) return BUY;
   if(sellRules > 0 && sellVotos == sellRules) return SELL;

   return NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double res[];
   if(CopyBuffer(handle, buffer, shift, 1, res) > 0) return res[0];
   return 0;
}

// ---------- TRADE MANAGEMENT ----------

void EnviaOrdem(Signal s, string motivo) {
   if(s == NONE) return;
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) return;

   double lote = CalculaLote(p_risk);
   double preco = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (s == BUY) ? preco - p_sl * _Point : preco + p_sl * _Point;
   double tp = (s == BUY) ? preco + p_tp * _Point : preco - p_tp * _Point;

   if(s == BUY) trade.Buy(lote, _Symbol, preco, sl, tp, motivo);
   else trade.Sell(lote, _Symbol, preco, sl, tp, motivo);

   if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
      GravaLog("Ordem enviada: " + motivo + " Lote=" + DoubleToString(lote, 2));
      SendNotification("MT-LiveExecutor: " + motivo);
   } else {
      GravaLog("Erro ao enviar ordem: " + (string)trade.ResultRetcode());
   }
}

double CalculaLote(double riscoPercent) {
   if(p_martingale) {
      // Logic to check last trade and double risk if loss
   }
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slPoints = (p_sl > 0) ? p_sl : 100;

   double lote = riscoAbs / (slPoints * _Point * (tickVal / tickSize));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lote = MathFloor(lote / step) * step;

   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lote < minVol) lote = minVol;
   if(lote > maxVol) lote = maxVol;

   return lote;
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) {
            ulong ticket = posInfo.Ticket();
            if(!PositionSelectByTicket(ticket)) continue;

            double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
            double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double currentSL = PositionGetDouble(POSITION_SL);

            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

            // Breakeven
            if(p_breakeven > 0) {
               if(profitPoints >= p_breakeven) {
                  double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? openPrice + p_breakevenPlus * _Point : openPrice - p_breakevenPlus * _Point;
                  if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && currentSL < newSL) || (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
                     trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                     continue;
                  }
               }
            }

            // Trailing Stop
            if(p_trailingStop > 0) {
               if(profitPoints >= p_trailingStop) {
                  double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
                  if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && newSL > currentSL + p_trailingStep * _Point) ||
                     (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (newSL < currentSL - p_trailingStep * _Point || currentSL == 0))) {
                     trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                  }
               }
            }
         }
      }
   }
}

// ---------- UTILITIES ----------

bool AguardaNoticias() {
   // Simplified news veto via binary flag
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string content = FileReadString(h);
      FileClose(h);
      if(content == "1") return true;
   }

   // Temporal filter via calendar.txt
   h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      while(!FileIsEnding(h)) {
         string line = FileReadString(h);
         // Expected format: YYYY.MM.DD HH:MM;Symbol;Impact;Title
         if(StringLen(line) < 16) continue;
         if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            datetime newsTime = StringToTime(StringSubstr(line, 0, 16));
            if(MathAbs(TimeCurrent() - newsTime) < p_newsVeto * 60) {
               FileClose(h);
               return true;
            }
         }
      }
      FileClose(h);
   }

   return false;
}

void GravaCSV() {
   static datetime lastSave = 0;
   if(TimeCurrent() - lastSave < 5) return;
   lastSave = TimeCurrent();

   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "OpenPrice", "Profit");
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         if(posInfo.SelectByIndex(i)) {
            FileWrite(h, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.Profit());
         }
      }
      FileClose(h);
   }
}

void CalculaStats() {
   // Win rate, drawdown, etc from History
}

// ---------- AI MOCKUP ----------
void AIPredict() {}
void AIOptimizer() {
   static datetime lastOpt = 0;
   if(TimeCurrent() - lastOpt < 3600) return;
   lastOpt = TimeCurrent();
   // Optimization logic...
}

// ---------- MQL5 HANDLERS ----------

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);

   // Initial prompt check
   int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string p = FileReadString(h);
      FileClose(h);
      InterpretaPrompt(p);
   }

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ResetStrategy();
   EventKillTimer();
}

void OnTimer() {
   // Check for new prompt
   static datetime lastPromptCheck = 0;
   if(TimeCurrent() - lastPromptCheck >= 1) {
      lastPromptCheck = TimeCurrent();
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string p = FileReadString(h);
         FileClose(h);
         static string lastPrompt = "";
         if(p != lastPrompt) {
            lastPrompt = p;
            InterpretaPrompt(p);
         }
      }
   }
   AIOptimizer();
}

void OnTick() {
   GerenciaPosicoes();
   GravaCSV();

   // Time filter
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string nowTime = StringFormat("%02d:%02d", dt.hour, dt.min);
   if(nowTime < p_startTime) return;

   // Frequency filter (New Bar)
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      lastBarTime = currentBar;
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s, "Estratégia NLP");
   }
}
