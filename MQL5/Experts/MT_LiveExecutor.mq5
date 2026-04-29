//=========================  MT5-LIVE-EXECUTOR  =========================
// Integrando modelos avançados de IA para previsão e otimização de estratégias
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// ---------- CONSTANTS & ENUMS ----------
#define EA_MAGIC 123456
enum Signal {BUY=1, SELL=-1, NONE=0};

// Rule types mapping
#define RT_MA          1
#define RT_RSI         2
#define RT_STOCH       3
#define RT_BB          4
#define RT_DAILYBREAK  5
#define RT_DELTA       6
#define RT_VOL         7
#define RT_AMA         8
#define RT_BAR2        9
#define RT_RS         10
#define RT_AI         11
#define RT_AI_PRED    12

// ---------- STRUCTS ----------
struct Rule {
   bool     active;
   int      type;
   int      tf;
   int      p1, p2, p3;
   double   d1, d2;
   string   s1;
   int      handle1, handle2;
   Signal   intent; // Desired direction for this rule
};

// ---------- GLOBAL VARIABLES ----------
Rule rules[20];
int nRules = 0;

double p_riskPercent = 1.0;
int    p_stopPoints = 0;
int    p_takePoints = 0;
int    p_maxTrades = 3;
int    p_beStart = 0;
int    p_bePlus = 0;
int    p_trailingStart = 0;
int    p_trailingStep = 10;
string p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;

datetime last_prompt_time = 0;
CTrade trade;

// ---------- UTILITIES ----------

double GetBufferValue(int handle, int buffer, int shift) {
   double val[];
   ArraySetAsSeries(val, true);
   if(CopyBuffer(handle, buffer, shift, 1, val) > 0) return val[0];
   return 0;
}

// ---------- INDICATOR FUNCTIONS ----------

// Logic for evaluation based on Rule type
Signal AvaliaRegra(Rule &r) {
   int shift = 1; // Signal stable on bar 1

   switch(r.type) {
      case RT_MA: {
         if(r.handle2 != INVALID_HANDLE && r.handle2 != 0) {
            // MA vs MA crossover
            double f = GetBufferValue(r.handle1, 0, shift);
            double s = GetBufferValue(r.handle2, 0, shift);
            double fp = GetBufferValue(r.handle1, 0, shift+1);
            double sp = GetBufferValue(r.handle2, 0, shift+1);
            if(fp < sp && f > s) return BUY;
            if(fp > sp && f < s) return SELL;
         } else {
            // Price vs MA
            double ma = GetBufferValue(r.handle1, 0, shift);
            double map = GetBufferValue(r.handle1, 0, shift+1);
            double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
            double closep = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
            if(closep < map && close > ma) return BUY;
            if(closep > map && close < ma) return SELL;
         }
         break;
      }
      case RT_RSI: {
         double v = GetBufferValue(r.handle1, 0, shift);
         double vp = GetBufferValue(r.handle1, 0, shift+1);
         if(r.d1 > 0) {
            // intent-based cross
            if(r.intent == BUY && vp < r.d1 && v >= r.d1) return BUY;
            if(r.intent == SELL && vp > r.d1 && v <= r.d1) return SELL;
         } else {
            // general thresholds if no threshold specified
            if(v < 30) return BUY;
            if(v > 70) return SELL;
         }
         break;
      }
      case RT_STOCH: {
         double k = GetBufferValue(r.handle1, 0, shift);
         double d = GetBufferValue(r.handle1, 1, shift);
         double kp = GetBufferValue(r.handle1, 0, shift+1);
         double dp = GetBufferValue(r.handle1, 1, shift+1);
         if(kp < dp && k > d) return BUY;
         if(kp > dp && k < d) return SELL;
         break;
      }
      case RT_BB: {
         double mid = GetBufferValue(r.handle1, 0, shift);
         double up = GetBufferValue(r.handle1, 1, shift);
         double lo = GetBufferValue(r.handle1, 2, shift);
         double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         if(close < lo) return BUY;
         if(close > up) return SELL;
         break;
      }
      case RT_DAILYBREAK: {
         double hi = iHigh(_Symbol, PERIOD_D1, 1);
         double lo = iLow(_Symbol, PERIOD_D1, 1);
         double close = iClose(_Symbol, PERIOD_M1, 0);
         if(close > hi) return BUY;
         if(close < lo) return SELL;
         break;
      }
      case RT_VOL: {
         double vol = iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         double volp = iVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
         if(vol > volp * 1.5) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift)) ? BUY : SELL;
         break;
      }
      case RT_AMA: {
         double ama = GetBufferValue(r.handle1, 0, shift);
         double amap = GetBufferValue(r.handle1, 0, shift+1);
         if(amap < ama) return BUY;
         if(amap > ama) return SELL;
         break;
      }
      case RT_BAR2: {
         double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
         double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
         double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
         // Inside bar
         if(h0 < h1 && l0 > l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift)) ? BUY : SELL;
         // Outside bar
         if(h0 > h1 && l0 < l1) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift)) ? SELL : BUY;
         break;
      }
      case RT_RS: {
         double r1 = GetBufferValue(r.handle1, 0, shift);
         double r2 = GetBufferValue(r.handle2, 0, shift);
         if(r1 > r2 + 5) return BUY;
         if(r1 < r2 - 5) return SELL;
         break;
      }
      case RT_AI_PRED: {
         double atr = GetBufferValue(r.handle1, 0, shift);
         double body = MathAbs(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) - iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift));
         if(body > 1.5 * atr) return (iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift)) ? BUY : SELL;
         break;
      }
   }
   return NONE;
}

// ---------- NLP UTILITIES ----------

double ExtraiNumero(string txt, int &startPos) {
   string res = "";
   bool found = false;
   for(int i = startPos; i < StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if(found) {
         startPos = i;
         return StringToDouble(res);
      }
   }
   return StringToDouble(res);
}

double ExtraiValorApos(string txt, string keyword) {
   int pos = StringFind(txt, keyword);
   if(pos < 0) return 0;
   int start = pos + StringLen(keyword);
   return ExtraiNumero(txt, start);
}

int PeriodoTexto(string nome) {
   StringToLower(nome);
   if(StringFind(nome, "m15") >= 0 || StringFind(nome, "15 min") >= 0 || StringFind(nome, "15 minutos") >= 0) return PERIOD_M15;
   if(StringFind(nome, "m30") >= 0 || StringFind(nome, "30 min") >= 0 || StringFind(nome, "30 minutos") >= 0) return PERIOD_M30;
   if(StringFind(nome, "m5") >= 0 || StringFind(nome, "5 min") >= 0 || StringFind(nome, "5 minutos") >= 0) return PERIOD_M5;
   if(StringFind(nome, "m1") >= 0 || StringFind(nome, "1 min") >= 0 || StringFind(nome, "1 minuto") >= 0) return PERIOD_M1;
   if(StringFind(nome, "h1") >= 0 || StringFind(nome, "1 h") >= 0 || StringFind(nome, "1 hora") >= 0) return PERIOD_H1;
   if(StringFind(nome, "h4") >= 0 || StringFind(nome, "4 h") >= 0 || StringFind(nome, "4 horas") >= 0) return PERIOD_H4;
   if(StringFind(nome, "d1") >= 0 || StringFind(nome, "diário") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

string ExtractTime(string txt) {
   int pos = StringFind(txt, "depois das ");
   if(pos < 0) return "00:00";
   string sub = StringSubstr(txt, pos + 11, 5);
   StringReplace(sub, "h", ":00");
   if(StringFind(sub, ":") < 0) sub += ":00";
   return sub;
}

void ResetStrategy() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) IndicatorRelease(rules[i].handle2);
   }
   nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 0;
   p_takePoints = 0;
   p_maxTrades = 3;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
   p_startTime = "00:00";
   p_frequency = PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   StringToLower(prompt);

   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(prompt);
   p_startTime = ExtractTime(prompt);
   p_riskPercent = ExtraiValorApos(prompt, "risco de ");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiValorApos(prompt, "stop de ");
   p_takePoints = (int)ExtraiValorApos(prompt, "take de ");
   p_maxTrades = (int)ExtraiValorApos(prompt, "máximo ");
   if(p_maxTrades == 0) p_maxTrades = 3;

   p_beStart = (int)ExtraiValorApos(prompt, "atingir +");
   p_bePlus = (int)ExtraiValorApos(prompt, "entrada +");

   p_trailingStart = (int)ExtraiValorApos(prompt, "trailing de ");

   string segments[];
   string norm = prompt;
   StringReplace(norm, " e ", "|");
   StringReplace(norm, ".", "|");
   StringReplace(norm, ",", "|");
   int nSeg = StringSplit(norm, '|', segments);

   Signal currentIntent = NONE;
   int lastMA_p1 = 0, lastMA_p2 = 0;
   int lastRSI_p1 = 14;

   for(int i=0; i<nSeg && nRules < 20; i++) {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      if(StringFind(s, "venda") >= 0 || StringFind(s, "vende") >= 0) currentIntent = SELL;

      Rule r;
      r.active = false;
      r.tf = PeriodoTexto(s);
      if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;

      r.intent = currentIntent;

      if(StringFind(s, "média") >= 0 || StringFind(s, " ma ") >= 0 || StringFind(s, " ma/") >= 0) {
         r.type = RT_MA;
         int pos = 0;
         int f = (int)ExtraiNumero(s, pos);
         int sc = (int)ExtraiNumero(s, pos);
         if(f > 0) lastMA_p1 = f;
         if(sc > 0) lastMA_p2 = sc;
         r.p1 = lastMA_p1;
         r.p2 = lastMA_p2;
         if(r.p1 > 0) {
            r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
            if(r.p2 > 0) r.handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_SMA, PRICE_CLOSE);
            r.active = true;
         }
      }
      else if(StringFind(s, "rsi") >= 0) {
         r.type = RT_RSI;
         int pos = 0;
         int v1 = (int)ExtraiNumero(s, pos);
         int v2 = (int)ExtraiNumero(s, pos);
         if(v1 > 0 && v1 < 40) { r.p1 = v1; r.d1 = v2; lastRSI_p1 = v1; }
         else { r.p1 = lastRSI_p1; r.d1 = v1; }
         r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
         r.active = true;
      }
      else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         r.type = RT_STOCH;
         r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         r.active = true;
      }
      else if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
         r.type = RT_BB;
         r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
         r.active = true;
      }
      else if(StringFind(s, "rompimento diário") >= 0) {
         r.type = RT_DAILYBREAK;
         r.active = true;
      }
      else if(StringFind(s, "volume") >= 0) {
         r.type = RT_VOL;
         r.active = true;
      }
      else if(StringFind(s, "ama") >= 0 || StringFind(s, "adaptativa") >= 0) {
         r.type = RT_AMA;
         r.handle1 = iAMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, 10, 2, 30, PRICE_CLOSE);
         r.active = true;
      }
      else if(StringFind(s, "padrão barras") >= 0) {
         r.type = RT_BAR2;
         r.active = true;
      }
      else if(StringFind(s, "força relativa") >= 0) {
         r.type = RT_RS;
         r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
         r.handle2 = iRSI("US30", (ENUM_TIMEFRAMES)r.tf, 14, PRICE_CLOSE);
         r.active = true;
      }
      else if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0) {
         r.type = RT_AI_PRED;
         r.handle1 = iATR(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14);
         r.active = true;
      }

      if(r.active) {
         rules[nRules] = r;
         nRules++;
      }
   }
}

// ---------- SIGNAL EVALUATION ----------

Signal AvaliaTudo() {
   int buy_votos = 0;
   int sell_votos = 0;
   int buy_total = 0;
   int sell_total = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      Signal s = AvaliaRegra(rules[i]);

      // If rule has specific intent, it only contributes to that leg
      if(rules[i].intent == BUY || rules[i].intent == NONE) {
         buy_total++;
         if(s == BUY) buy_votos++;
      }
      if(rules[i].intent == SELL || rules[i].intent == NONE) {
         sell_total++;
         if(s == SELL) sell_votos++;
      }
   }

   if(buy_total > 0 && buy_votos == buy_total) return BUY;
   if(sell_total > 0 && sell_votos == sell_total) return SELL;

   return NONE;
}

// ---------- EXECUTION ----------

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE) return false;
   string content = FileReadString(handle);
   FileClose(handle);

   if(content == "1") return true;

   datetime newsTime = StringToTime(content);
   if(newsTime > 0) {
      if(TimeCurrent() >= newsTime - 20 * 60 && TimeCurrent() <= newsTime + 20 * 60) return true;
   }

   return false;
}

double CalculaLote(double riscoPercent, int stopPoints) {
   if(stopPoints <= 0) stopPoints = 300; // Default if not specified
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(tickValue == 0 || tickSize == 0) return 0.01;

   double pointsValue = tickValue / (tickSize / _Point);
   double volume = riscoAbs / (stopPoints * pointsValue);

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   volume = MathFloor(volume / stepLot) * stepLot;
   if(volume < minLot) volume = minLot;
   if(volume > maxLot) volume = maxLot;

   return NormalizeDouble(volume, 2);
}

void EnviaOrdem(Signal s, string reason) {
   if(s == NONE) return;
   if(AguardaNoticias()) {
      Print("Operação vetada por notícias.");
      return;
   }

   int count = 0;
   for(int i=0; i<PositionsTotal(); i++) {
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) count++;
   }
   if(count >= p_maxTrades) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;
   double volume = CalculaLote(p_riskPercent, p_stopPoints);

   if(s == BUY) {
      if(p_stopPoints > 0) sl = bid - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = ask + p_takePoints * _Point;

      // Margin check
      double margin;
      if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, volume, ask, margin)) return;
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
         Print("Margem insuficiente.");
         return;
      }

      trade.SetExpertMagicNumber(EA_MAGIC);
      if(trade.Buy(volume, _Symbol, ask, sl, tp, reason)) {
         SendNotification("MT-LiveExecutor: COMPRA executada em " + _Symbol);
      }
   } else {
      if(p_stopPoints > 0) sl = ask + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = bid - p_takePoints * _Point;

      // Margin check
      double margin;
      if(!OrderCalcMargin(ORDER_TYPE_SELL, _Symbol, volume, bid, margin)) return;
      if(margin > AccountInfoDouble(ACCOUNT_MARGIN_FREE)) {
         Print("Margem insuficiente.");
         return;
      }

      trade.SetExpertMagicNumber(EA_MAGIC);
      if(trade.Sell(volume, _Symbol, bid, sl, tp, reason)) {
         SendNotification("MT-LiveExecutor: VENDA executada em " + _Symbol);
      }
   }
}

// ---------- POSITION MANAGEMENT ----------

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(PositionGetSymbol(i) != _Symbol || PositionGetInteger(POSITION_MAGIC) != EA_MAGIC) continue;

      ulong ticket = PositionGetInteger(POSITION_TICKET);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      double tp = PositionGetDouble(POSITION_TP);
      double curSL = sl;

      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double price = (type == POSITION_TYPE_BUY) ? bid : ask;
      double profitPoints = (type == POSITION_TYPE_BUY) ? (bid - open) / _Point : (open - ask) / _Point;

      // Break-even
      if(p_beStart > 0 && profitPoints >= p_beStart) {
         double targetBE = (type == POSITION_TYPE_BUY) ? open + p_bePlus * _Point : open - p_bePlus * _Point;
         if(type == POSITION_TYPE_BUY && (sl < targetBE || sl == 0)) curSL = targetBE;
         if(type == POSITION_TYPE_SELL && (sl > targetBE || sl == 0)) curSL = targetBE;
      }

      // Trailing Stop
      if(p_trailingStart > 0 && profitPoints >= p_trailingStart) {
         double targetTS = (type == POSITION_TYPE_BUY) ? bid - p_trailingStart * _Point : ask + p_trailingStart * _Point;
         if(type == POSITION_TYPE_BUY && (targetTS > curSL + p_trailingStep * _Point || curSL == 0)) curSL = targetTS;
         if(type == POSITION_TYPE_SELL && (targetTS < curSL - p_trailingStep * _Point || curSL == 0)) curSL = targetTS;
      }

      if(curSL != sl) {
         trade.PositionModify(ticket, curSL, tp);
      }
   }
}

// ---------- LOGGING & PERSISTENCE ----------

void GravaLog(string texto) {
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_WRITE | FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
      FileClose(handle);
   }
}

void GravaCSV() {
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i=0; i<PositionsTotal(); i++) {
         if(PositionGetInteger(POSITION_MAGIC) == EA_MAGIC) {
            FileWrite(handle,
               PositionGetInteger(POSITION_TICKET),
               PositionGetSymbol(i),
               PositionGetInteger(POSITION_TYPE),
               PositionGetDouble(POSITION_VOLUME),
               PositionGetDouble(POSITION_PRICE_OPEN),
               PositionGetInteger(POSITION_TIME),
               PositionGetDouble(POSITION_SL),
               PositionGetDouble(POSITION_TP),
               PositionGetDouble(POSITION_PROFIT),
               PositionGetString(POSITION_COMMENT)
            );
         }
      }
      FileClose(handle);
   }
}

void CalculaEstatisticas() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   double profit = 0;
   int wins = 0, losses = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += p;
         if(p > 0) wins++;
         else if(p < 0) losses++;
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100.0 : 0;
   PrintFormat("Stats: Profit=%.2f, WinRate=%.2f%%", profit, winRate);
}

// ---------- EVENT HANDLERS ----------

int OnInit() {
   EventSetTimer(1);
   last_prompt_time = 0;
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
}

void AIOptimizer() {
   HistorySelect(0, TimeCurrent());
   int total = 0;
   int wins = 0;
   for(int i=HistoryDealsTotal()-1; i>=0 && total < 10; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         if(HistoryDealGetDouble(ticket, DEAL_PROFIT) > 0) wins++;
         total++;
      }
   }
   if(total >= 10) {
      double wr = (double)wins/total;
      if(wr < 0.4) p_riskPercent = NormalizeDouble(p_riskPercent * 0.9, 2);
      if(wr > 0.6) p_riskPercent = NormalizeDouble(p_riskPercent * 1.1, 2);
      if(p_riskPercent > 2.0) p_riskPercent = 2.0;
      if(p_riskPercent < 0.1) p_riskPercent = 0.1;
   }
}

void OnTimer() {
   // Runtime logic update from prompt.txt
   long modDate = FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(modDate > (long)last_prompt_time) {
      int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(handle != INVALID_HANDLE) {
         string prompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(prompt);
         last_prompt_time = (datetime)modDate;
         GravaLog("Estratégia atualizada via prompt.txt: " + prompt);
      }
   }

   // Periodic stats and AI optimization
   static datetime lastStat = 0;
   if(TimeCurrent() - lastStat > 3600) {
      CalculaEstatisticas();
      AIOptimizer();
      lastStat = TimeCurrent();
   }
}

void OnTick() {
   // Restricted by startTime
   if(TimeToString(TimeCurrent(), TIME_MINUTES) < p_startTime) return;

   // Bar-time check for signal
   static datetime lastBar = 0;
   datetime curBar = iTime(_Symbol, p_frequency, 0);

   if(curBar != lastBar) {
      Signal s = AvaliaTudo();
      if(s != NONE) {
         EnviaOrdem(s, "Sinal MT-LiveExecutor");
         GravaLog("Sinal detectado: " + EnumToString(s));
      }
      lastBar = curBar;
   }

   // Management and state on every tick
   GerenciaPosicoes();
   GravaCSV();
}
