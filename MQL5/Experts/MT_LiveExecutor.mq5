//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Integrated AI-driven strategy executor
//========================================================================

#property copyright "Copyright 2024, Jules"
#property link      "https://github.com/jules"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Constants ---
#define EA_MAGIC 123456

// --- Enums ---
enum Signal {BUY=1, SELL=-1, NONE=0};

// --- Structs ---
struct Rule {
   int      type;       // 1: MA, 2: RSI, 3: Stoch, etc.
   Signal   intent;     // BUY or SELL
   int      tf;         // Timeframe
   int      p1, p2, p3; // Parameters
   double   d1, d2;     // Thresholds
   string   s1;         // Bench symbol or extra text
   int      handle1, handle2;

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      type = 0;
      intent = NONE;
      tf = 0;
      p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0;
      s1 = "";
      handle1 = INVALID_HANDLE;
      handle2 = INVALID_HANDLE;
   }
};

// --- Globals ---
Rule     g_rules[20];
int      g_nRules = 0;
CTrade   g_trade;
string   g_lastPrompt = "";
datetime g_lastPromptTime = 0;

// Parameters parsed from prompt
bool     p_useMartingale = false;
double   p_riskPercent = 1.0;
int      p_stopLoss = 300;     // Points
int      p_takeProfit = 500;   // Points
int      p_maxTrades = 3;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
string   p_startTime = "00:00";
int      p_newsVeto = 20;      // Minutes

// State management
datetime g_lastTickTime = 0;
datetime g_lastBarTime = 0;
datetime g_lastAI = 0;

// --- NLP Parser Functions ---

double ExtraiNumero(string txt, int &cursor) {
   string res = "";
   bool found = false;
   for(int i = cursor; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         if(c == ',') c = '.';
         res += ShortToString(c);
         found = true;
      } else if(found) {
         cursor = i;
         return StringToDouble(res);
      }
   }
   cursor = StringLen(txt);
   return StringToDouble(res);
}

int PeriodoTexto(string txt) {
   string work = txt;
   StringToLower(work);
   if(StringFind(work, "m1") >= 0 && StringFind(work, "m15") < 0) return PERIOD_M1;
   if(StringFind(work, "m5") >= 0 && StringFind(work, "m15") < 0) return PERIOD_M5;
   if(StringFind(work, "m15") >= 0) return PERIOD_M15;
   if(StringFind(work, "m30") >= 0) return PERIOD_M30;
   if(StringFind(work, "h1") >= 0) return PERIOD_H1;
   if(StringFind(work, "h4") >= 0) return PERIOD_H4;
   if(StringFind(work, "d1") >= 0) return PERIOD_D1;
   if(StringFind(work, "minutos") >= 0 || StringFind(work, "min") >= 0) {
      int c = 0;
      int n = (int)ExtraiNumero(work, c);
      if(n == 1) return PERIOD_M1;
      if(n == 5) return PERIOD_M5;
      if(n == 15) return PERIOD_M15;
      if(n == 30) return PERIOD_M30;
   }
   return PERIOD_CURRENT;
}

void ResetStrategy() {
   for(int i = 0; i < 20; i++) g_rules[i].Reset();
   g_nRules = 0;
   p_riskPercent = 1.0;
   p_stopLoss = 300;
   p_takeProfit = 500;
   p_maxTrades = 3;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStop = 0;
   p_trailingStep = 0;
}

void AddRule(string segment, Signal currentIntent) {
   if(g_nRules >= 20) return;
   string txt = segment;
   StringToLower(txt);

   Rule r;
   r.Reset();
   r.intent = currentIntent;
   r.tf = (int)p_frequency;

   // 1. Moving Average
   if(StringFind(txt, "média") >= 0 || StringFind(txt, "ma") >= 0) {
      r.type = 1;
      int c = StringFind(txt, "média");
      if(c < 0) c = StringFind(txt, "ma");
      c += 5;
      r.p1 = (int)ExtraiNumero(txt, c);
      if(r.p1 == 0) r.p1 = 20;
      r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) {
         g_rules[g_nRules] = r;
         g_nRules++;
      }
   }

   // 2. RSI
   if(StringFind(txt, "rsi") >= 0) {
      r.Reset();
      r.intent = currentIntent;
      r.type = 2;
      r.tf = (int)p_frequency;
      int c = StringFind(txt, "rsi") + 3;
      double n1 = ExtraiNumero(txt, c);
      double n2 = ExtraiNumero(txt, c);
      if(n2 == 0) {
         if(n1 >= 40) { r.p1 = 14; r.d1 = n1; }
         else { r.p1 = (int)n1; r.d1 = (currentIntent == BUY) ? 30 : 70; }
      } else {
         r.p1 = (int)n1;
         r.d1 = n2;
      }
      r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) {
         g_rules[g_nRules] = r;
         g_nRules++;
      }
   }

   // 3. Stochastic
   if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
      r.Reset();
      r.intent = currentIntent;
      r.type = 3;
      r.tf = (int)p_frequency;
      r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
      if(r.handle1 != INVALID_HANDLE) {
         g_rules[g_nRules] = r;
         g_nRules++;
      }
   }

   // 4. Bollinger Bands
   if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bb") >= 0) {
      r.Reset();
      r.intent = currentIntent;
      r.type = 4;
      r.tf = (int)p_frequency;
      r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
      if(r.handle1 != INVALID_HANDLE) {
         g_rules[g_nRules] = r;
         g_nRules++;
      }
   }
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string work = prompt;
   StringReplace(work, " e ", ".");
   StringReplace(work, ";", ".");
   string segments[];
   StringSplit(work, '.', segments);

   Signal currentIntent = NONE;
   for(int i = 0; i < ArraySize(segments); i++) {
      string s = segments[i];
      StringToLower(s);

      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      // Global parameters
      int c = 0;
      if(StringFind(s, "stop") >= 0) {
         c = StringFind(s, "stop") + 4;
         p_stopLoss = (int)ExtraiNumero(s, c);
      }
      if(StringFind(s, "take") >= 0) {
         c = StringFind(s, "take") + 4;
         p_takeProfit = (int)ExtraiNumero(s, c);
      }
      if(StringFind(s, "risco") >= 0) {
         c = StringFind(s, "risco") + 5;
         p_riskPercent = ExtraiNumero(s, c);
      }
      if(StringFind(s, "máximo") >= 0) {
         c = StringFind(s, "máximo") + 6;
         p_maxTrades = (int)ExtraiNumero(s, c);
      }
      if(StringFind(s, "atingir") >= 0) {
         c = StringFind(s, "atingir") + 7;
         p_beStart = (int)ExtraiNumero(s, c);
      }
      if(StringFind(s, "entrada +") >= 0) {
         c = StringFind(s, "entrada +") + 9;
         p_bePlus = (int)ExtraiNumero(s, c);
      }
      if(StringFind(s, "cada") >= 0) {
         p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(s);
      }
      if(StringFind(s, "depois das") >= 0 || StringFind(s, "início") >= 0) {
         c = StringFind(s, "depois das") >= 0 ? StringFind(s, "depois das") + 10 : StringFind(s, "início") + 6;
         // Extract time HH:MM
         string t = "";
         for(int j = c; j < StringLen(s); j++) {
            ushort chr = StringGetCharacter(s, j);
            if((chr >= '0' && chr <= '9') || chr == ':' || chr == 'h') {
               if(chr == 'h') chr = ':';
               t += ShortToString(chr);
            } else if(t != "") break;
         }
         if(StringLen(t) > 0) {
            if(StringFind(t, ":") < 0) t += ":00";
            p_startTime = t;
         }
      }
      if(StringFind(s, "notícias") >= 0) {
         c = StringFind(s, "notícias") - 10;
         if(c < 0) c = 0;
         p_newsVeto = (int)ExtraiNumero(s, c);
         if(p_newsVeto == 0) p_newsVeto = 20;
      }
      if(StringFind(s, "martingale") >= 0) {
         p_useMartingale = true;
      }

      if(currentIntent != NONE) {
         AddRule(s, currentIntent);
      }
   }
   GravaLog("Estratégia interpretada. Regras: " + IntegerToString(g_nRules));
}

// --- Signal Evaluation Functions ---

double GetBufferValue(int handle, int buffer, int shift) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

bool AvaliaRegra(Rule &r) {
   if(r.handle1 == INVALID_HANDLE) return false;

   // 1. Moving Average Crossover
   if(r.type == 1) {
      double ma1 = GetBufferValue(r.handle1, 0, 1);
      double ma2 = GetBufferValue(r.handle1, 0, 2);
      double c1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double c2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);

      if(r.intent == BUY) return (c2 < ma2 && c1 > ma1);
      if(r.intent == SELL) return (c2 > ma2 && c1 < ma1);
   }

   // 2. RSI
   if(r.type == 2) {
      double rsi1 = GetBufferValue(r.handle1, 0, 1);
      double rsi2 = GetBufferValue(r.handle1, 0, 2);

      if(r.intent == BUY) return (rsi2 < r.d1 && rsi1 > r.d1);
      if(r.intent == SELL) return (rsi2 > r.d1 && rsi1 < r.d1);
   }

   // 3. Stochastic
   if(r.type == 3) {
      double k1 = GetBufferValue(r.handle1, 0, 1);
      double d1 = GetBufferValue(r.handle1, 1, 1);
      double k2 = GetBufferValue(r.handle1, 0, 2);
      double d2 = GetBufferValue(r.handle1, 1, 2);

      if(r.intent == BUY) return (k2 < d2 && k1 > d1);
      if(r.intent == SELL) return (k2 > d2 && k1 < d1);
   }

   // 4. Bollinger Bands
   if(r.type == 4) {
      double upper = GetBufferValue(r.handle1, 1, 1);
      double lower = GetBufferValue(r.handle1, 2, 1);
      double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);

      if(r.intent == BUY) return (close < lower);
      if(r.intent == SELL) return (close > upper);
   }

   return false;
}

Signal AvaliaTudo() {
   int buyConfirmations = 0;
   int sellConfirmations = 0;
   int buyRules = 0;
   int sellRules = 0;

   for(int i = 0; i < g_nRules; i++) {
      if(g_rules[i].intent == BUY) {
         buyRules++;
         if(AvaliaRegra(g_rules[i])) buyConfirmations++;
      } else if(g_rules[i].intent == SELL) {
         sellRules++;
         if(AvaliaRegra(g_rules[i])) sellConfirmations++;
      }
   }

   if(buyRules > 0 && buyConfirmations == buyRules) return BUY;
   if(sellRules > 0 && sellConfirmations == sellRules) return SELL;

   return NONE;
}

// --- Trade and Management Functions ---

void GravaLog(string texto) {
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE|FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWrite(h, TimeToString(TimeCurrent()) + ": " + texto);
      FileClose(h);
   }
   Print(texto);
}

void GravaCSV() {
   static datetime lastCSV = 0;
   if(TimeCurrent() - lastCSV < 5) return;
   lastCSV = TimeCurrent();

   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket;Symbol;Type;Profit;SL;TP");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
               FileWrite(h, IntegerToString(PositionGetInteger(POSITION_TICKET)) + ";" +
                          PositionGetString(POSITION_SYMBOL) + ";" +
                          IntegerToString(PositionGetInteger(POSITION_TYPE)) + ";" +
                          DoubleToString(PositionGetDouble(POSITION_PROFIT), 2) + ";" +
                          DoubleToString(PositionGetDouble(POSITION_SL), 5) + ";" +
                          DoubleToString(PositionGetDouble(POSITION_TP), 5));
            }
         }
      }
      FileClose(h);
   }
}

double CalculaLote(double riscoPercent) {
   double actualRisk = riscoPercent;

   if(p_useMartingale) {
      HistorySelect(TimeCurrent() - 86400 * 7, TimeCurrent());
      int total = HistoryDealsTotal();
      if(total > 0) {
         ulong ticket = HistoryDealGetTicket(total - 1);
         if(HistoryDealSelect(ticket)) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) {
               actualRisk *= 2.0;
            }
         }
      }
   }

   double balance = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount = balance * (actualRisk / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopLoss == 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   // A cada tick de variação (tickSize), ganhamos/perdemos tickValue por lote.
   // Variamos p_stopLoss * _Point. Quantos tickSizes cabem nisso? (p_stopLoss * _Point / tickSize)
   // Então a perda por lote é: (p_stopLoss * _Point / tickSize) * tickValue
   double lot = riskAmount / ((p_stopLoss * _Point / tickSize) * tickValue);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / stepLot) * stepLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

bool AguardaNoticias() {
   // 1. Check for manual veto flag
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string content = FileReadString(h);
      FileClose(h);
      if(StringFind(content, "VETO=1") >= 0) return true;
   }

   // 2. Check calendar for high-impact events
   h = FileOpen("calendar.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      while(!FileIsEnding(h)) {
         string line = FileReadString(h);
         if(StringFind(line, "High") >= 0 || StringFind(line, "Alto") >= 0) {
            // Assume format: YYYY.MM.DD HH:MM;Event;Impact
            string parts[];
            StringSplit(line, ';', parts);
            if(ArraySize(parts) >= 1) {
               datetime newsTime = StringToTime(parts[0]);
               long diff = MathAbs((long)TimeCurrent() - (long)newsTime);
               if(diff <= p_newsVeto * 60) {
                  FileClose(h);
                  return true;
               }
            }
         }
      }
      FileClose(h);
   }
   return false;
}

bool IsTimeAllowed() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string now = StringFormat("%02d:%02d", dt.hour, dt.min);
   return (now >= p_startTime);
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) return;
   if(!IsTimeAllowed()) return;

   double lot = CalculaLote(p_riskPercent);
   double sl = 0, tp = 0;
   double price = 0;

   if(s == BUY) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(p_stopLoss > 0) sl = price - p_stopLoss * _Point;
      if(p_takeProfit > 0) tp = price + p_takeProfit * _Point;

      for(int i=0; i<3; i++) {
         if(g_trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor Entry")) {
            GravaLog("Compra executada: " + DoubleToString(lot, 2) + " SL:" + DoubleToString(sl, 5) + " TP:" + DoubleToString(tp, 5));
            SendNotification("MT-LiveExecutor: Compra em " + _Symbol);
            break;
         }
         if(g_trade.ResultRetcode() == TRADE_RETCODE_REQUOTES || g_trade.ResultRetcode() == TRADE_RETCODE_OFFQUOTES) {
            price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            continue;
         } else break;
      }
   } else if(s == SELL) {
      price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(p_stopLoss > 0) sl = price + p_stopLoss * _Point;
      if(p_takeProfit > 0) tp = price - p_takeProfit * _Point;

      for(int i=0; i<3; i++) {
         if(g_trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor Entry")) {
            GravaLog("Venda executada: " + DoubleToString(lot, 2) + " SL:" + DoubleToString(sl, 5) + " TP:" + DoubleToString(tp, 5));
            SendNotification("MT-LiveExecutor: Venda em " + _Symbol);
            break;
         }
         if(g_trade.ResultRetcode() == TRADE_RETCODE_REQUOTES || g_trade.ResultRetcode() == TRADE_RETCODE_OFFQUOTES) {
            price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            continue;
         } else break;
      }
   }
}

void GerenciaPosicoes() {
   for(int i = 0; i < PositionsTotal(); i++) {
      if(PositionSelectByTicket(PositionGetTicket(i))) {
         if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
            double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                                  (SymbolInfoDouble(_Symbol, SYMBOL_BID) - PositionGetDouble(POSITION_PRICE_OPEN)) / _Point :
                                  (PositionGetDouble(POSITION_PRICE_OPEN) - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) / _Point;

            // Break-even
            if(p_beStart > 0 && profitPoints >= p_beStart) {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                              PositionGetDouble(POSITION_PRICE_OPEN) + p_bePlus * _Point :
                              PositionGetDouble(POSITION_PRICE_OPEN) - p_bePlus * _Point;

               if(PositionGetDouble(POSITION_SL) != newSL) {
                  g_trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, PositionGetDouble(POSITION_TP));
               }
            }

            // Trailing Stop
            if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
               double newSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                              SymbolInfoDouble(_Symbol, SYMBOL_BID) - p_trailingStop * _Point :
                              SymbolInfoDouble(_Symbol, SYMBOL_ASK) + p_trailingStop * _Point;

               if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                  if(newSL > PositionGetDouble(POSITION_SL) + p_trailingStep * _Point)
                     g_trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, PositionGetDouble(POSITION_TP));
               } else {
                  if(newSL < PositionGetDouble(POSITION_SL) - p_trailingStep * _Point || PositionGetDouble(POSITION_SL) == 0)
                     g_trade.PositionModify(PositionGetInteger(POSITION_TICKET), newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}

// --- MQL5 Handlers ---

int OnInit() {
   g_trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

void OnTimer() {
   // Check for new prompt
   int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(h != INVALID_HANDLE) {
      string prompt = FileReadString(h);
      FileClose(h);
      if(prompt != g_lastPrompt) {
         g_lastPrompt = prompt;
         InterpretaPrompt(prompt);
      }
   }

   // AI Optimizer (Hourly)
   if(TimeCurrent() - g_lastAI > 3600) {
      g_lastAI = TimeCurrent();
      HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent());
      int total = HistoryDealsTotal();
      int win = 0, count = 0;
      for(int i = total - 1; i >= 0 && count < 10; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealSelect(ticket)) {
            if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
               if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) win++;
               count++;
            }
         }
      }
      if(count >= 5) {
         double winRate = (double)win / count;
         if(winRate < 0.4) {
            p_riskPercent *= 0.8; // Reduce risk if win rate is low
            GravaLog("AI Optimizer: Risco reduzido para " + DoubleToString(p_riskPercent, 2) + "% devido a win rate de " + DoubleToString(winRate * 100, 1) + "%");
         }
      }
   }
}

void OnTick() {
   GerenciaPosicoes();
   GravaCSV();

   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != g_lastBarTime) {
      g_lastBarTime = currentBar;
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
   }
}
