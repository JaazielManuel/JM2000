//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Agente de Execução Direta
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- CONSTANTES ---
#define EA_MAGIC 123456
#define MAX_RULES 20

// --- ENUMS ---
enum Signal {BUY=1, SELL=-1, NONE=0};

// --- ESTRUTURAS ---
struct Rule {
   bool     active;
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   int      tf;         // Timeframe
   int      p1, p2, p3; // Períodos
   double   d1, d2;     // Limiares / Desvios
   string   s1;         // Texto (ex: benchmark)
   int      intent;     // BUY, SELL ou NONE
   int      handle1;
   int      handle2;
};

// --- VARIÁVEIS GLOBAIS ---
Rule rules[MAX_RULES];
int nRules = 0;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;

// Parâmetros de Estratégia (populados pelo parser)
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_maxTrades = 3;
int p_beStart = 0;
int p_bePlus = 0;
int p_trailingStart = 0;
int p_trailingStep = 10;
string p_startTime = "00:00";
datetime last_prompt_time = 0;

// --- 1. BIBLIOTECA DE INDICADORES (SINAIS) ---

// 1.1 MÉDIAS & CRUZAMENTOS / PREÇO VS MÉDIA
Signal CruzamentoMA(Rule &r, int shift=1)
{
   if(r.handle1 == INVALID_HANDLE) return NONE;

   double ma1_now = GetBufferValue(r.handle1, 0, shift);
   double ma1_prev = GetBufferValue(r.handle1, 0, shift+1);

   if(r.handle2 != INVALID_HANDLE && r.handle2 != 0) {
      // MA vs MA
      double ma2_now = GetBufferValue(r.handle2, 0, shift);
      double ma2_prev = GetBufferValue(r.handle2, 0, shift+1);

      if(ma1_prev < ma2_prev && ma1_now > ma2_now) return BUY;
      if(ma1_prev > ma2_prev && ma1_now < ma2_now) return SELL;
   } else {
      // Preço vs MA
      double close_now = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
      double close_prev = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);

      if(close_prev < ma1_prev && close_now > ma1_now) return BUY;
      if(close_prev > ma1_prev && close_now < ma1_now) return SELL;
   }
   return NONE;
}

// 1.2 RSI
Signal RSIThreshold(Rule &r, int shift=1)
{
   if(r.handle1 == INVALID_HANDLE) return NONE;
   double v = GetBufferValue(r.handle1, 0, shift);

   if(r.intent == BUY && v > r.d1) return BUY;
   if(r.intent == SELL && v < r.d1) return SELL;

   // Lógica padrão se não houver intent específico ou para compatibilidade
   if(r.intent == NONE) {
      if(v > 70) return SELL;
      if(v < 30) return BUY;
   }

   return NONE;
}

// 1.3 ESTOCÁSTICO
Signal StochCross(Rule &r, int shift=1)
{
   if(r.handle1 == INVALID_HANDLE) return NONE;
   double k1 = GetBufferValue(r.handle1, 0, shift);
   double d1 = GetBufferValue(r.handle1, 1, shift);
   double k2 = GetBufferValue(r.handle1, 0, shift+1);
   double d2 = GetBufferValue(r.handle1, 1, shift+1);

   if(k2 < d2 && k1 > d1) return BUY;
   if(k2 > d2 && k1 < d1) return SELL;
   return NONE;
}

// 1.4 BOLLINGER BANDS
Signal BBounce(Rule &r, int shift=1)
{
   if(r.handle1 == INVALID_HANDLE) return NONE;
   double upper = GetBufferValue(r.handle1, 1, shift);
   double lower = GetBufferValue(r.handle1, 2, shift);
   double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);

   if(close < lower) return BUY;
   if(close > upper) return SELL;
   return NONE;
}

// 1.5 BREAKOUT DIÁRIO
Signal DailyBreak(Rule &r, int shift=0)
{
   double hi = iHigh(_Symbol, PERIOD_D1, 1);
   double lo = iLow(_Symbol, PERIOD_D1, 1);
   double close = iClose(_Symbol, PERIOD_CURRENT, shift);

   if(close > hi) return BUY;
   if(close < lo) return SELL;
   return NONE;
}

// 1.6 DELTA DE AGRESSÃO (Simulado para MT5 padrão)
Signal DeltaAggression(Rule &r)
{
   MqlTick arr[];
   int n = CopyTicksRange(_Symbol, arr, COPY_TICKS_TRADE, TimeCurrent() - r.p1, TimeCurrent());
   if(n <= 0) return NONE;

   long buy = 0, sell = 0;
   for(int i=0; i<n; i++) {
      if((arr[i].flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) buy++;
      else if((arr[i].flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) sell++;
   }
   long delta = buy - sell;
   if(delta > r.d1) return BUY;
   if(delta < -r.d1) return SELL;
   return NONE;
}

// 1.7 CICLO DE VOLUME
Signal VolumeCycle(Rule &r, int shift=1)
{
   long vol[]; ArraySetAsSeries(vol, true);
   CopyVolume(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift, r.p1, vol);
   int highIdx = ArrayMaximum(vol);
   int lowIdx = ArrayMinimum(vol);

   if(highIdx == 0) return SELL;
   if(lowIdx == 0) return BUY;
   return NONE;
}

// 1.8 MÉDIA MÓVEL ADAPTATIVA (AMA)
Signal AMASignal(Rule &r, int shift=1)
{
   if(r.handle1 == INVALID_HANDLE) return NONE;
   double ama_now = GetBufferValue(r.handle1, 0, shift);
   double ama_prev = GetBufferValue(r.handle1, 0, shift+1);

   if(ama_now > ama_prev) return BUY;
   if(ama_now < ama_prev) return SELL;
   return NONE;
}

// 1.9 PADRÃO DE 2 BARRAS
Signal Bar2Pattern(Rule &r, int shift=1)
{
   double h0 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double l0 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double h1 = iHigh(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double l1 = iLow(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);
   double c0 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
   double o0 = iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);

   // Inside Bar
   if(h0 < h1 && l0 > l1) return (c0 > o0) ? BUY : SELL;
   // Outside Bar
   if(h0 > h1 && l0 < l1) return (c0 > o0) ? SELL : BUY;

   return NONE;
}

// 1.10 FORÇA RELATIVA
Signal RSByHandles(Rule &r, int shift=1)
{
   if(r.handle1 == INVALID_HANDLE || r.handle2 == INVALID_HANDLE) return NONE;
   double r1 = GetBufferValue(r.handle1, 0, shift);
   double r2 = GetBufferValue(r.handle2, 0, shift);

   if(r1 > r2 + 5) return BUY;
   if(r1 < r2 - 5) return SELL;
   return NONE;
}

// 1.11 AI PREDICTOR (Heurística baseada em ATR e Corpo)
Signal AISignal(Rule &r, int shift=1)
{
   if(r.handle1 == INVALID_HANDLE) return NONE;
   double atr = GetBufferValue(r.handle1, 0, shift);
   double body = MathAbs(iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) - iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift));
   bool bullish = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift) > iOpen(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);

   if(body > 1.5 * atr) return bullish ? BUY : SELL;
   return NONE;
}

// --- UTILITÁRIOS ---

double GetBufferValue(int handle, int buffer, int shift)
{
   double val[1];
   if(CopyBuffer(handle, buffer, shift, 1, val) <= 0) return 0;
   return val[0];
}

// --- NLP PARSING ENGINE ---

double ExtraiNumero(string txt, int &pos) {
   string res = "";
   bool found = false;
   for(int i=pos; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',') {
         res += (c == ',') ? "." : StringSubstr(txt, i, 1);
         found = true;
      } else if(found) {
         pos = i;
         return StringToDouble(res);
      }
   }
   pos = StringLen(txt);
   return StringToDouble(res);
}

double ExtraiValorApos(string txt, string keyword) {
   int p = StringFind(txt, keyword);
   if(p < 0) return 0;
   int pos = p + StringLen(keyword);
   return ExtraiNumero(txt, pos);
}

string ExtractTime(string txt) {
   int p = StringFind(txt, "depois das ");
   if(p < 0) return "00:00";
   int pos = p + 11;
   string res = "";
   for(int i=pos; i<StringLen(txt); i++) {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == ':' || c == 'h') {
         res += (c == 'h' && StringLen(res) > 0 && StringFind(res, ":") < 0) ? ":" : StringSubstr(txt, i, 1);
      } else if(StringLen(res) > 0) break;
   }
   if(StringFind(res, ":") < 0 && StringLen(res) > 0) res += ":00";
   return res;
}

int PeriodoTexto(string nome) {
   nome = StringSubstr(nome, 0, 10);
   StringToLower(nome);
   if(StringFind(nome, "m1") >= 0 && StringFind(nome, "m15") < 0) return PERIOD_M1;
   if(StringFind(nome, "m5") >= 0) return PERIOD_M5;
   if(StringFind(nome, "m15") >= 0 || StringFind(nome, "15 min") >= 0) return PERIOD_M15;
   if(StringFind(nome, "h1") >= 0 || StringFind(nome, "1 hora") >= 0) return PERIOD_H1;
   if(StringFind(nome, "d1") >= 0 || StringFind(nome, "diário") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void ResetStrategy() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].handle1 != INVALID_HANDLE && rules[i].handle1 != 0) IndicatorRelease(rules[i].handle1);
      if(rules[i].handle2 != INVALID_HANDLE && rules[i].handle2 != 0) IndicatorRelease(rules[i].handle2);
   }
   nRules = 0;
   ZeroMemory(rules);
   p_frequency = PERIOD_M15;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_maxTrades = 3;
   p_beStart = 0;
   p_bePlus = 0;
   p_trailingStart = 0;
   p_trailingStep = 10;
   p_startTime = "00:00";
}

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string lowerPrompt = prompt;
   StringToLower(lowerPrompt);

   // Parâmetros Globais
   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(lowerPrompt);
   p_riskPercent = ExtraiValorApos(lowerPrompt, "risco de ");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiValorApos(lowerPrompt, "stop de ");
   p_takePoints = (int)ExtraiValorApos(lowerPrompt, "take de ");
   p_maxTrades = (int)ExtraiValorApos(lowerPrompt, "máximo ");
   if(p_maxTrades == 0) p_maxTrades = 3;

   p_beStart = (int)ExtraiValorApos(lowerPrompt, "atingir +");
   p_bePlus = (int)ExtraiValorApos(lowerPrompt, "entrada +");
   p_trailingStart = (int)ExtraiValorApos(lowerPrompt, "trailing ");
   p_startTime = ExtractTime(lowerPrompt);

   // Divide em segmentos
   string segments[];
   string sep = "|";
   string work = lowerPrompt;
   StringReplace(work, " e ", sep);
   StringReplace(work, ".", sep);
   StringReplace(work, ",", sep);
   ushort u_sep = StringGetCharacter(sep, 0);
   int nSeg = StringSplit(work, u_sep, segments);

   for(int i=0; i<nSeg && nRules < MAX_RULES; i++) {
      string s = segments[i];
      StringTrimLeft(s); StringTrimRight(s);
      if(StringLen(s) < 3) continue;

      Rule r; r.active = true; r.intent = NONE;
      r.tf = PeriodoTexto(s);
      if(r.tf == PERIOD_CURRENT) r.tf = p_frequency;

      if(StringFind(s, "compra") >= 0) r.intent = BUY;
      else if(StringFind(s, "vende") >= 0) r.intent = SELL;

      // MA
      if(StringFind(s, " ma ") >= 0 || StringFind(s, "média") >= 0) {
         r.type = 1;
         int pos = 0;
         r.p1 = (int)ExtraiNumero(s, pos);
         r.p2 = (int)ExtraiNumero(s, pos);
         r.handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
         if(r.p2 > 0) r.handle2 = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p2, 0, MODE_SMA, PRICE_CLOSE);
         rules[nRules++] = r;
      }
      // RSI
      else if(StringFind(s, "rsi") >= 0) {
         r.type = 2;
         int pos = 0;
         double n1 = ExtraiNumero(s, pos);
         double n2 = ExtraiNumero(s, pos);
         if(n1 < 40) { r.p1 = (int)n1; r.d1 = n2; }
         else { r.p1 = 14; r.d1 = n1; }
         r.handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
         rules[nRules++] = r;
      }
      // Estocástico
      else if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
         r.type = 3;
         r.handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         rules[nRules++] = r;
      }
      // Bollinger
      else if(StringFind(s, "bollinger") >= 0 || StringFind(s, " bb") >= 0) {
         r.type = 4;
         r.handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, 20, 0, 2.0, PRICE_CLOSE);
         rules[nRules++] = r;
      }
      // AI / Previsão
      else if(StringFind(s, "previsão") >= 0 || StringFind(s, "ai") >= 0) {
         r.type = 11;
         r.handle1 = iATR(_Symbol, (ENUM_TIMEFRAMES)r.tf, 14);
         rules[nRules++] = r;
      }
   }
}

// --- CORE SIGNAL AND EXECUTION LOGIC ---

Signal AvaliaRegra(Rule &r) {
   switch(r.type) {
      case 1: return CruzamentoMA(r);
      case 2: return RSIThreshold(r);
      case 3: return StochCross(r);
      case 4: return BBounce(r);
      case 5: return DailyBreak(r);
      case 6: return DeltaAggression(r);
      case 7: return VolumeCycle(r);
      case 8: return AMASignal(r);
      case 9: return Bar2Pattern(r);
      case 10: return RSByHandles(r);
      case 11: return AISignal(r);
   }
   return NONE;
}

Signal AvaliaTudo() {
   int buyLeg = 0, buyRules = 0;
   int sellLeg = 0, sellRules = 0;

   for(int i=0; i<nRules; i++) {
      Signal s = AvaliaRegra(rules[i]);
      if(rules[i].intent == BUY || rules[i].intent == NONE) {
         buyRules++;
         if(s == BUY) buyLeg++;
      }
      if(rules[i].intent == SELL || rules[i].intent == NONE) {
         sellRules++;
         if(s == SELL) sellLeg++;
      }
   }

   if(buyRules > 0 && buyLeg == buyRules) return BUY;
   if(sellRules > 0 && sellLeg == sellRules) return SELL;
   return NONE;
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double riskAmount = capital * (riscoPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopPoints <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   double lot = riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point)));
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return lot;
}

void EnviaOrdem(Signal s, string reason) {
   if(s == NONE) return;
   if(PositionsTotal() >= p_maxTrades) return;
   if(AguardaNoticias()) return;

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;
   double lot = CalculaLote(p_riskPercent);

   if(s == BUY) {
      if(p_stopPoints > 0) sl = price - p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
      if(trade.Buy(lot, _Symbol, price, sl, tp, reason)) {
         GravaLog("Compra executada: " + reason);
      }
   } else {
      if(p_stopPoints > 0) sl = price + p_stopPoints * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
      if(trade.Sell(lot, _Symbol, price, sl, tp, reason)) {
         GravaLog("Venda executada: " + reason);
      }
   }
}

void GerenciaPosicoes() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) {
         double openPrice = posInfo.PriceOpen();
         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double currentSL = posInfo.StopLoss();
         int points = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (int)((currentPrice - openPrice)/_Point) : (int)((openPrice - currentPrice)/_Point);

         // Break-even
         if(p_beStart > 0 && points >= p_beStart && currentSL == 0) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_bePlus * _Point : openPrice - p_bePlus * _Point;
            trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            GravaLog("Break-even acionado para " + (string)posInfo.Ticket());
         }

         // Trailing Stop
         if(p_trailingStart > 0 && points >= p_trailingStart) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentPrice - p_trailingStart * _Point : currentPrice + p_trailingStart * _Point;
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               if(newSL > currentSL + p_trailingStep * _Point) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            } else {
               if(currentSL == 0 || newSL < currentSL - p_trailingStep * _Point) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

// --- AUXILIARY SYSTEMS ---

bool AguardaNoticias() {
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE) return false;

   string content = FileReadString(handle);
   FileClose(handle);

   if(content == "1") return true;

   datetime newsTime = StringToTime(content);
   if(newsTime > 0) {
      if(TimeCurrent() >= newsTime - 20*60 && TimeCurrent() <= newsTime + 20*60) return true;
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
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(),
                      posInfo.PriceOpen(), posInfo.Time(), posInfo.StopLoss(), posInfo.TakeProfit(),
                      posInfo.Profit(), posInfo.Comment());
         }
      }
      FileClose(handle);
   }
}

void CalculaEstatisticas() {
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double profit = 0;

   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         profit += p;
         if(p > 0) wins++;
         else if(p < 0) losses++;
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;
   GravaLog("Estatísticas - Lucro: " + (string)profit + " | WinRate: " + DoubleToString(winRate*100, 2) + "%");

   // AIOptimizer Heuristic
   if(wins + losses >= 10) {
      if(winRate < 0.40) {
         p_riskPercent *= 0.8;
         GravaLog("AIOptimizer: Reduzindo risco devido a performance.");
      } else if(winRate > 0.60) {
         p_riskPercent = MathMin(p_riskPercent * 1.2, 2.0);
         GravaLog("AIOptimizer: Aumentando risco devido a boa performance.");
      }
   }
}

// --- EVENT HANDLERS ---

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1);

   // Carrega prompt inicial se existir
   int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle);
      FileClose(handle);
      InterpretaPrompt(prompt);
      last_prompt_time = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
      GravaLog("EA Inicializado com prompt de arquivo.");
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   ResetStrategy();
   GravaLog("EA Finalizado.");
}

void OnTick() {
   static datetime lastBar = 0;
   datetime currentBar = iTime(_Symbol, p_frequency, 0);

   // Gerenciamento de posições em cada tick
   GerenciaPosicoes();
   GravaCSV();

   // Entrada apenas no início da barra
   if(currentBar != lastBar) {
      lastBar = currentBar;

      // Filtro de horário
      if(TimeToString(TimeCurrent(), TIME_MINUTES) < p_startTime) return;

      Signal s = AvaliaTudo();
      if(s != NONE) {
         EnviaOrdem(s, "Sinal consolidado");
      }
   }
}

void OnTimer() {
   // Verifica atualização do prompt.txt
   datetime modify = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(modify > last_prompt_time) {
      int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if(handle != INVALID_HANDLE) {
         string prompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(prompt);
         last_prompt_time = modify;
         GravaLog("Estratégia atualizada em tempo real via prompt.txt");
      }
   }

   // Calcula estatísticas a cada hora
   static datetime lastStat = 0;
   if(TimeCurrent() - lastStat > 3600) {
      CalculaEstatisticas();
      lastStat = TimeCurrent();
   }
}
