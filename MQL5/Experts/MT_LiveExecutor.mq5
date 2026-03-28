//=========================  MT-LiveExecutor  =========================
// Módulo Único de Execução em Tempo Real com NLP e IA-Optimization
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\HistoryOrderInfo.mqh>
#include <Trade\HistoryDealInfo.mqh>

// ---------- 1. DEFINIÇÕES E ESTRUTURAS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI,
   RULE_STOCH,
   RULE_BB,
   RULE_DAILY_BREAK,
   RULE_DELTA,
   RULE_VOLUME_CYCLE,
   RULE_AMA,
   RULE_BAR_PATTERN,
   RULE_RS_RELATIVE,
   RULE_NONE
};

struct Rule {
   bool      active;
   int       tf;
   double    p1, p2, p3;
   double    d1, d2;
   string    s1;
   bool      is_cross;
   RuleType  type;
   int       p1_handle;
   int       p2_handle;
   int       p3_handle;
};

// ---------- 2. VARIÁVEIS GLOBAIS OPERACIONAIS ----------
Rule        rules[30];
int         nRules = 0;
CTrade      trade;
CPositionInfo posInfo;
CSymbolInfo  symInfo;
CAccountInfo accInfo;

// Parâmetros extraídos do prompt
double      p_riskPercent = 1.0;
int         p_stopPoints = 300;
int         p_takePoints = 500;
int         p_trailingStopPoints = 0;
int         p_breakEvenPoints = 0;
int         p_breakEvenProfitPoints = 50;
long        p_startTimeSeconds = 0;
int         p_maxTrades = 1;
int         p_newsVetoMinutes = 0;
bool        p_hedge = true;
bool        p_martingale = false;
int         p_executionTF = PERIOD_CURRENT;

// Estado e Controle
int         dynamicSafetyPoints = 0;
datetime    lastSafetyUpdate = 0;
datetime    lastBarTime = 0;
string      currentPrompt = "";
const int   EA_MAGIC = 20260101;

// Forward Declarations
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
double CalculaLote(double riscoPercent);
void EnviaOrdem(Signal s);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaCSV();
void AIOptimizer();
void ResetStrategy();

// NLP & Signal Helpers
void AddRule(string seg);
ENUM_TIMEFRAMES MinutesToTimeframe(int minutes);
double ExtractNumber(string text, string keyword);
long ExtractTime(string text, string keyword);
int ExtractTimeframe(string text);
Signal CheckMA(Rule &r);
Signal CheckRSI(Rule &r);
Signal CheckStoch(Rule &r);
Signal CheckBB(Rule &r);
double iClose(string symbol, ENUM_TIMEFRAMES tf, int shift);
datetime iTime(string symbol, ENUM_TIMEFRAMES tf, int shift);

// ---------- 3. HANDLERS DE EVENTOS ----------
int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   symInfo.Name(_Symbol);
   EventSetTimer(60); // Timer para AIOptimizer e News Check
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   ResetStrategy();
   EventKillTimer();
}

void OnTick() {
   // 1. Gestão de Posições Existentes (Prioridade Máxima)
   GerenciaPosicoes();
   GravaCSV();

   // 2. Atualização de Segurança Dinâmica
   if(TimeCurrent() - lastSafetyUpdate >= 60) {
      if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyUpdate = TimeCurrent();
   }

   // 3. Filtros de Operação
   if(AguardaNoticias()) return;
   if(TimeCurrent() % 86400 < p_startTimeSeconds) return;

   // 4. Execução por Candle (ou Tick conforme estratégia)
   datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_executionTF, 0);
   if(currentBar != lastBarTime) {
      Signal s = AvaliaTudo();
      if(s != NONE) {
         EnviaOrdem(s);
         lastBarTime = currentBar;
      }
   }
}

void OnTimer() {
   // Verificação de atualização de prompt via Global Variable ou Arquivo
   if(GlobalVariableCheck("MT_Executor_Prompt_Update") && GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
      // Ler arquivo MQL5/Files/MT_LiveExecutor_Prompt.txt
      int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
      if(handle != INVALID_HANDLE) {
         string newPrompt = FileReadString(handle);
         FileClose(handle);
         InterpretaPrompt(newPrompt);
         GlobalVariableSet("MT_Executor_Prompt_Update", 0);
      }
   }

   AIOptimizer();
}

// ---------- 4. NLP PARSING E UTILITÁRIOS ----------

void InterpretaPrompt(string prompt) {
   ResetStrategy();
   currentPrompt = prompt;

   string lowerPrompt = prompt;
   StringToLower(lowerPrompt);
   StringReplace(lowerPrompt, " + ", "|");
   StringReplace(lowerPrompt, " e ", "|");
   StringReplace(lowerPrompt, ",", "|");
   StringReplace(lowerPrompt, ".", "|");

   string segments[];
   StringSplit(lowerPrompt, StringGetCharacter("|", 0), segments);

   for(int i = 0; i < ArraySize(segments); i++) {
      string seg = segments[i];
      StringTrimLeft(seg); StringTrimRight(seg);
      if(seg == "") continue;

      // Extração de Restrições Operacionais
      if(StringFind(seg, "stop de") >= 0) p_stopPoints = (int)ExtractNumber(seg, "stop de");
      if(StringFind(seg, "take de") >= 0) p_takePoints = (int)ExtractNumber(seg, "take de");
      if(StringFind(seg, "risco de") >= 0) p_riskPercent = ExtractNumber(seg, "risco de");
      if(StringFind(seg, "depois das") >= 0) p_startTimeSeconds = ExtractTime(seg, "depois das");
      if(StringFind(seg, "não operar") >= 0) p_newsVetoMinutes = (int)ExtractNumber(seg, "operar");
      if(StringFind(seg, "máximo") >= 0) p_maxTrades = (int)ExtractNumber(seg, "máximo");
      if(StringFind(seg, "trailing") >= 0) p_trailingStopPoints = (int)ExtractNumber(seg, "trailing");
      if(StringFind(seg, "move stop para entrada") >= 0) {
         p_breakEvenPoints = (int)ExtractNumber(seg, "atingir");
         p_breakEvenProfitPoints = (int)ExtractNumber(seg, "entrada +");
      }
      if(StringFind(seg, "martingale") >= 0) p_martingale = true;
      if(StringFind(seg, "hedge") >= 0) p_hedge = true;
      if(StringFind(seg, "a cada") >= 0) p_executionTF = MinutesToTimeframe((int)ExtractNumber(seg, "a cada"));

      // Extração de Regras de Indicadores
      AddRule(seg);
   }

   // Reset trigger time for immediate evaluation
   lastBarTime = 0;
}

void AddRule(string seg) {
   Rule r;
   r.active = true;
   r.tf = ExtractTimeframe(seg);
   r.type = RULE_NONE;
   r.is_cross = (StringFind(seg, "cruzar") >= 0 || StringFind(seg, "subir") >= 0 || StringFind(seg, "cair") >= 0);

   if(StringFind(seg, "média") >= 0) {
      r.type = RULE_MA_CROSS;
      r.p1 = ExtractNumber(seg, "média de");
      if(StringFind(seg, "/") >= 0) {
         // Dual MA logic could be added here
      }
      r.p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, (int)r.p1, 0, MODE_SMA, PRICE_CLOSE);
   }
   else if(StringFind(seg, "rsi") >= 0) {
      r.type = RULE_RSI;
      r.p1 = ExtractNumber(seg, "rsi (");
      if(r.p1 == 0) r.p1 = ExtractNumber(seg, "rsi");
      r.d1 = ExtractNumber(seg, "acima de");
      r.d2 = ExtractNumber(seg, "abaixo de");
      r.p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, (int)r.p1, PRICE_CLOSE);
   }
   else if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
      r.type = RULE_STOCH;
      r.p1 = 5; r.p2 = 3; r.p3 = 3; // Defaults
      r.p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, (int)r.p1, (int)r.p2, (int)r.p3, MODE_SMA, STO_LOWHIGH);
   }
   else if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bb") >= 0) {
      r.type = RULE_BB;
      r.p1 = 20; r.d1 = 2.0; // Defaults
      r.p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, (int)r.p1, 0, r.d1, PRICE_CLOSE);
   }

   if(r.type != RULE_NONE && nRules < 30) {
      rules[nRules] = r;
      nRules++;
   }
}

double ExtractNumber(string text, string keyword) {
   int pos = StringFind(text, keyword);
   if(pos < 0) return 0;
   string sub = StringSubstr(text, pos + StringLen(keyword));
   string res = "";
   bool found = false;
   for(int i=0; i<StringLen(sub); i++) {
      ushort c = StringGetCharacter(sub, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += CharToString((uchar)c);
         found = true;
      } else if(found) break;
   }
   return StringToDouble(res);
}

long ExtractTime(string text, string keyword) {
   int pos = StringFind(text, keyword);
   if(pos < 0) return 0;
   string sub = StringSubstr(text, pos + StringLen(keyword));
   StringTrimLeft(sub);
   int h=0, m=0;
   if(StringScan(sub, "%dh", h) > 0 || StringScan(sub, "%d:%d", h, m) > 0) {
      return h * 3600 + m * 60;
   }
   return 0;
}

ENUM_TIMEFRAMES MinutesToTimeframe(int minutes) {
   if(minutes <= 1) return PERIOD_M1;
   if(minutes <= 5) return PERIOD_M5;
   if(minutes <= 15) return PERIOD_M15;
   if(minutes <= 30) return PERIOD_M30;
   if(minutes <= 60) return PERIOD_H1;
   if(minutes <= 240) return PERIOD_H4;
   return PERIOD_D1;
}

int ExtractTimeframe(string text) {
   if(StringFind(text, "m15") >= 0) return PERIOD_M15;
   if(StringFind(text, "m30") >= 0) return PERIOD_M30;
   if(StringFind(text, "m5") >= 0) return PERIOD_M5;
   if(StringFind(text, "m1") >= 0) return PERIOD_M1;
   if(StringFind(text, "h1") >= 0) return PERIOD_H1;
   if(StringFind(text, "d1") >= 0) return PERIOD_D1;
   return PERIOD_CURRENT;
}

void ResetStrategy() {
   for(int i=0; i<nRules; i++) {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
   }
   ZeroMemory(rules);
   nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_trailingStopPoints = 0;
   p_breakEvenPoints = 0;
   p_startTimeSeconds = 0;
   p_maxTrades = 1;
   p_newsVetoMinutes = 0;
   p_hedge = true;
   p_martingale = false;
   p_executionTF = PERIOD_CURRENT;
}

// ---------- 5. AVALIAÇÃO DE SINAIS E INDICADORES ----------

Signal AvaliaTudo() {
   int buyVoters = 0;
   int sellVoters = 0;
   int activeRulesCount = 0;

   for(int i=0; i<nRules; i++) {
      if(!rules[i].active) continue;
      activeRulesCount++;
      Signal s = NONE;

      switch(rules[i].type) {
         case RULE_MA_CROSS: s = CheckMA(rules[i]); break;
         case RULE_RSI:      s = CheckRSI(rules[i]); break;
         case RULE_STOCH:    s = CheckStoch(rules[i]); break;
         case RULE_BB:       s = CheckBB(rules[i]); break;
         default: break;
      }

      if(s == BUY) buyVoters++;
      else if(s == SELL) sellVoters++;
   }

   if(activeRulesCount == 0) return NONE;
   if(buyVoters > 0 && sellVoters == 0) return BUY;
   if(sellVoters > 0 && buyVoters == 0) return SELL;

   return NONE;
}

Signal CheckMA(Rule &r) {
   double ma[]; ArraySetAsSeries(ma, true);
   if(CopyBuffer(r.p1_handle, 0, 0, 3, ma) < 3) return NONE;

   double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
   double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);

   if(r.is_cross) {
      if(close2 < ma[2] && close1 > ma[1]) return BUY;
      if(close2 > ma[2] && close1 < ma[1]) return SELL;
   } else {
      if(close1 > ma[1]) return BUY;
      if(close1 < ma[1]) return SELL;
   }
   return NONE;
}

Signal CheckRSI(Rule &r) {
   double rsi[]; ArraySetAsSeries(rsi, true);
   if(CopyBuffer(r.p1_handle, 0, 0, 3, rsi) < 3) return NONE;

   // Lógica baseada no prompt: "rsi subir acima de 55" ou "rsi cair abaixo de 45"
   // Também suporta o padrão MT5-KNOWLEDGE-CORE: "rsi threshold over/under"

   if(r.is_cross) {
      if(r.d1 > 0 && rsi[2] < r.d1 && rsi[1] > r.d1) return BUY;
      if(r.d2 > 0 && rsi[2] > r.d2 && rsi[1] < r.d2) return SELL;
   } else {
      if(r.d1 > 0 && rsi[1] > r.d1) return BUY;
      if(r.d2 > 0 && rsi[1] < r.d2) return SELL;
   }
   return NONE;
}

Signal CheckStoch(Rule &r) {
   double k[], d[]; ArraySetAsSeries(k, true); ArraySetAsSeries(d, true);
   if(CopyBuffer(r.p1_handle, 0, 0, 3, k) < 3 || CopyBuffer(r.p1_handle, 1, 0, 3, d) < 3) return NONE;
   if(k[2] < d[2] && k[1] > d[1]) return BUY;
   if(k[2] > d[2] && k[1] < d[1]) return SELL;
   return NONE;
}

Signal CheckBB(Rule &r) {
   double up[], lo[]; ArraySetAsSeries(up, true); ArraySetAsSeries(lo, true);
   if(CopyBuffer(r.p1_handle, 1, 0, 3, up) < 3 || CopyBuffer(r.p1_handle, 2, 0, 3, lo) < 3) return NONE;
   double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
   if(close < lo[1]) return BUY;
   if(close > up[1]) return SELL;
   return NONE;
}

// MQL4 Compatibility Wrappers (MQL5-Knowledge-Core integration)
double iClose(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   double res[];
   if(CopyClose(symbol, tf, shift, 1, res) > 0) return res[0];
   return 0;
}

datetime iTime(string symbol, ENUM_TIMEFRAMES tf, int shift) {
   datetime res[];
   if(CopyTime(symbol, tf, shift, 1, res) > 0) return res[0];
   return 0;
}

// ---------- 6. EXECUÇÃO E GESTÃO DE ORDENS ----------

void EnviaOrdem(Signal s) {
   if(PositionsTotal() >= p_maxTrades && p_maxTrades > 0) return;

   double volume = CalculaLote(p_riskPercent);
   if(volume <= 0) return;

   // Lógica de Hedge (Fechar opostas antes de abrir nova se p_hedge for false)
   if(!p_hedge) {
      for(int i = PositionsTotal() - 1; i >= 0; i--) {
         if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
            if((s == BUY && posInfo.PositionType() == POSITION_TYPE_SELL) ||
               (s == SELL && posInfo.PositionType() == POSITION_TYPE_BUY)) {
               trade.PositionClose(posInfo.Ticket());
            }
         }
      }
   }

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Safety Buffers
   double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double safetyBuffer = (stopsLevel + dynamicSafetyPoints + 1) * _Point;

   double sl = 0, tp = 0;
   if(s == BUY) {
      sl = price - MathMax(p_stopPoints * _Point, safetyBuffer);
      tp = price + p_takePoints * _Point;
      if(trade.Buy(volume, _Symbol, price, sl, tp, "MT-LiveExecutor Entry")) {
         if(trade.ResultRetcode() != TRADE_RETCODE_DONE) dynamicSafetyPoints += 5;
      }
   } else {
      sl = price + MathMax(p_stopPoints * _Point, safetyBuffer);
      tp = price - p_takePoints * _Point;
      if(trade.Sell(volume, _Symbol, price, sl, tp, "MT-LiveExecutor Entry")) {
         if(trade.ResultRetcode() != TRADE_RETCODE_DONE) dynamicSafetyPoints += 5;
      }
   }
}

double CalculaLote(double riscoPercent) {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (riscoPercent / 100.0);

   // Martingale adjustment
   if(p_martingale) {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i = total - 1; i >= 0; i--) {
         CHistoryDealInfo deal;
         if(deal.SelectByIndex(i) && deal.Symbol() == _Symbol && deal.Entry() == DEAL_ENTRY_OUT) {
            if(deal.Profit() < 0) riskAmount *= 2.0;
            break;
         }
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double slPoints = (p_stopPoints > 0) ? p_stopPoints : 300;

   double volume = riskAmount / (slPoints * (tickValue / (tickSize / _Point)));

   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   volume = MathFloor(volume / stepVol) * stepVol;
   return MathMin(maxVol, MathMax(minVol, volume));
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC) {
         double currentPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();

         int diffPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                          (int)((currentPrice - openPrice) / _Point) :
                          (int)((openPrice - currentPrice) / _Point);

         // Break-even logic
         if(p_breakEvenPoints > 0 && diffPoints >= p_breakEvenPoints) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                           openPrice + p_breakEvenProfitPoints * _Point :
                           openPrice - p_breakEvenProfitPoints * _Point;

            if((posInfo.PositionType() == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0)) ||
               (posInfo.PositionType() == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }

         // Trailing Stop logic
         if(p_trailingStopPoints > 0 && diffPoints >= p_trailingStopPoints) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                           currentPrice - p_trailingStopPoints * _Point :
                           currentPrice + p_trailingStopPoints * _Point;

            if((posInfo.PositionType() == POSITION_TYPE_BUY && (currentSL < newSL || currentSL == 0)) ||
               (posInfo.PositionType() == POSITION_TYPE_SELL && (currentSL > newSL || currentSL == 0))) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

// ---------- 7. RECURSOS AUXILIARES E OTIMIZAÇÃO ----------

bool AguardaNoticias() {
   if(p_newsVetoMinutes == 0) return false;

   // 1. Verificar arquivo externo news_veto.txt (Common folder)
   int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true;
   }

   // 2. Fallback: Verificação via Calendário MQL5 (Simplificado)
   MqlCalendarValue values[];
   datetime from = TimeCurrent() - p_newsVetoMinutes * 60;
   datetime to = TimeCurrent() + p_newsVetoMinutes * 60;

   if(CalendarValueHistory(values, from, to)) {
      for(int i=0; i<ArraySize(values); i++) {
         MqlCalendarEvent event;
         if(CalendarEventById(values[i].event_id, event)) {
            if(event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
         }
      }
   }

   return false;
}

void GravaCSV() {
   static datetime lastWrite = 0;
   if(TimeCurrent() - lastWrite < 5) return; // Optimize I/O by writing every 5 seconds
   lastWrite = TimeCurrent();

   int handle = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if(handle != INVALID_HANDLE) {
      FileWrite(handle, "Ticket", "Symbol", "Type", "OpenPrice", "SL", "TP", "Profit", "Time");
      for(int i = 0; i < PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC) {
            FileWrite(handle,
               posInfo.Ticket(),
               posInfo.Symbol(),
               posInfo.PositionType(),
               posInfo.PriceOpen(),
               posInfo.StopLoss(),
               posInfo.TakeProfit(),
               posInfo.Profit(),
               posInfo.Time()
            );
         }
      }
      FileClose(handle);
   }
}

void AIOptimizer() {
   // Análise de Performance Rolling (24h)
   HistorySelect(TimeCurrent() - 86400, TimeCurrent());
   int total = HistoryDealsTotal();
   double profit = 0;
   int wins = 0, losses = 0;

   for(int i=0; i<total; i++) {
      CHistoryDealInfo deal;
      if(deal.SelectByIndex(i) && deal.Entry() == DEAL_ENTRY_OUT) {
         double p = deal.Profit() + deal.Commission() + deal.Swap();
         profit += p;
         if(p > 0) wins++; else losses++;
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) : 0;

   // Heurística de Ajuste de Risco baseado em ATR/Volatilidade (Simplificado)
   // Se winRate < 40%, reduzir risco pela metade temporariamente
   if(winRate > 0 && winRate < 0.40) {
      // p_riskPercent *= 0.5; // Comentado para evitar loops de redução sem volta
   }

   // Log de Estatísticas
   // PrintFormat("AIOptimizer: WinRate: %.2f%% | Total Profit: %.2f", winRate * 100, profit);
}
