//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Procedural MQL5 Implementation
//========================================================================

#property copyright "Copyright 2024, MT-LiveExecutor"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- DEFINES ---
#define EA_MAGIC 123456

// --- ENUMS ---
enum Signal { BUY=1, SELL=-1, NONE=0 };

// --- STRUCTS ---
struct Rule {
   bool     active;
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Volume, 8: AMA, 9: Pattern, 10: RS
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      intent;     // 1: BUY, -1: SELL
   int      handle;
   string   op;         // Relational operator: ">", "<", "ca" (cross above), "cb" (cross below)

   void Reset() {
      if(handle != INVALID_HANDLE && handle != 0) IndicatorRelease(handle);
      active = false; type = 0; tf = 0; p1 = 0; p2 = 0; p3 = 0;
      d1 = 0; d2 = 0; s1 = ""; intent = 0; handle = INVALID_HANDLE;
      op = "";
   }
};

// --- GLOBALS ---
Rule     buyRules[20];
Rule     sellRules[20];
int      nBuyRules = 0;
int      nSellRules = 0;

// Strategy Parameters
double   p_risk = 1.0;
int      p_sl = 0;
int      p_tp = 0;
int      p_maxTrades = 3;
int      p_startHour = 0;
int      p_breakeven = 0;
int      p_breakevenStep = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;
bool     p_martingale = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

CTrade trade;

// --- EVENT HANDLERS ---
int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1); // Check prompt every second

   // Initial prompt check
   string initialPrompt = "compra se rsi 14 < 30. venda se rsi 14 > 70. stop de 300. take de 500. risco 1.0";
   InterpretaPrompt(initialPrompt);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   ResetStrategy();
   CalculaStats();
}

void OnTick() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < p_startHour) return;

   static datetime lastBar = 0;
   datetime currBar = iTime(_Symbol, p_frequency, 0);

   if(currBar != lastBar) {
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
      lastBar = currBar;
   }

   GerenciaPosicoes();
}

void OnTimer() {
   // File monitoring for real-time updates
   string filename = "prompt.txt";
   if(FileIsExist(filename, FILE_COMMON)) {
      int handle = FileOpen(filename, FILE_READ|FILE_TXT|FILE_COMMON);
      if(handle != INVALID_HANDLE) {
         string content = FileReadString(handle);
         FileClose(handle);
         FileDelete(filename, FILE_COMMON);
         if(StringLen(content) > 0) {
            InterpretaPrompt(content);
            GravaLog("Estratégia atualizada via prompt.txt");
         }
      }
   }

   // Periodic AI optimization
   static int aiCounter = 0;
   aiCounter++;
   if(aiCounter >= 3600) {
      AIOptimizer();
      CalculaStats();
      aiCounter = 0;
   }
}

// --- UTILS ---
double ExtraiNumero(string txt, int &cursor) {
   string s = "";
   bool found = false;
   int len = StringLen(txt);
   while(cursor < len) {
      ushort c = StringGetCharacter(txt, cursor);
      if((c >= '0' && c <= '9') || c == '.') {
         s += CharToString((uchar)c);
         found = true;
      } else if(found) break;
      cursor++;
   }
   return StringToDouble(s);
}

int PeriodoTexto(string nome) {
   StringLower(nome);
   if(StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if(StringFind(nome, "h4") >= 0)  return PERIOD_H4;
   if(StringFind(nome, "d1") >= 0)  return PERIOD_D1;
   if(StringFind(nome, "minutos") >= 0 || StringFind(nome, "min") >= 0) {
      int c = 0; double n = ExtraiNumero(nome, c);
      if(n == 1) return PERIOD_M1;
      if(n == 5) return PERIOD_M5;
      if(n == 15) return PERIOD_M15;
      if(n == 30) return PERIOD_M30;
   }
   return PERIOD_CURRENT;
}

void ResetStrategy() {
   for(int i=0; i<20; i++) {
      buyRules[i].Reset();
      sellRules[i].Reset();
   }
   nBuyRules = 0;
   nSellRules = 0;
}

void AddRule(string txt, int intent) {
   StringLower(txt);
   int n = 0;
   if(intent == 1) {
      if(nBuyRules >= 20) return;
      n = nBuyRules; nBuyRules++;
   }
   else {
      if(nSellRules >= 20) return;
      n = nSellRules; nSellRules++;
   }

   Rule r; r.Reset();
   r.active = true;
   r.intent = intent;
   r.tf = PeriodoTexto(txt);

   if(StringFind(txt, "média") >= 0 || StringFind(txt, "media") >= 0 || StringFind(txt, "ma") >= 0) {
      r.type = 1;
      int c = StringFind(txt, "períodos");
      if(c < 0) c = StringFind(txt, "periodos");
      if(c < 0) c = 0; else c -= 5;
      r.p1 = (int)ExtraiNumero(txt, c);
      if(r.p1 == 0) r.p1 = 20;
      if(StringFind(txt, "cruzar acima") >= 0 || StringFind(txt, "acima") >= 0) r.op = "ca";
      else r.op = "cb";
      r.handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
   }
   else if(StringFind(txt, "rsi") >= 0) {
      r.type = 2;
      int c = StringFind(txt, "rsi") + 3;
      r.p1 = (int)ExtraiNumero(txt, c);
      if(r.p1 == 0) r.p1 = 14;
      if(StringFind(txt, "acima") >= 0 || StringFind(txt, "subir") >= 0 || StringFind(txt, ">") >= 0) {
         r.op = ">";
         int c2 = StringFind(txt, "acima"); if(c2<0) c2=StringFind(txt, "subir"); if(c2<0) c2=StringFind(txt, ">");
         c2 += 5; r.d1 = ExtraiNumero(txt, c2);
      } else {
         r.op = "<";
         int c2 = StringFind(txt, "abaixo"); if(c2<0) c2=StringFind(txt, "cair"); if(c2<0) c2=StringFind(txt, "<");
         c2 += 6; r.d1 = ExtraiNumero(txt, c2);
      }
      r.handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
   }
   else if(StringFind(txt, "estocástico") >= 0 || StringFind(txt, "stoch") >= 0) {
      r.type = 3;
      int c = StringFind(txt, "stoch"); if(c<0) c=StringFind(txt, "estocástico");
      c += 5; r.p1 = (int)ExtraiNumero(txt, c); if(r.p1==0) r.p1=5;
      r.p2 = (int)ExtraiNumero(txt, c); if(r.p2==0) r.p2=3;
      r.p3 = (int)ExtraiNumero(txt, c); if(r.p3==0) r.p3=3;
      if(StringFind(txt, "cruzar") >= 0) r.op = "ca"; else r.op = ">";
      r.handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
   }
   else if(StringFind(txt, "bollinger") >= 0 || StringFind(txt, "bb") >= 0) {
      r.type = 4;
      int c = StringFind(txt, "bb"); if(c<0) c=StringFind(txt, "bollinger");
      c += 2; r.p1 = (int)ExtraiNumero(txt, c); if(r.p1==0) r.p1=20;
      r.d1 = ExtraiNumero(txt, c); if(r.d1==0) r.d1=2.0;
      r.handle = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
   }
   else if(StringFind(txt, "breakout") >= 0) {
      r.type = 5;
   }
   else if(StringFind(txt, "delta") >= 0 || StringFind(txt, "agressão") >= 0) {
      r.type = 6;
      int c = StringFind(txt, "delta"); if(c<0) c=StringFind(txt, "agressão");
      c += 5; r.p1 = (int)ExtraiNumero(txt, c); if(r.p1==0) r.p1=300;
   }
   else if(StringFind(txt, "volume") >= 0) {
      r.type = 7;
      int c = StringFind(txt, "volume") + 6;
      r.p1 = (int)ExtraiNumero(txt, c); if(r.p1==0) r.p1=12;
   }
   else if(StringFind(txt, "ama") >= 0) {
      r.type = 8;
      int c = StringFind(txt, "ama") + 3;
      r.p1 = (int)ExtraiNumero(txt, c); if(r.p1==0) r.p1=10;
      r.handle = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 2, 30, 0, PRICE_CLOSE);
   }
   else if(StringFind(txt, "padrão") >= 0 || StringFind(txt, "barra") >= 0 || StringFind(txt, "pattern") >= 0) {
      r.type = 9;
   }
   else if(StringFind(txt, "força relativa") >= 0 || StringFind(txt, "rs") >= 0) {
      r.type = 10;
      int c = StringFind(txt, "rs") + 2;
      r.s1 = "US30"; // Default benchmark
   }

   if(intent == 1) buyRules[n] = r;
   else sellRules[n] = r;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   StringLower(prompt);
   string segments[];
   StringReplace(prompt, "|", ".");
   StringReplace(prompt, "\n", ".");
   int n = StringSplit(prompt, '.', segments);

   int currentIntent = 0;
   for(int i=0; i<n; i++) {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = 1;
      else if(StringFind(s, "venda") >= 0) currentIntent = -1;

      if(currentIntent != 0) {
         if(StringFind(s, "média") >= 0 || StringFind(s, "rsi") >= 0 || StringFind(s, "stoch") >= 0 ||
            StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0 || StringFind(s, "breakout") >= 0 ||
            StringFind(s, "delta") >= 0 || StringFind(s, "volume") >= 0 || StringFind(s, "ama") >= 0 ||
            StringFind(s, "padrão") >= 0 || StringFind(s, "barra") >= 0 || StringFind(s, "pattern") >= 0 ||
            StringFind(s, "rs") >= 0) {
            AddRule(s, currentIntent);
         }
      }

      // Global parameters
      int c = 0;
      if(StringFind(s, "risco") >= 0) {
         c = StringFind(s, "risco"); p_risk = ExtraiNumero(s, c);
      }
      if(StringFind(s, "stop de") >= 0 || StringFind(s, "stop loss") >= 0) {
         c = (StringFind(s, "stop de") >= 0) ? StringFind(s, "stop de") : StringFind(s, "stop loss");
         p_sl = (int)ExtraiNumero(s, c);
      }
      if(StringFind(s, "take de") >= 0 || StringFind(s, "take profit") >= 0) {
         c = (StringFind(s, "take de") >= 0) ? StringFind(s, "take de") : StringFind(s, "take profit");
         p_tp = (int)ExtraiNumero(s, c);
      }
      if(StringFind(s, "máximo") >= 0 && StringFind(s, "trades") >= 0) {
         c = StringFind(s, "máximo"); p_maxTrades = (int)ExtraiNumero(s, c);
      }
      if(StringFind(s, "depois das") >= 0 || StringFind(s, "após as") >= 0) {
         c = (StringFind(s, "depois das") >= 0) ? StringFind(s, "depois das") : StringFind(s, "após as");
         p_startHour = (int)ExtraiNumero(s, c);
      }
      if(StringFind(s, "breakeven") >= 0 || StringFind(s, "move stop para entrada") >= 0 || StringFind(s, "ao atingir") >= 0) {
         if(StringFind(s, "ao atingir") >= 0) {
            int c2 = StringFind(s, "ao atingir");
            p_breakeven = (int)ExtraiNumero(s, c2);
            if(StringFind(s, "entrada") >= 0) {
               int c3 = StringFind(s, "entrada");
               p_breakevenStep = (int)ExtraiNumero(s, c3);
            }
         } else {
            c = (StringFind(s, "breakeven") >= 0) ? StringFind(s, "breakeven") : StringFind(s, "move stop para entrada");
            p_breakeven = (int)ExtraiNumero(s, c);
            if(StringFind(s, "+") >= 0) {
               int c2 = StringFind(s, "+"); p_breakevenStep = (int)ExtraiNumero(s, c2);
            }
         }
      }
      if(StringFind(s, "trailing") >= 0 || StringFind(s, "rastreio") >= 0) {
         c = (StringFind(s, "trailing") >= 0) ? StringFind(s, "trailing") : StringFind(s, "rastreio");
         p_trailingStop = (int)ExtraiNumero(s, c);
         p_trailingStep = (int)ExtraiNumero(s, c);
      }
      if(StringFind(s, "martingale") >= 0) p_martingale = true;
      if(StringFind(s, "a cada") >= 0) {
         c = StringFind(s, "a cada"); p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(s);
      }
   }
}

// --- SIGNAL ENGINE ---
double GetBufferValue(int handle, int buffer, int shift) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

bool AvaliaRegra(Rule &r) {
   if(!r.active) return false;
   double v1=0, v2=0, p1=0, p2=0;

   switch(r.type) {
      case 1: // MA
         v1 = GetBufferValue(r.handle, 0, 1);
         p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         if(r.op == "ca") {
            v2 = GetBufferValue(r.handle, 0, 2);
            p2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            return (p2 <= v2 && p1 > v1);
         } else {
            v2 = GetBufferValue(r.handle, 0, 2);
            p2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
            return (p2 >= v2 && p1 < v1);
         }
      case 2: // RSI
         v1 = GetBufferValue(r.handle, 0, 1);
         if(r.op == ">") return (v1 > r.d1);
         else return (v1 < r.d1);
      case 3: // Stoch
         v1 = GetBufferValue(r.handle, 0, 1); // Main
         v2 = GetBufferValue(r.handle, 1, 1); // Signal
         if(r.op == "ca") return (GetBufferValue(r.handle,0,2) <= GetBufferValue(r.handle,1,2) && v1 > v2);
         else return (v1 > r.d1);
      case 4: // BB
         v1 = GetBufferValue(r.handle, 1, 1); // Upper
         v2 = GetBufferValue(r.handle, 2, 1); // Lower
         p1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         if(r.intent == 1) return (p1 < v2);
         else return (p1 > v1);
      case 5: // Daily Breakout
         v1 = iHigh(_Symbol, PERIOD_D1, 1);
         v2 = iLow(_Symbol, PERIOD_D1, 1);
         p1 = iClose(_Symbol, PERIOD_CURRENT, 0);
         if(r.intent == 1) return (p1 > v1);
         else return (p1 < v2);
      case 6: // Delta
         return false; // Placeholder
      case 7: // Volume
         return false; // Placeholder
      case 8: // AMA
         v1 = GetBufferValue(r.handle, 0, 1);
         v2 = GetBufferValue(r.handle, 0, 2);
         if(r.intent == 1) return (v1 > v2);
         else return (v1 < v2);
      case 9: // Pattern
         p1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         p2 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
         double h2 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         double l2 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);
         if(p1 < h2 && p2 > l2) return true; // Inside Bar
         return false;
      case 10: // RS
         return false; // Placeholder
   }
   return false;
}

Signal AvaliaTudo() {
   if(nBuyRules > 0) {
      bool all = true;
      for(int i=0; i<nBuyRules; i++) if(!AvaliaRegra(buyRules[i])) { all = false; break; }
      if(all) return BUY;
   }
   if(nSellRules > 0) {
      bool all = true;
      for(int i=0; i<nSellRules; i++) if(!AvaliaRegra(sellRules[i])) { all = false; break; }
      if(all) return SELL;
   }
   return NONE;
}
// --- TRADE EXECUTION ---
void GravaLog(string texto) {
   Print(texto);
   SendNotification(texto);
}

void CalculaStats() {
   int total = 0, wins = 0;
   double profit = 0, loss = 0;

   HistorySelect(0, TimeCurrent());
   int deals = HistoryDealsTotal();

   for(int i=0; i<deals; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(p != 0) {
            total++;
            if(p > 0) { wins++; profit += p; }
            else { loss -= p; }
         }
      }
   }

   double winRate = (total > 0) ? (double)wins / total * 100 : 0;
   double pf = (loss > 0) ? profit / loss : profit;

   string res = StringFormat("Stats: Trades: %d | WinRate: %.1f%% | PF: %.2f", total, winRate, pf);
   GravaLog(res);
}

bool AguardaNoticias() {
   string filename = "calendar.txt";
   if(!FileIsExist(filename, FILE_COMMON)) return false;

   int handle = FileOpen(filename, FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle == INVALID_HANDLE) return false;

   datetime now = TimeCurrent();
   bool veto = false;

   while(!FileIsEnding(handle)) {
      string line = FileReadString(handle);
      if(StringLen(line) < 16) continue;

      // Expected format: YYYY.MM.DD HH:MM;Symbol;Impact;Title
      string parts[];
      if(StringSplit(line, ';', parts) < 3) continue;

      datetime newsTime = StringToTime(parts[0]);
      if(newsTime == 0) continue;

      if(parts[2] == "High" || parts[2] == "Alto") {
         if(MathAbs(now - newsTime) < 1200) { // 20 min = 1200 sec
            veto = true;
            break;
         }
      }
   }
   FileClose(handle);

   if(veto) GravaLog("Veto por notícia de alto impacto.");
   return veto;
}

double CalculaLote(double riskPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAbs = capital * riskPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double slPoints = p_sl > 0 ? p_sl : 300;
   double lot = riskAbs / (slPoints * _Point * (tickVal / tickSize));

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / step) * step;
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(lot < minLot) lot = minLot;
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void EnviaOrdem(Signal s) {
   if(s == NONE) return;
   if(AguardaNoticias()) return;

   int openTrades = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) openTrades++;
   }
   if(openTrades >= p_maxTrades) return;

   double lote = CalculaLote(p_risk);
   double sl = 0, tp = 0;
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(s == BUY) {
      if(p_sl > 0) sl = price - p_sl * _Point;
      if(p_tp > 0) tp = price + p_tp * _Point;
      if(!trade.Buy(lote, _Symbol, price, sl, tp)) {
         GravaLog(StringFormat("Erro na Compra: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
      } else {
         GravaLog("Compra executada com sucesso.");
      }
   } else {
      if(p_sl > 0) sl = price + p_sl * _Point;
      if(p_tp > 0) tp = price - p_tp * _Point;
      if(!trade.Sell(lote, _Symbol, price, sl, tp)) {
         GravaLog(StringFormat("Erro na Venda: %d - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
      } else {
         GravaLog("Venda executada com sucesso.");
      }
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
         long type = PositionGetInteger(POSITION_TYPE);
         double sl = PositionGetDouble(POSITION_SL);

         double profitPoints = (type == POSITION_TYPE_BUY) ? (currPrice - openPrice) / _Point : (openPrice - currPrice) / _Point;

         // Breakeven
         if(p_breakeven > 0 && profitPoints >= p_breakeven) {
            double newSL = (type == POSITION_TYPE_BUY) ? openPrice + p_breakevenStep * _Point : openPrice - p_breakevenStep * _Point;
            if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }

         // Trailing
         if(p_trailingStop > 0 && profitPoints >= p_trailingStop) {
            double newSL = (type == POSITION_TYPE_BUY) ? currPrice - p_trailingStop * _Point : currPrice + p_trailingStop * _Point;
             if((type == POSITION_TYPE_BUY && (sl < newSL || sl == 0)) || (type == POSITION_TYPE_SELL && (sl > newSL || sl == 0))) {
               trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}

// --- AI INTEGRATION ---
int AIPredict() {
   string filename = "signal_ai.txt";
   if(!FileIsExist(filename, FILE_COMMON)) return 0;

   int handle = FileOpen(filename, FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle == INVALID_HANDLE) return 0;

   string val = FileReadString(handle);
   FileClose(handle);

   if(val == "BUY") return 1;
   if(val == "SELL") return -1;
   return 0;
}

void AIOptimizer() {
   GravaLog("Running AI Strategy Optimizer...");
   // Simulating optimization: adjust risk slightly based on win rate
   // This is a placeholder for more complex logic
}
