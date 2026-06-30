//+------------------------------------------------------------------+
//|                                             MT_LiveExecutor.mq5 |
//|                                  Copyright 2024, MetaTrader AI   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, MetaTrader AI"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

//--- defines
#define EA_MAGIC 123456
#define MAX_RULES 40

//--- enums
enum Signal {BUY=1, SELL=-1, NONE=0};

//--- structs
struct Rule {
   bool     active;
   int      intent; // 1 BUY, -1 SELL
   int      type;   // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: Breakout, 6: Delta, 7: Volume, 8: AMA, 9: Pattern, 10: Relative
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   string   op;
   int      handle;
   int      handle2;

   void Reset() {
      active = false;
      intent = 0;
      type = 0;
      tf = PERIOD_CURRENT;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      op = "";
      if(handle != INVALID_HANDLE) { IndicatorRelease(handle); handle = INVALID_HANDLE; }
      if(handle2 != INVALID_HANDLE) { IndicatorRelease(handle2); handle2 = INVALID_HANDLE; }
   }
};

//--- globals
Rule g_rules[MAX_RULES];
int  g_nRules = 0;
CTrade g_trade;

// Strategy params
int    p_maxTrades = 3;
double p_riskPercent = 1.0;
int    p_stopPoints = 300;
int    p_takePoints = 500;
int    p_startHour = 0;
int    p_breakevenTrigger = 0;
int    p_breakevenOffset = 0;
int    p_trailingStop = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// Stats
double g_totalProfit = 0;
int    g_winTrades = 0;
int    g_lossTrades = 0;

//--- Event Handlers
int OnInit() {
   g_trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
   CalculaStats();
}

void OnTick() {
   if(Hour() < p_startHour) return;
   if(AguardaNoticias()) return;

   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBar) {
      Signal s = AvaliaTudo();
      if(s != NONE) {
         EnviaOrdem(s);
      }
      lastBar = currentBar;
   }

   GerenciaPosicoes();
}

void OnTimer() {
   static uint lastCheck = 0;
   if(GetTickCount() - lastCheck > 1000) {
      if(FileIsExist("prompt.txt", FILE_COMMON)) {
         int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
         if(h != INVALID_HANDLE) {
            string prompt = FileReadString(h);
            FileClose(h);
            FileDelete("prompt.txt", FILE_COMMON);
            InterpretaPrompt(prompt);
         }
      }
      lastCheck = GetTickCount();
   }

   static datetime lastStats = 0;
   if(TimeCurrent() - lastStats > 3600) {
      CalculaStats();
      lastStats = TimeCurrent();
   }
}

//--- NLP/Parser
void InterpretaPrompt(string prompt) {
   ResetStrategy();
   GravaLog("Novo prompt recebido: " + prompt);

   string segments[];
   string cleanPrompt = prompt;
   StringReplace(cleanPrompt, "|", ".");
   StringReplace(cleanPrompt, "\n", ".");
   ushort sep = StringGetCharacter(".", 0);
   StringSplit(cleanPrompt, sep, segments);

   int currentIntent = 0;

   for(int i=0; i<ArraySize(segments); i++) {
      string seg = segments[i];
      StringToLower(seg);

      if(StringFind(seg, "compra") >= 0) currentIntent = 1;
      else if(StringFind(seg, "vende") >= 0) currentIntent = -1;

      // Global params
      if(StringFind(seg, "risco de") >= 0) p_riskPercent = ExtraiNumero(seg, "risco de");
      if(StringFind(seg, "stop de") >= 0) p_stopPoints = (int)ExtraiNumero(seg, "stop de");
      if(StringFind(seg, "take de") >= 0) p_takePoints = (int)ExtraiNumero(seg, "take de");
      if(StringFind(seg, "máximo") >= 0 && StringFind(seg, "trades") >= 0) p_maxTrades = (int)ExtraiNumero(seg, "máximo");
      if(StringFind(seg, "depois das") >= 0) p_startHour = (int)ExtraiNumero(seg, "depois das");
      else if(StringFind(seg, "após as") >= 0) p_startHour = (int)ExtraiNumero(seg, "após as");

      if(StringFind(seg, "cada") >= 0 && StringFind(seg, "minutos") >= 0) {
         int m = (int)ExtraiNumero(seg, "cada");
         if(m == 1) p_frequency = PERIOD_M1;
         else if(m == 5) p_frequency = PERIOD_M5;
         else if(m == 15) p_frequency = PERIOD_M15;
         else if(m == 30) p_frequency = PERIOD_M30;
         else if(m == 60) p_frequency = PERIOD_H1;
      }

      // Breakeven / Trailing
      if(StringFind(seg, "breakeven") >= 0 || StringFind(seg, "move stop para entrada") >= 0) {
         p_breakevenTrigger = (int)ExtraiNumero(seg, "atingir");
         p_breakevenOffset = (int)ExtraiNumero(seg, "entrada");
      }
      if(StringFind(seg, "trailing") >= 0 || StringFind(seg, "rastreio") >= 0) {
         p_trailingStop = (int)ExtraiNumero(seg, "trailing");
         if(p_trailingStop == 0) p_trailingStop = (int)ExtraiNumero(seg, "rastreio");
      }

      // Rules
      AddRuleSpecific(seg, currentIntent);
   }
}

void AddRuleSpecific(string seg, int intent) {
   if(g_nRules >= MAX_RULES) return;

   // MA
   int maPos = StringFind(seg, "média");
   if(maPos < 0) maPos = StringFind(seg, "ma");
   if(maPos >= 0) {
      g_rules[g_nRules].active = true;
      g_rules[g_nRules].intent = intent;
      g_rules[g_nRules].type = 1;
      g_rules[g_nRules].p1 = (int)ExtraiNumero(seg, "média", maPos);
      if(g_rules[g_nRules].p1 == 0) g_rules[g_nRules].p1 = (int)ExtraiNumero(seg, "ma", maPos);
      if(g_rules[g_nRules].p1 == 0) g_rules[g_nRules].p1 = 20;

      if(StringFind(seg, "cruzar acima") >= 0) g_rules[g_nRules].op = "cross_above";
      else if(StringFind(seg, "cruzar abaixo") >= 0) g_rules[g_nRules].op = "cross_below";
      else if(StringFind(seg, "acima") >= 0) g_rules[g_nRules].op = ">";
      else if(StringFind(seg, "abaixo") >= 0) g_rules[g_nRules].op = "<";

      g_rules[g_nRules].handle = iMA(_Symbol, p_frequency, g_rules[g_nRules].p1, 0, MODE_SMA, PRICE_CLOSE);
      g_nRules++;
   }

   // RSI
   int rsiPos = StringFind(seg, "rsi");
   if(rsiPos >= 0) {
      g_rules[g_nRules].active = true;
      g_rules[g_nRules].intent = intent;
      g_rules[g_nRules].type = 2;
      g_rules[g_nRules].p1 = (int)ExtraiNumero(seg, "rsi", rsiPos);
      if(g_rules[g_nRules].p1 == 0) g_rules[g_nRules].p1 = 14;

      if(StringFind(seg, "subir acima") >= 0 || StringFind(seg, "acima") >= 0) {
         g_rules[g_nRules].op = ">";
         g_rules[g_nRules].d1 = ExtraiNumero(seg, "acima", rsiPos);
         if(g_rules[g_nRules].d1 == 0) g_rules[g_nRules].d1 = 70;
      } else if(StringFind(seg, "cair abaixo") >= 0 || StringFind(seg, "abaixo") >= 0) {
         g_rules[g_nRules].op = "<";
         g_rules[g_nRules].d1 = ExtraiNumero(seg, "abaixo", rsiPos);
         if(g_rules[g_nRules].d1 == 0) g_rules[g_nRules].d1 = 30;
      }

      g_rules[g_nRules].handle = iRSI(_Symbol, p_frequency, g_rules[g_nRules].p1, PRICE_CLOSE);
      g_nRules++;
   }

   // STOCH
   int stochPos = StringFind(seg, "estocástico");
   if(stochPos < 0) stochPos = StringFind(seg, "stoch");
   if(stochPos >= 0) {
      g_rules[g_nRules].active = true;
      g_rules[g_nRules].intent = intent;
      g_rules[g_nRules].type = 3;
      g_rules[g_nRules].p1 = 5; // K
      g_rules[g_nRules].p2 = 3; // D
      g_rules[g_nRules].p3 = 3; // Slowing
      g_rules[g_nRules].handle = iStochastic(_Symbol, p_frequency, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      g_nRules++;
   }

   // BB
   int bbPos = StringFind(seg, "bollinger");
   if(bbPos >= 0) {
      g_rules[g_nRules].active = true;
      g_rules[g_nRules].intent = intent;
      g_rules[g_nRules].type = 4;
      g_rules[g_nRules].p1 = 20; // Period
      g_rules[g_nRules].d1 = 2.0; // Dev
      g_rules[g_nRules].handle = iBands(_Symbol, p_frequency, 20, 0, 2.0, PRICE_CLOSE);
      g_nRules++;
   }
}

double ExtraiNumero(string text, string keyword, int startPos=0) {
   int idx = StringFind(text, keyword, startPos);
   if(idx < 0) return 0;

   string sub = StringSubstr(text, idx + StringLen(keyword));
   string res = "";
   bool foundDigit = false;

   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+') {
         res += ShortToString(c);
         foundDigit = true;
      } else if(foundDigit) {
         break;
      }
   }
   return StringToDouble(res);
}

void ResetStrategy() {
   for(int i=0; i<MAX_RULES; i++) g_rules[i].Reset();
   g_nRules = 0;
   p_startHour = 0;
   p_riskPercent = 1.0;
}

//--- Signal Engine
Signal AvaliaTudo() {
   int buyRules = 0, sellRules = 0;
   int buyMet = 0, sellMet = 0;

   for(int i=0; i<g_nRules; i++) {
      if(!g_rules[i].active) continue;

      bool met = AvaliaRegra(g_rules[i]);
      if(g_rules[i].intent == 1) {
         buyRules++;
         if(met) buyMet++;
      } else if(g_rules[i].intent == -1) {
         sellRules++;
         if(met) sellMet++;
      }
   }

   if(buyRules > 0 && buyMet == buyRules) return BUY;
   if(sellRules > 0 && sellMet == sellRules) return SELL;

   return NONE;
}

bool AvaliaRegra(Rule &r) {
   if(r.type == 1) { // MA
      double ma[2];
      if(CopyBuffer(r.handle, 0, 0, 2, ma) < 2) return false;
      double close[2];
      if(CopyClose(_Symbol, p_frequency, 0, 2, close) < 2) return false;
      ArraySetAsSeries(ma, true);
      ArraySetAsSeries(close, true);
      if(r.op == "cross_above") return (close[1] <= ma[1] && close[0] > ma[0]);
      if(r.op == "cross_below") return (close[1] >= ma[1] && close[0] < ma[0]);
      if(r.op == ">") return (close[0] > ma[0]);
      if(r.op == "<") return (close[0] < ma[0]);
   }

   if(r.type == 2) { // RSI
      double rsi[1];
      if(CopyBuffer(r.handle, 0, 0, 1, rsi) < 1) return false;
      if(r.op == ">") return (rsi[0] > r.d1);
      if(r.op == "<") return (rsi[0] < r.d1);
   }

   if(r.type == 3) { // Stoch
      double k[2], d[2];
      CopyBuffer(r.handle, 0, 0, 2, k);
      CopyBuffer(r.handle, 1, 0, 2, d);
      ArraySetAsSeries(k, true);
      ArraySetAsSeries(d, true);
      if(r.intent == 1) return (k[1] < d[1] && k[0] > d[0]); // Cross up
      if(r.intent == -1) return (k[1] > d[1] && k[0] < d[0]); // Cross down
   }

   if(r.type == 4) { // BB
      double lower[1], upper[1], close[1];
      CopyBuffer(r.handle, 1, 0, 1, upper);
      CopyBuffer(r.handle, 2, 0, 1, lower);
      CopyClose(_Symbol, p_frequency, 0, 1, close);
      if(r.intent == 1) return (close[0] < lower[0]);
      if(r.intent == -1) return (close[0] > upper[0]);
   }

   return false;
}

//--- Trade Management
void EnviaOrdem(Signal s) {
   if(PositionsTotalByMagic(EA_MAGIC) >= p_maxTrades) return;

   double lote = CalculaLote(p_riskPercent);
   double sl = 0, tp = 0;
   double price = 0;

   int retries = 3;
   bool success = false;

   for(int i=0; i<retries && !success; i++) {
      if(s == BUY) {
         price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         sl = price - p_stopPoints * _Point;
         tp = price + p_takePoints * _Point;
         if(g_trade.Buy(lote, _Symbol, price, sl, tp)) {
            if(g_trade.ResultRetcode() == TRADE_RETCODE_DONE || g_trade.ResultRetcode() == TRADE_RETCODE_PLACED) {
               GravaLog("Compra enviada: " + g_trade.ResultRetcodeDescription());
               GravaEstadoCSV();
               success = true;
            }
         }
      } else if(s == SELL) {
         price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         sl = price + p_stopPoints * _Point;
         tp = price - p_takePoints * _Point;
         if(g_trade.Sell(lote, _Symbol, price, sl, tp)) {
            if(g_trade.ResultRetcode() == TRADE_RETCODE_DONE || g_trade.ResultRetcode() == TRADE_RETCODE_PLACED) {
               GravaLog("Venda enviada: " + g_trade.ResultRetcodeDescription());
               GravaEstadoCSV();
               success = true;
            }
         }
      }
      if(!success) {
         GravaLog("Falha ao enviar ordem (Tentativa " + (string)(i+1) + "): " + g_trade.ResultRetcodeDescription());
         Sleep(100);
      }
   }
}

double CalculaLote(double risco) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * risco / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(p_stopPoints == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lot = riscoAbs / (p_stopPoints * _Point * (tickVal / tickSize));

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, MathMin(maxLot, NormalizeDouble(lot / stepLot, 0) * stepLot));
   return lot;
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket)) {
         if(PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         long type = PositionGetInteger(POSITION_TYPE);
         double sl = PositionGetDouble(POSITION_SL);

         // Breakeven
         if(p_breakevenTrigger > 0) {
            double profitPoints = (type == POSITION_TYPE_BUY) ? (currentPrice - openPrice)/_Point : (openPrice - currentPrice)/_Point;
            if(profitPoints >= p_breakevenTrigger) {
               double newSL = (type == POSITION_TYPE_BUY) ? openPrice + p_breakevenOffset*_Point : openPrice - p_breakevenOffset*_Point;
               if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
                  g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
                  GravaLog("Breakeven acionado para ticket " + (string)ticket);
               }
            }
         }

         // Trailing
         if(p_trailingStop > 0) {
            if(type == POSITION_TYPE_BUY) {
               double newSL = currentPrice - p_trailingStop * _Point;
               if(newSL > sl + _Point) {
                  g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            } else {
               double newSL = currentPrice + p_trailingStop * _Point;
               if(newSL < sl - _Point || sl == 0) {
                  g_trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

//--- Helpers
bool AguardaNoticias() {
   // Check news_veto.txt
   if(FileIsExist("news_veto.txt", FILE_COMMON)) {
      int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string line = FileReadString(h);
         FileClose(h);
         if(line == "true" || line == "1") return true;
      }
   }

   // Check calendar.txt
   if(FileIsExist("calendar.txt", FILE_COMMON)) {
      int h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         while(!FileIsEnding(h)) {
            string line = FileReadString(h);
            // Example calendar line: "2024.06.30 14:30;USD;CPI;High"
            string parts[];
            StringSplit(line, ';', parts);
            if(ArraySize(parts) >= 4 && parts[3] == "High") {
               datetime newsTime = StringToTime(parts[0]);
               if(MathAbs(TimeCurrent() - newsTime) < 1200) { // 20 min window
                  FileClose(h);
                  return true;
               }
            }
         }
         FileClose(h);
      }
   }
   return false;
}

void GravaLog(string text) {
   Print(text);
   SendNotification(text);
}

void GravaEstadoCSV() {
   int h = FileOpen("states.csv", FILE_WRITE|FILE_READ|FILE_CSV|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      for(int i=0; i<PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
               FileWrite(h, ticket, PositionGetDouble(POSITION_PRICE_OPEN), PositionGetDouble(POSITION_SL), PositionGetDouble(POSITION_TP), TimeToString(PositionGetInteger(POSITION_TIME)));
            }
         }
      }
      FileClose(h);
   }
}

void CalculaStats() {
   GravaLog("Relatório de performance: WinRate=" + (string)g_winTrades + "/" + (string)(g_winTrades+g_lossTrades));
}

int PositionsTotalByMagic(long magic) {
   int count = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(PositionSelectByTicket(PositionGetTicket(i))) {
         if(PositionGetInteger(POSITION_MAGIC) == magic) count++;
      }
   }
   return count;
}

int Hour() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour;
}
