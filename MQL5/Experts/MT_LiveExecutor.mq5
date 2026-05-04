//=========================  MT5-LIVE-EXECUTOR  =========================
// Agent: MT-LiveExecutor
// Description: Multi-strategy NLP-based executor for MetaTrader 5
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Enums and Structs ---
enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   bool     active;
   ENUM_TIMEFRAMES tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
   int      intent;     // BUY or SELL
};

// --- Global Variables ---
Rule     rules[20];
int      nRules = 0;
long     EA_MAGIC = 123456;

double   p_riskPercent  = 1.0;
int      p_stopPoints   = 0;
int      p_takePoints   = 0;
int      p_maxTrades    = 3;
string   p_startTime    = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool     p_useMartingale = false;
int      p_trailingStart = 0;
int      p_trailingStep  = 10;
int      p_beStart       = 0;
int      p_bePlus        = 0;

datetime lastPromptUpdate = 0;
CTrade   trade;

// --- Forward Declarations ---
void InterpretaPrompt(string prompt);
Signal AvaliaRegra(Rule &r);
Signal AvaliaTudo();
double CalculaLote(double riscoPercent);
void EnviaOrdem(Signal s, string reason);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaLog(string texto);
void GravaCSV();
void AIOptimizer();
void ResetStrategy();

// --- Utilities ---

double ExtraiNumero(string text, string keyword, double defaultVal = 0) {
   int pos = StringFind(text, keyword);
   if(pos < 0) return defaultVal;
   int start = pos + StringLen(keyword);
   return ExtraiNumero(text, start);
}

double ExtraiNumero(string text, int &startPos) {
   string res = "";
   bool found = false;
   for(int i = startPos; i < StringLen(text); i++) {
      ushort c = StringGetCharacter(text, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if(found) {
         startPos = i;
         break;
      }
   }
   return (res == "") ? 0 : StringToDouble(res);
}

double ExtraiValorApos(string text, string keyword) {
   int pos = StringFind(text, keyword);
   if(pos < 0) return -1;
   int start = pos + StringLen(keyword);
   while(start < StringLen(text) && StringGetCharacter(text, start) == ' ') start++;
   return ExtraiNumero(text, start);
}

ENUM_TIMEFRAMES PeriodoTexto(string texto) {
   string work = texto;
   StringToLower(work);
   if(StringFind(work, "15 minutos") >= 0 || StringFind(work, "m15") >= 0) return PERIOD_M15;
   if(StringFind(work, "5 minutos") >= 0 || StringFind(work, "m5") >= 0)  return PERIOD_M5;
   if(StringFind(work, "1 minuto") >= 0 || StringFind(work, "m1") >= 0)   return PERIOD_M1;
   if(StringFind(work, "1 hora") >= 0 || StringFind(work, "h1") >= 0)     return PERIOD_H1;
   if(StringFind(work, "diário") >= 0 || StringFind(work, "d1") >= 0)     return PERIOD_D1;
   return PERIOD_CURRENT;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) < 0) return 0;
   return val[0];
}

void ResetStrategy() {
   for(int i = 0; i < nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) IndicatorRelease(rules[i].handle2);
      rules[i].active = false;
   }
   nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 0;
   p_takePoints = 0;
   p_maxTrades = 3;
   p_startTime = "00:00";
   p_frequency = PERIOD_M15;
   p_useMartingale = false;
   p_trailingStart = 0;
   p_beStart = 0;
   p_bePlus = 0;
}

// --- Interpretation Logic ---

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string work = prompt;
   StringToLower(work);

   // Global Params
   double val = ExtraiValorApos(work, "risco de");
   if(val > 0) p_riskPercent = val;
   val = ExtraiValorApos(work, "stop de");
   if(val > 0) p_stopPoints = (int)val;
   val = ExtraiValorApos(work, "take de");
   if(val > 0) p_takePoints = (int)val;
   val = ExtraiValorApos(work, "máximo");
   if(val > 0) p_maxTrades = (int)val;
   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   // Start time
   if(StringFind(work, "depois das") >= 0 || StringFind(work, "início") >= 0 || StringFind(work, "começar") >= 0) {
      int pos = StringFind(work, ":");
      if(pos > 2) {
         p_startTime = StringSubstr(work, pos - 2, 5);
      }
   }

   p_frequency = PeriodoTexto(work);

   // Break-even and Trailing
   if(StringFind(work, "move stop para entrada") >= 0) {
      p_beStart = (int)ExtraiNumero(work, "atingir +");
      p_bePlus = (int)ExtraiNumero(work, "entrada +");
   }
   if(StringFind(work, "trailing") >= 0) {
      p_trailingStart = (int)ExtraiNumero(work, "trailing de");
      p_trailingStep = 10;
   }

   // Segments
   string segments[];
   string tempWork = work;
   // Ensure " e " doesn't split if it's part of a phrase, but here we use it as a logical separator.
   StringReplace(tempWork, " e ", "|");
   StringReplace(tempWork, ".", "|");
   StringReplace(tempWork, ",", "|");
   ushort sep = StringGetCharacter("|", 0);
   int nSeg = StringSplit(tempWork, sep, segments);

   int currentIntent = NONE;
   for(int i = 0; i < nSeg && nRules < 20; i++) {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      if(currentIntent == NONE) continue; // Skip segments without direction if no global direction yet

      ENUM_TIMEFRAMES stf = PeriodoTexto(s);
      if(stf == PERIOD_CURRENT) stf = p_frequency;

      // MA Cross
      if(StringFind(s, " ma ") >= 0 || StringFind(s, "média") >= 0) {
         rules[nRules].type = 1;
         rules[nRules].active = true;
         rules[nRules].tf = stf;
         rules[nRules].intent = currentIntent;
         int cursor = 0;
         rules[nRules].p1 = (int)ExtraiNumero(s, cursor);
         rules[nRules].p2 = (int)ExtraiNumero(s, cursor);
         if(rules[nRules].p1 == 0) rules[nRules].p1 = 20;
         rules[nRules].handle1 = iMA(_Symbol, stf, rules[nRules].p1, 0, MODE_SMA, PRICE_CLOSE);
         if(rules[nRules].p2 > 0)
            rules[nRules].handle2 = iMA(_Symbol, stf, rules[nRules].p2, 0, MODE_SMA, PRICE_CLOSE);
         else
            rules[nRules].handle2 = INVALID_HANDLE;
         nRules++;
      }
      // RSI
      else if(StringFind(s, "rsi") >= 0) {
         rules[nRules].type = 2;
         rules[nRules].active = true;
         rules[nRules].tf = stf;
         rules[nRules].intent = currentIntent;
         int cursor = 0;
         double v1 = ExtraiNumero(s, cursor);
         double v2 = ExtraiNumero(s, cursor);
         if(v1 < 40) { rules[nRules].p1 = (int)v1; rules[nRules].d1 = v2; }
         else { rules[nRules].p1 = 14; rules[nRules].d1 = v1; }
         if(rules[nRules].p1 == 0) rules[nRules].p1 = 14;
         if(rules[nRules].d1 == 0) rules[nRules].d1 = (currentIntent == BUY) ? 30 : 70;
         rules[nRules].handle1 = iRSI(_Symbol, stf, rules[nRules].p1, PRICE_CLOSE);
         nRules++;
      }
      // Stoch
      else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         rules[nRules].type = 3;
         rules[nRules].active = true;
         rules[nRules].tf = stf;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iStochastic(_Symbol, stf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         nRules++;
      }
      // AI / Previsão
      else if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0) {
         rules[nRules].type = 11;
         rules[nRules].active = true;
         rules[nRules].tf = stf;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iATR(_Symbol, stf, 14);
         nRules++;
      }
      // BB
      else if(StringFind(s, "bollinger") >= 0 || StringFind(s, " bandas") >= 0) {
         rules[nRules].type = 4;
         rules[nRules].active = true;
         rules[nRules].tf = stf;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iBands(_Symbol, stf, 20, 0, 2.0, PRICE_CLOSE);
         nRules++;
      }
      // DailyBreak
      else if(StringFind(s, "rompimento diário") >= 0) {
         rules[nRules].type = 5;
         rules[nRules].active = true;
         rules[nRules].tf = stf;
         rules[nRules].intent = currentIntent;
         nRules++;
      }
      // Vol
      else if(StringFind(s, "volume") >= 0) {
         rules[nRules].type = 7;
         rules[nRules].active = true;
         rules[nRules].tf = stf;
         rules[nRules].intent = currentIntent;
         nRules++;
      }
      // AMA
      else if(StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0) {
         rules[nRules].type = 8;
         rules[nRules].active = true;
         rules[nRules].tf = stf;
         rules[nRules].intent = currentIntent;
         rules[nRules].handle1 = iAMA(_Symbol, stf, 10, 2, 30, 0, PRICE_CLOSE);
         nRules++;
      }
   }
}

// --- System Utilities ---

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "true" || content == "1") return true;
   }
   return false;
}

void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
      FileClose(handle);
   }
   Print(texto);
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i = 0; i < PositionsTotal(); i++) {
         ulong ticket = PositionGetTicket(i);
         if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
            FileWrite(handle, ticket, PositionGetString(POSITION_SYMBOL), PositionGetInteger(POSITION_TYPE),
                      PositionGetDouble(POSITION_VOLUME), PositionGetDouble(POSITION_PRICE_OPEN),
                      PositionGetInteger(POSITION_TIME), PositionGetDouble(POSITION_SL),
                      PositionGetDouble(POSITION_TP), PositionGetDouble(POSITION_PROFIT),
                      PositionGetString(POSITION_COMMENT));
         }
      }
      FileClose(handle);
   }
}

void AIOptimizer() {
   HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, count = 0;
   for(int i = total - 1; i >= 0 && count < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
         count++;
      }
   }
   if(count >= 5 && (double)wins / count < 0.4) {
      p_riskPercent *= 0.8;
      GravaLog("Optimizer: Risco reduzido devido a performance baixa.");
   }
}

// --- Event Handlers ---

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ResetStrategy();
   EventKillTimer();
}

void OnTick() {
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, p_frequency, 0);

   GerenciaPosicoes();
   GravaCSV();

   if(curBar != lastBar) {
      lastBar = curBar;

      // Time veto
      string curTime = TimeToString(TimeCurrent(), TIME_MINUTES);
      if(curTime < p_startTime) return;

      // News veto
      if(AguardaNoticias()) return;

      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s, "Signal Confirmado");
   }
}

void OnTimer() {
   int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
      if(mod > lastPromptUpdate) {
         string prompt = FileReadString(handle);
         InterpretaPrompt(prompt);
         lastPromptUpdate = mod;
         GravaLog("Novo prompt carregado: " + prompt);
      }
      FileClose(handle);
   }

   static datetime lastOpt = 0;
   if(TimeCurrent() - lastOpt > 3600) {
      AIOptimizer();
      lastOpt = TimeCurrent();
   }
}

// --- Evaluation Logic ---

Signal AvaliaRegra(Rule &r) {
   if(!r.active) return NONE;
   Signal sig = NONE;

   if(r.type == 1) { // MA
      double ma1 = GetBufferValue(r.handle1, 0, 1);
      double ma1p = GetBufferValue(r.handle1, 0, 2);
      if(r.handle2 == INVALID_HANDLE) { // Price vs MA
         double close1 = iClose(_Symbol, r.tf, 1);
         double close2 = iClose(_Symbol, r.tf, 2);
         if(close2 < ma1p && close1 > ma1) sig = BUY;
         else if(close2 > ma1p && close1 < ma1) sig = SELL;
      } else { // MA vs MA
         double ma2 = GetBufferValue(r.handle2, 0, 1);
         double ma2p = GetBufferValue(r.handle2, 0, 2);
         if(ma1p < ma2p && ma1 > ma2) sig = BUY;
         else if(ma1p > ma2p && ma1 < ma2) sig = SELL;
      }
   }

   else if(r.type == 2) { // RSI
      double rsi1 = GetBufferValue(r.handle1, 0, 1);
      double rsi2 = GetBufferValue(r.handle1, 0, 2);
      if(rsi2 < r.d1 && rsi1 > r.d1) sig = BUY;
      else if(rsi2 > r.d1 && rsi1 < r.d1) sig = SELL;
      else if(rsi1 < 30) sig = BUY;
      else if(rsi1 > 70) sig = SELL;
   }

   else if(r.type == 3) { // Stoch
      double k1 = GetBufferValue(r.handle1, 0, 1);
      double d1 = GetBufferValue(r.handle1, 1, 1);
      double k2 = GetBufferValue(r.handle1, 0, 2);
      double d2 = GetBufferValue(r.handle1, 1, 2);
      if(k2 < d2 && k1 > d1) sig = BUY;
      else if(k2 > d2 && k1 < d1) sig = SELL;
   }

   else if(r.type == 4) { // Bollinger Bands
      double upper = GetBufferValue(r.handle1, 1, 1);
      double lower = GetBufferValue(r.handle1, 2, 1);
      double close = iClose(_Symbol, r.tf, 1);
      if(close < lower) sig = BUY;
      else if(close > upper) sig = SELL;
   }

   else if(r.type == 5) { // Daily Breakout
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double close = iClose(_Symbol, r.tf, 1);
      if(close > hi) sig = BUY;
      else if(close < lo) sig = SELL;
   }

   else if(r.type == 7) { // Volume
      double v1 = (double)iVolume(_Symbol, r.tf, 1);
      double v2 = (double)iVolume(_Symbol, r.tf, 2);
      if(v1 > v2 * 1.5) {
         sig = (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? BUY : SELL;
      }
   }

   else if(r.type == 8) { // AMA
      double ama1 = GetBufferValue(r.handle1, 0, 1);
      double ama2 = GetBufferValue(r.handle1, 0, 2);
      if(ama1 > ama2) sig = BUY;
      else if(ama1 < ama2) sig = SELL;
   }

   else if(r.type == 11) { // AI Heuristic
      double atr = GetBufferValue(r.handle1, 0, 1);
      double body = MathAbs(iClose(_Symbol, r.tf, 1) - iOpen(_Symbol, r.tf, 1));
      if(body > 1.5 * atr) {
         sig = (iClose(_Symbol, r.tf, 1) > iOpen(_Symbol, r.tf, 1)) ? BUY : SELL;
      }
   }

   // Respect Intent
   if(r.intent != NONE && sig != r.intent) return NONE;
   return sig;
}

Signal AvaliaTudo() {
   if(nRules == 0) return NONE;
   int buyVotes = 0, sellVotes = 0;
   int buyRules = 0, sellRules = 0;

   for(int i = 0; i < nRules; i++) {
      if(rules[i].intent == BUY) buyRules++;
      if(rules[i].intent == SELL) sellRules++;

      Signal s = AvaliaRegra(rules[i]);
      if(s == BUY) buyVotes++;
      if(s == SELL) sellVotes++;
   }

   if(buyRules > 0 && buyVotes == buyRules) return BUY;
   if(sellRules > 0 && sellVotes == sellRules) return SELL;
   return NONE;
}

// --- Trade Execution Logic ---

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = capital * (riscoPercent / 100.0);

   if(p_useMartingale) {
      HistorySelect(0, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAmount *= 2.0;
            break;
         }
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   int stop = (p_stopPoints > 0) ? p_stopPoints : 300;

   double volume = riskAmount / (stop * (tickValue / (tickSize / _Point)));
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   volume = MathFloor(volume / step) * step;

   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(volume < minVol) volume = minVol;
   if(volume > maxVol) volume = maxVol;

   return volume;
}

void EnviaOrdem(Signal s, string reason) {
   if(s == NONE) return;

   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) count++;
   }
   if(count >= p_maxTrades) return;

   double lote = CalculaLote(p_riskPercent);
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Margin Check
   double margin;
   ENUM_ORDER_TYPE type = (s == BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcMargin(type, _Symbol, lote, price, margin)) return;
   if(margin > AccountInfoDouble(ACCOUNT_FREEMARGIN)) {
      GravaLog("Margem insuficiente para " + EnumToString(s));
      return;
   }

   double sl = 0, tp = 0;
   if(s == BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
      if(trade.Buy(lote, _Symbol, price, sl, tp, reason)) {
         SendNotification("Compra executada: " + reason);
      } else {
         GravaLog("Erro na compra: " + (string)trade.ResultRetcode() + " " + trade.ResultComment());
      }
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
      if(trade.Sell(lote, _Symbol, price, sl, tp, reason)) {
         SendNotification("Venda executada: " + reason);
      } else {
         GravaLog("Erro na venda: " + (string)trade.ResultRetcode() + " " + trade.ResultComment());
      }
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double profitPoints = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? (curPrice - open) / _Point : (open - curPrice) / _Point;

      // Break-even
      if(p_beStart > 0 && profitPoints >= p_beStart) {
         double targetSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? open + p_bePlus * _Point : open - p_bePlus * _Point;
         if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && (curSL < targetSL || curSL == 0)) ||
            (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (curSL > targetSL || curSL == 0))) {
            trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
         }
      }

      // Trailing Stop
      if(p_trailingStart > 0 && profitPoints >= p_trailingStart) {
         double targetSL = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? curPrice - p_trailingStart * _Point : curPrice + p_trailingStart * _Point;
         if(MathAbs(targetSL - curSL) >= p_trailingStep * _Point) {
            if((PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY && targetSL > curSL) ||
               (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL && (targetSL < curSL || curSL == 0))) {
               trade.PositionModify(ticket, targetSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}
