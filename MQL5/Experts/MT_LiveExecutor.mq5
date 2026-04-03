//=========================  MT5-LIVE-EXECUTOR  =========================
// Integrando modelos avançados de IA para previsão e otimização de estratégias
// Módulo único para execução de prompts em português no MetaTrader 5
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- CONSTANTES E ENUMS ----------
#define EA_MAGIC 20260101
#define MAX_RULES 30

enum Signal { BUY=1, SELL=-1, NONE=0 };

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI,
   RULE_STOCH,
   RULE_BB,
   RULE_DAILY_BREAK,
   RULE_DELTA,
   RULE_VOLUME,
   RULE_AMA,
   RULE_BAR_PATTERN,
   RULE_RS_RELATIVE
};

struct Rule {
   bool      active;
   RuleType  type;
   ENUM_TIMEFRAMES tf;
   int       p1, p2, p3; // Períodos ou handles
   double    d1, d2;     // Thresholds ou desvios
   string    s1;         // Símbolo benchmark
   Signal    intent;     // BUY ou SELL
   int       p1_handle, p2_handle, p3_handle; // Handles de indicadores
};

// ---------- VARIÁVEIS GLOBAIS DE OPERAÇÃO ----------
Rule rules[MAX_RULES];
int nRules = 0;

double p_riskPercent = 1.0;
double p_stopPoints = 0;
double p_takePoints = 0;
double p_trailingStopPoints = 0;
double p_breakEvenPoints = 0;
double p_breakEvenTrigger = 0;
int    p_maxSimultaneousTrades = 3;
bool   p_useMartingale = false;
bool   p_hedge = true;
ENUM_TIMEFRAMES p_mainTF = PERIOD_CURRENT;

datetime p_startTime = 0;
datetime p_endTime = 0;
int p_startTimeSeconds = 0; // Segundos desde a meia-noite

int dynamicSafetyPoints = 0;
datetime lastBarTime = 0;
datetime lastCSVWrite = 0;

// Estatísticas
double s_winRate = 0;
double s_profitFactor = 0;
double s_drawdown = 0;

// Objetos MQL5
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;

// ---------- PROTÓTIPOS ----------
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
double CalculaLote(double riscoPercent);
void EnviaOrdem(Signal s);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaCSV();
void ResetStrategy();
void CalculaEstatisticas();
string ExtractNumber(string text, string key, int occurrence=1);
string ExtractTime(string text, string key);
ENUM_TIMEFRAMES PeriodoTexto(string nome);

//========================================================================

// ---------- INDICADORES E SINAIS ----------

Signal AvaliaRegra(int ruleIdx, int shift) {
   Rule r = rules[ruleIdx];
   if (!r.active) return NONE;

   switch (r.type) {
      case RULE_MA_CROSS: {
         double fast[], slow[];
         ArraySetAsSeries(fast, true); ArraySetAsSeries(slow, true);
         if (CopyBuffer(r.p1_handle, 0, shift, 2, fast) < 2) return NONE;
         if (CopyBuffer(r.p2_handle, 0, shift, 2, slow) < 2) return NONE;
         // Bullish Cross: fast crosses ABOVE slow
         if (fast[1] < slow[1] && fast[0] > slow[0]) return BUY;
         // Bearish Cross: fast crosses BELOW slow
         if (fast[1] > slow[1] && fast[0] < slow[0]) return SELL;
         break;
      }
      case RULE_RSI: {
         double rsi[]; ArraySetAsSeries(rsi, true);
         if (CopyBuffer(r.p1_handle, 0, shift, 2, rsi) < 2) return NONE;
         if (r.intent == BUY) {
            if (rsi[1] < r.d1 && rsi[0] > r.d1) return BUY; // Crossover Above
            if (rsi[0] > r.d1) return BUY; // Above threshold (momentum)
         }
         if (r.intent == SELL) {
            if (rsi[1] > r.d1 && rsi[0] < r.d1) return SELL; // Crossover Below
            if (rsi[0] < r.d1) return SELL; // Below threshold (momentum)
         }
         break;
      }
      case RULE_STOCH: {
         double k[], d[];
         ArraySetAsSeries(k, true); ArraySetAsSeries(d, true);
         if (CopyBuffer(r.p1_handle, 0, shift, 2, k) < 2) return NONE;
         if (CopyBuffer(r.p1_handle, 1, shift, 2, d) < 2) return NONE;
         if (k[1] < d[1] && k[0] > d[0]) return BUY;
         if (k[1] > d[1] && k[0] < d[0]) return SELL;
         break;
      }
      case RULE_BB: {
         double mid[], up[], lo[];
         ArraySetAsSeries(mid, true); ArraySetAsSeries(up, true); ArraySetAsSeries(lo, true);
         if (CopyBuffer(r.p1_handle, 0, shift, 1, mid) < 1) return NONE;
         if (CopyBuffer(r.p1_handle, 1, shift, 1, up) < 1) return NONE;
         if (CopyBuffer(r.p1_handle, 2, shift, 1, lo) < 1) return NONE;
         double close = iClose(_Symbol, r.tf, shift);
         if (close < lo[0]) return BUY;
         if (close > up[0]) return SELL;
         break;
      }
   }
   return NONE;
}

// ---------- NLP PARSER ----------

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   string segments[];
   ushort separators[] = {',', '.', ';', '+'};
   // First, find the main timeframe if any (e.g., "A cada 15 minutos")
   p_mainTF = PeriodoTexto(prompt);

   int nSeg = StringSplit(prompt, separators[0], segments);
   Signal currentIntent = NONE;

   for (int i=0; i<nSeg; i++) {
      string s = segments[i];
      StringToLower(s);
      StringTrimLeft(s); StringTrimRight(s);
      StringReplace(s, ",", "."); // Fix decimal comma

      // Detecta Intent (BUY/SELL)
      if (StringFind(s, "compra") >= 0) currentIntent = BUY;
      if (StringFind(s, "venda") >= 0) currentIntent = SELL;

      // Parâmetros de Gestão
      if (StringFind(s, "stop") >= 0 && StringFind(s, "move") < 0)
         p_stopPoints = StringToDouble(ExtractNumber(s, "stop"));
      if (StringFind(s, "take") >= 0)
         p_takePoints = StringToDouble(ExtractNumber(s, "take"));
      if (StringFind(s, "risco") >= 0)
         p_riskPercent = StringToDouble(ExtractNumber(s, "risco"));
      if (StringFind(s, "máximo") >= 0 && StringFind(s, "trades") >= 0)
         p_maxSimultaneousTrades = (int)StringToDouble(ExtractNumber(s, "máximo"));

      // Trailing e Breakeven
      if (StringFind(s, "atingir") >= 0 && StringFind(s, "move stop") >= 0) {
         p_breakEvenTrigger = StringToDouble(ExtractNumber(s, "atingir"));
         p_breakEvenPoints = StringToDouble(ExtractNumber(s, "entrada"));
      }

      // Horário
      if (StringFind(s, "depois das") >= 0) {
         string timeStr = ExtractTime(s, "depois das");
         p_startTimeSeconds = (int)StringToTime("1970.01.01 " + timeStr) % 86400;
      }

      // Regra: Média Móvel
      if (StringFind(s, "média") >= 0) {
         int period = (int)StringToDouble(ExtractNumber(s, "média"));
         if (period <= 0) period = 20;
         rules[nRules].active = true;
         rules[nRules].type = RULE_MA_CROSS;
         rules[nRules].p1 = period;
         rules[nRules].tf = p_mainTF;
         rules[nRules].intent = currentIntent;
         rules[nRules].p1_handle = iMA(_Symbol, p_mainTF, 1, 0, MODE_SMA, PRICE_CLOSE); // Price proxy (MA 1)
         rules[nRules].p2_handle = iMA(_Symbol, p_mainTF, period, 0, MODE_SMA, PRICE_CLOSE);
         nRules++;
      }

      // Regra: RSI
      if (StringFind(s, "rsi") >= 0) {
         int period = (int)StringToDouble(ExtractNumber(s, "rsi"));
         if (period <= 0) period = 14;
         double threshold = StringToDouble(ExtractNumber(s, "acima", 1));
         if (threshold == 0) threshold = StringToDouble(ExtractNumber(s, "abaixo", 1));
         rules[nRules].active = true;
         rules[nRules].type = RULE_RSI;
         rules[nRules].p1 = period;
         rules[nRules].d1 = threshold;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_mainTF;
         rules[nRules].p1_handle = iRSI(_Symbol, p_mainTF, period, PRICE_CLOSE);
         nRules++;
      }
   }
}

// UTILS PARA NLP
string ExtractNumber(string text, string key, int occurrence=1) {
   int pos = StringFind(text, key);
   if (pos < 0) return "0";
   string sub = StringSubstr(text, pos + StringLen(key));
   string res = "";
   bool found = false;
   for (int i=0; i<StringLen(sub); i++) {
      ushort c = sub[i];
      if ((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         found = true;
      } else if (found) break;
   }
   return (res == "") ? "0" : res;
}

string ExtractTime(string text, string key) {
   int pos = StringFind(text, key);
   if (pos < 0) return "00:00";
   string sub = StringSubstr(text, pos + StringLen(key));
   StringTrimLeft(sub);
   string res = StringSubstr(sub, 0, 5);
   StringReplace(res, "h", ":00");
   if (StringLen(res) < 5) res += ":00";
   return res;
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
   StringToLower(nome);
   if (StringFind(nome, "m15") >= 0 || StringFind(nome, "15 minutos") >= 0) return PERIOD_M15;
   if (StringFind(nome, "m5") >= 0 || StringFind(nome, "5 minutos") >= 0) return PERIOD_M5;
   if (StringFind(nome, "m1") >= 0 || StringFind(nome, "1 minuto") >= 0) return PERIOD_M1;
   if (StringFind(nome, "h1") >= 0 || StringFind(nome, "1 hora") >= 0) return PERIOD_H1;
   if (StringFind(nome, "d1") >= 0 || StringFind(nome, "diário") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

// ---------- DECISÃO E EXECUÇÃO ----------

Signal AvaliaTudo() {
   if (nRules == 0) return NONE;

   // AND logic for Confluence:
   // We group rules by intent (BUY or SELL) and they must all agree within that group
   bool buyPossible = false, sellPossible = false;
   bool buyAgreement = true, sellAgreement = true;
   int buyCount = 0, sellCount = 0;

   for (int i=0; i<nRules; i++) {
      Signal s = AvaliaRegra(i, 1);
      if (rules[i].intent == BUY) {
         buyCount++;
         if (s != BUY) buyAgreement = false;
         else buyPossible = true;
      }
      if (rules[i].intent == SELL) {
         sellCount++;
         if (s != SELL) sellAgreement = false;
         else sellPossible = true;
      }
   }

   if (buyCount > 0 && buyAgreement) return BUY;
   if (sellCount > 0 && sellAgreement) return SELL;

   return NONE;
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double stop = MathMax(p_stopPoints, (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 1));
   if (stop <= 0) stop = 100; // default 100 points
   double volume = riscoAbs / (stop * (tickVal / (tickSize / _Point)) * _Point);
   return NormalizeDouble(volume, 2);
}

void EnviaOrdem(Signal s) {
   if (s == NONE || AguardaNoticias()) return;
   if (PositionsTotal() >= p_maxSimultaneousTrades) return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double price = (s == BUY) ? ask : bid;
   double stop = MathMax(p_stopPoints, (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 1)) * _Point;
   double take = p_takePoints * _Point;

   double sl = (s == BUY) ? price - stop : price + stop;
   double tp = (s == BUY) ? price + take : price - take;
   if (p_takePoints == 0) tp = 0;

   double lot = CalculaLote(p_riskPercent);

   if (!p_hedge) {
      for (int i=PositionsTotal()-1; i>=0; i--) {
         if (posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) {
            if ((s == BUY && posInfo.PositionType() == POSITION_TYPE_SELL) ||
                (s == SELL && posInfo.PositionType() == POSITION_TYPE_BUY))
               trade.PositionClose(posInfo.Ticket());
         }
      }
   }

   trade.SetExpertMagicNumber(EA_MAGIC);
   bool success = false;
   if (s == BUY) success = trade.Buy(lot, _Symbol, price, sl, tp, "Prompt Execute");
   else success = trade.Sell(lot, _Symbol, price, sl, tp, "Prompt Execute");

   if (success) SendNotification("MT-LiveExecutor: Ordem de " + ((s==BUY)?"COMPRA":"VENDA") + " enviada em " + _Symbol);
}

void GerenciaPosicoes() {
   for (int i=PositionsTotal()-1; i>=0; i--) {
      if (posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
         double open = posInfo.PriceOpen();
         double current = posInfo.PriceCurrent();
         double sl = posInfo.StopLoss();
         double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                               (current - open) / _Point : (open - current) / _Point;

         // Break-even
         if (p_breakEvenTrigger > 0 && profitPoints >= p_breakEvenTrigger) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                           open + p_breakEvenPoints * _Point : open - p_breakEvenPoints * _Point;
            if (sl == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > sl) ||
                (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < sl || sl == 0)))
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
         }

         // Trailing Stop
         if (p_trailingStopPoints > 0 && profitPoints >= p_trailingStopPoints) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                           current - p_trailingStopPoints * _Point : current + p_trailingStopPoints * _Point;
            if (sl == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > sl) ||
                (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < sl || sl == 0)))
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
         }
      }
   }
}

bool AguardaNoticias() {
   // Logic: check news_veto.txt
   // If it contains "1", it's a generic veto.
   // Advanced: If it contains timestamps, check +/- 20 min.
   string path = "news_veto.txt";
   int handle = FileOpen(path, FILE_READ | FILE_TXT | FILE_COMMON);
   if (handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if (content == "1") return true;

      // Time-based veto (format: UNIX_TIMESTAMP in file)
      long newsTime = StringToInteger(content);
      if (newsTime > 0) {
         long now = TimeCurrent();
         if (now >= newsTime - 20*60 && now <= newsTime + 20*60) return true;
      }
   }
   return false;
}

void GravaCSV() {
   if (TimeCurrent() - lastCSVWrite < 5) return;
   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI);
   if (handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Price", "SL", "TP", "Time", "Reason", "WinRate", "PF");
      for (int i=0; i<PositionsTotal(); i++) {
         if (posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC)
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PriceOpen(),
                      posInfo.StopLoss(), posInfo.TakeProfit(), posInfo.Time(), posInfo.Comment(), s_winRate, s_profitFactor);
      }
      FileClose(handle);
      lastCSVWrite = TimeCurrent();
   }
}

void ResetStrategy() {
   for (int i=0; i<nRules; i++) {
      if (rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if (rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if (rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
   ZeroMemory(rules);
   nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 0; p_takePoints = 0;
   p_trailingStopPoints = 0; p_breakEvenPoints = 0; p_breakEvenTrigger = 0;
   p_mainTF = PERIOD_CURRENT;
}

void CalculaEstatisticas() {
   HistorySelect(TimeCurrent() - 86400 * 30, TimeCurrent());
   int total = HistoryDealsTotal();
   int wins = 0, losses = 0;
   double grossProfit = 0, grossLoss = 0;
   for (int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if (HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC &&
          HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
         if (p > 0) { wins++; grossProfit += p; }
         else if (p < 0) { losses++; grossLoss += MathAbs(p); }
      }
   }
   if (wins + losses > 0) s_winRate = (double)wins / (wins + losses) * 100.0;
   if (grossLoss > 0) s_profitFactor = grossProfit / grossLoss;
}

// ---------- EVENTOS DO EXPERT ----------

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(5);

   int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
   if (handle != INVALID_HANDLE) {
      string prompt = FileReadString(handle);
      InterpretaPrompt(prompt);
      FileClose(handle);
   }
   CalculaEstatisticas();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {
   ResetStrategy();
   EventKillTimer();
}

void OnTick() {
   GerenciaPosicoes();
   GravaCSV();

   datetime currentBarTime = iTime(_Symbol, p_mainTF, 0);
   if (currentBarTime != lastBarTime) {
      lastBarTime = currentBarTime;
      CalculaEstatisticas();

      if (p_startTimeSeconds > 0) {
         int nowSeconds = (int)TimeCurrent() % 86400;
         if (nowSeconds < p_startTimeSeconds) return;
      }

      Signal s = AvaliaTudo();
      if (s != NONE) EnviaOrdem(s);
   }
}

void OnTimer() {
   double updateVal = GlobalVariableGet("MT_Executor_Prompt_Update");
   if (updateVal > 0) {
      int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT | FILE_ANSI);
      if (handle != INVALID_HANDLE) {
         string prompt = FileReadString(handle);
         InterpretaPrompt(prompt);
         FileClose(handle);
         Print("Estratégia atualizada!");
      }
      GlobalVariableSet("MT_Executor_Prompt_Update", 0);
   }
   if (dynamicSafetyPoints > 0) dynamicSafetyPoints--;
}
