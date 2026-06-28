//=========================  MT5-LIVE-EXECUTOR  =========================
// Description: Multi-strategy executor driven by Portuguese prompts.
// EA_MAGIC: 123456
//========================================================================

#property copyright "MT-LiveExecutor"
#property link      ""
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- ENUMS ---
enum ENUM_SIGNAL { SIGNAL_NONE=0, SIGNAL_BUY=1, SIGNAL_SELL=-1 };

// --- STRUCTS ---
struct Rule {
   bool           active;
   int            type;       // Indicator type (1=MA, 2=RSI, etc.)
   ENUM_TIMEFRAMES tf;
   int            handle;     // Main indicator handle
   int            handle2;    // Optional second handle (e.g. for crosses)
   int            p1, p2, p3; // Integer parameters
   double         d1, d2;     // Double parameters
   string         s1;         // String parameter (e.g. benchmark symbol)
   string         op;         // Operator (">", "<", "cross_above", etc.)
   ENUM_SIGNAL    intent;     // BUY or SELL intent

   void Reset() {
      if(handle != INVALID_HANDLE)  IndicatorRelease(handle);
      if(handle2 != INVALID_HANDLE) IndicatorRelease(handle2);
      active = false;
      type = 0;
      tf = PERIOD_CURRENT;
      handle = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      op = "";
      intent = SIGNAL_NONE;
   }
};

// --- GLOBALS ---
Rule rules_buy[20];
Rule rules_sell[20];
int nRulesBuy = 0;
int nRulesSell = 0;

// Strategy Parameters
double p_risk        = 1.0;
int    p_stopPoints  = 0;
int    p_takePoints  = 0;
int    p_breakeven   = 0;
int    p_beProfit    = 0;
int    p_trailingStop = 0;
int    p_maxTrades   = 1;
int    p_startHour   = 0;
bool   p_martingale  = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool   p_exitOpposite = false;

// Trading Objects
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;

const int EA_MAGIC = 123456;
datetime last_bar = 0;
string last_prompt = "";

// --- NLP ENGINE ---

double ExtraiNumero(string txt, int startPos=0) {
   string res = "";
   bool found = false;
   for(int i=startPos; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == '-' || c == '+') {
         res += ShortToString(c);
         found = true;
      } else if(found) break;
   }
   return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string txt) {
   string t = txt;
   StringToLower(t);
   if(StringFind(t, "m15") >= 0) return PERIOD_M15; // Order matters: m15 before m1
   if(StringFind(t, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(t, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(t, "m30") >= 0) return PERIOD_M30;
   if(StringFind(t, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(t, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(t, "d1") >= 0)  return PERIOD_D1;
   return PERIOD_CURRENT;
}

void AddRuleSpecific(string segment, ENUM_SIGNAL intent) {
   Rule newRule;
   newRule.Reset();
   newRule.intent = intent;
   newRule.active = true;
   newRule.tf = PeriodoTexto(segment);

   string s = segment;
   StringToLower(s);

   // Moving Average
   int maPos = StringFind(s, "média");
   if(maPos < 0) maPos = StringFind(s, "ma");
   if(maPos >= 0) {
      newRule.type = 1;
      newRule.p1 = (int)ExtraiNumero(s, maPos);
      if(StringFind(s, "cruzar acima") >= 0 || StringFind(s, "cruzamento acima") >= 0) newRule.op = "cross_above";
      else if(StringFind(s, "cruzar abaixo") >= 0 || StringFind(s, "cruzamento abaixo") >= 0) newRule.op = "cross_below";
      else if(StringFind(s, "acima") >= 0) newRule.op = ">";
      else if(StringFind(s, "abaixo") >= 0) newRule.op = "<";

      newRule.handle = iMA(_Symbol, newRule.tf, newRule.p1, 0, MODE_EMA, PRICE_CLOSE);
   }

   // RSI
   int rsiPos = StringFind(s, "rsi");
   if(rsiPos >= 0) {
      Rule rsiRule;
      rsiRule.Reset();
      rsiRule.intent = intent;
      rsiRule.active = true;
      rsiRule.tf = newRule.tf;
      rsiRule.type = 2;
      rsiRule.p1 = (int)ExtraiNumero(s, rsiPos);

      int opPos = -1;
      int p_acima = StringFind(s, "acima", rsiPos);
      int p_subir = StringFind(s, "subir", rsiPos);
      int p_abaixo = StringFind(s, "abaixo", rsiPos);
      int p_cair = StringFind(s, "cair", rsiPos);

      if(p_acima >= 0 || p_subir >= 0) {
         rsiRule.op = ">";
         opPos = (p_acima >= 0) ? p_acima : p_subir;
      }
      else if(p_abaixo >= 0 || p_cair >= 0) {
         rsiRule.op = "<";
         opPos = (p_abaixo >= 0) ? p_abaixo : p_cair;
      }

      if(opPos >= 0) rsiRule.d1 = ExtraiNumero(s, opPos);
      rsiRule.handle = iRSI(_Symbol, rsiRule.tf, rsiRule.p1, PRICE_CLOSE);

      if(intent == SIGNAL_BUY && nRulesBuy < 20) rules_buy[nRulesBuy++] = rsiRule;
      else if(intent == SIGNAL_SELL && nRulesSell < 20) rules_sell[nRulesSell++] = rsiRule;
   }

   // 2-Bar Pattern (Type 9)
   if(StringFind(s, "padrão") >= 0 || StringFind(s, "2-bar") >= 0) {
      newRule.type = 9;
      newRule.op = "pattern";
   }

   // Relative Strength (Type 10)
   int benchPos = StringFind(s, "bench");
   if(benchPos >= 0) {
      newRule.type = 10;
      int quoteStart = StringFind(s, "\"", benchPos);
      if(quoteStart >= 0) {
         int quoteEnd = StringFind(s, "\"", quoteStart + 1);
         if(quoteEnd > quoteStart) newRule.s1 = StringSubstr(s, quoteStart + 1, quoteEnd - quoteStart - 1);
      } else {
         newRule.s1 = "US30"; // Default benchmark
      }
      newRule.handle = iRSI(_Symbol, newRule.tf, 14, PRICE_CLOSE);
      newRule.handle2 = iRSI(newRule.s1, newRule.tf, 14, PRICE_CLOSE);
   }

   if(newRule.type > 0) {
      if(intent == SIGNAL_BUY && nRulesBuy < 20) {
         rules_buy[nRulesBuy] = newRule;
         nRulesBuy++;
      } else if(intent == SIGNAL_SELL && nRulesSell < 20) {
         rules_sell[nRulesSell] = newRule;
         nRulesSell++;
      }
   }
}

void InterpretaPrompt(string prompt) {
   string p = prompt;
   StringReplace(p, "|", ".");
   StringReplace(p, "\n", ".");

   string segments[];
   StringSplit(p, '.', segments);

   ENUM_SIGNAL currentIntent = SIGNAL_NONE;

   // Reset existing rules
   for(int i=0; i<20; i++) {
      rules_buy[i].Reset();
      rules_sell[i].Reset();
   }
   nRulesBuy = 0;
   nRulesSell = 0;

   for(int i=0; i<ArraySize(segments); i++) {
      string s = segments[i];
      StringReplace(s, ",", ".");
      StringToLower(s);

      // Detect Intent FIRST
      if(StringFind(s, "compra") >= 0) currentIntent = SIGNAL_BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SIGNAL_SELL;

      // Global Parameters
      if(StringFind(s, "stop de") >= 0) p_stopPoints = (int)ExtraiNumero(s, StringFind(s, "stop de"));
      if(StringFind(s, "take de") >= 0) p_takePoints = (int)ExtraiNumero(s, StringFind(s, "take de"));
      if(StringFind(s, "risco de") >= 0) p_risk = ExtraiNumero(s, StringFind(s, "risco de"));
      if(StringFind(s, "máximo") >= 0 && StringFind(s, "trades") >= 0) p_maxTrades = (int)ExtraiNumero(s, StringFind(s, "máximo"));

      // Breakeven
      if(StringFind(s, "move stop para entrada") >= 0 || StringFind(s, "breakeven") >= 0) {
         int targetPos = StringFind(s, "atingir");
         if(targetPos >= 0) p_breakeven = (int)ExtraiNumero(s, targetPos);
         int profitPos = StringFind(s, "entrada");
         if(profitPos >= 0) p_beProfit = (int)ExtraiNumero(s, profitPos);
      }

      // Trailing
      if(StringFind(s, "trailing") >= 0 || StringFind(s, "rastreio") >= 0) {
         p_trailingStop = (int)ExtraiNumero(s, StringFind(s, "trailing") >= 0 ? StringFind(s, "trailing") : StringFind(s, "rastreio"));
      }

      // Time restrictions
      if(StringFind(s, "depois das") >= 0 || StringFind(s, "após as") >= 0) {
         p_startHour = (int)ExtraiNumero(s, StringFind(s, "depois das") >= 0 ? StringFind(s, "depois das") : StringFind(s, "após as"));
      }

      // Martingale
      if(StringFind(s, "martingale") >= 0) p_martingale = true;

      // Detect Intent
      if(StringFind(s, "compra") >= 0) currentIntent = SIGNAL_BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SIGNAL_SELL;

      // Rules
      if(currentIntent != SIGNAL_NONE) {
         AddRuleSpecific(s, currentIntent);
      }

      // Frequency
      ENUM_TIMEFRAMES tf = PeriodoTexto(s);
      if(tf != PERIOD_CURRENT && StringFind(s, "cada") >= 0) p_frequency = tf;
   }
}

// --- SIGNAL ENGINE ---

double GetVal(int handle, int index=0) {
   double buffer[];
   ArraySetAsSeries(buffer, true);
   if(CopyBuffer(handle, 0, index, 1, buffer) > 0) return buffer[0];
   return 0;
}

bool AvaliaRegra(Rule &r) {
   if(!r.active || r.handle == INVALID_HANDLE) return false;

   double val1 = GetVal(r.handle, 1);
   double val2 = GetVal(r.handle, 2);

   if(r.type == 1) { // MA
      double price1 = iClose(_Symbol, r.tf, 1);
      double price2 = iClose(_Symbol, r.tf, 2);

      if(r.op == "cross_above") return (price2 <= val2 && price1 > val1);
      if(r.op == "cross_below") return (price2 >= val2 && price1 < val1);
      if(r.op == ">") return price1 > val1;
      if(r.op == "<") return price1 < val1;
   }

   if(r.type == 2) { // RSI
      if(r.op == ">") return val1 > r.d1;
      if(r.op == "<") return val1 < r.d1;
   }

   if(r.type == 9) { // 2-Bar Pattern
      double h0 = iHigh(_Symbol, r.tf, 0);
      double l0 = iLow(_Symbol, r.tf, 0);
      double h1 = iHigh(_Symbol, r.tf, 1);
      double l1 = iLow(_Symbol, r.tf, 1);
      bool isInside = (h0 < h1 && l0 > l1);
      bool isOutside = (h0 > h1 && l0 < l1);
      if(isInside || isOutside) {
         bool bullish = (iClose(_Symbol, r.tf, 0) > iOpen(_Symbol, r.tf, 0));
         return (r.intent == SIGNAL_BUY) ? bullish : !bullish;
      }
   }

   if(r.type == 10) { // Relative Strength
      double rsi1 = GetVal(r.handle, 0);
      double rsi2 = GetVal(r.handle2, 0);
      if(r.intent == SIGNAL_BUY) return (rsi1 > rsi2 + 5);
      if(r.intent == SIGNAL_SELL) return (rsi1 < rsi2 - 5);
   }

   return false;
}

int AIPredict() {
   int h = FileOpen("signal_ai.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string val = FileReadString(h);
      FileClose(h);
      if(val == "BUY") return 1;
      if(val == "SELL") return -1;
   }
   return 0;
}

ENUM_SIGNAL AvaliaTudo() {
   // Check BUY confluence
   bool buyMet = (nRulesBuy > 0);
   for(int i=0; i<nRulesBuy; i++) {
      if(!AvaliaRegra(rules_buy[i])) { buyMet = false; break; }
   }

   // Check SELL confluence
   bool sellMet = (nRulesSell > 0);
   for(int i=0; i<nRulesSell; i++) {
      if(!AvaliaRegra(rules_sell[i])) { sellMet = false; break; }
   }

   if(buyMet) return SIGNAL_BUY;
   if(sellMet) return SIGNAL_SELL;
   return SIGNAL_NONE;
}

// --- TRADE MANAGEMENT ---

double CalculaLote(double riskPercent) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAbs = balance * riskPercent / 100.0;

   // Martingale check
   if(p_martingale) {
      HistorySelect(0, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
            HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAbs *= 2;
            break;
         }
      }
   }

   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slPoints = (p_stopPoints > 0) ? p_stopPoints : 300; // Default if not set

   double lot = riskAbs / (slPoints * _Point * (tickVal / tickSize));

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void EnviaOrdem(ENUM_SIGNAL s) {
   if(s == SIGNAL_NONE) return;

   double price = (s == SIGNAL_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   if(s == SIGNAL_BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
   }

   double lot = CalculaLote(p_risk);

   for(int i=0; i<3; i++) { // Retry loop
      bool res = false;
      if(s == SIGNAL_BUY) res = trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor");
      else res = trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor");

      if(res && trade.ResultRetcode() == TRADE_RETCODE_DONE) {
         GravaLog("Ordem enviada com sucesso: " + EnumToString(s));
         // GravaEstadoCSV(...);
         break;
      }
      Sleep(100);
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) {
         double openPrice = posInfo.PriceOpen();
         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double sl = posInfo.StopLoss();

         double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (currentPrice - openPrice) / _Point : (openPrice - currentPrice) / _Point;

         // Breakeven
         if(p_breakeven > 0 && profitPoints >= p_breakeven) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_beProfit * _Point : openPrice - p_beProfit * _Point;
            if((posInfo.PositionType() == POSITION_TYPE_BUY && sl < newSL) || (posInfo.PositionType() == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
               GravaLog("Breakeven acionado.");
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStop * _Point : currentPrice + p_trailingStop * _Point;
            if((posInfo.PositionType() == POSITION_TYPE_BUY && sl < newSL) || (posInfo.PositionType() == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

// --- UTILITIES & HANDLERS ---

void GravaLog(string texto) {
   Print(texto);
   SendNotification("MT-LiveExecutor: " + texto);
}

void CalculaStats() {
   // Simulated performance tracking
   Print("Updating stats...");
}

bool AguardaNoticias() {
   // Read calendar.txt from common files
   int handle = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      // Logic to check veto period
      FileClose(handle);
   }
   return false;
}

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(3600); // Hourly stats
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   CalculaStats();
   for(int i=0; i<20; i++) {
      rules_buy[i].Reset();
      rules_sell[i].Reset();
   }
}

void OnTimer() {
   CalculaStats();
}

void OnTick() {
   // Real-time logic update
   if(FileIsExist("prompt.txt", FILE_COMMON)) {
      int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(h != INVALID_HANDLE) {
         string p = FileReadString(h);
         FileClose(h);
         FileDelete("prompt.txt", FILE_COMMON);
         InterpretaPrompt(p);
         GravaLog("Nova estratégia carregada: " + p);
      }
   }

   // Time check
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < p_startHour) return;

   // News check
   if(AguardaNoticias()) return;

   // Frequency check
   datetime current_bar = iTime(_Symbol, p_frequency, 0);
   if(current_bar != last_bar) {
      last_bar = current_bar;

      // Position Count
      int count = 0;
      for(int i=PositionsTotal()-1; i>=0; i--) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) count++;
      }

      if(count < p_maxTrades) {
         ENUM_SIGNAL s = AvaliaTudo();
         int ai = AIPredict();
         if(ai == 1 && s == SIGNAL_NONE) s = SIGNAL_BUY;
         else if(ai == -1 && s == SIGNAL_NONE) s = SIGNAL_SELL;

         EnviaOrdem(s);
      }
   }

   GerenciaPosicoes();
}

void GravaEstadoCSV(ulong ticket, double price, double sl, double tp, string motive) {
   int h = FileOpen("states.csv", FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ',');
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, ticket, price, sl, tp, TimeToString(TimeCurrent()), motive);
      FileClose(h);
   }
}
