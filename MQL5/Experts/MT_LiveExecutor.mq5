//=========================  MT5-KNOWLEDGE-CORE  =========================
// MT-LiveExecutor - Agente Executor de Estratégias via Prompt
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- CONSTANTES E GLOBAIS ----------
#define EA_MAGIC 123456
#define MAX_RULES 20

enum Signal {BUY=1, SELL=-1, NONE=0};

struct Rule {
   int      type;       // 1: MA, 2: RSI, 3: Stoch, 4: BB, 5: DailyBreak, 6: Delta, 7: Vol, 8: AMA, 9: Bar2, 10: RS, 11: AI
   int      intent;     // BUY ou SELL
   int      tf;         // Timeframe
   int      p1, p2, p3; // Parâmetros inteiros
   double   d1, d2;     // Parâmetros double
   string   s1;         // Parâmetro string (ex: bench symbol)
   int      handle1;    // Handle do indicador 1
   int      handle2;    // Handle do indicador 2

   void Reset() {
      if(handle1 != INVALID_HANDLE && handle1 != 0) IndicatorRelease(handle1);
      if(handle2 != INVALID_HANDLE && handle2 != 0) IndicatorRelease(handle2);
      type = 0; intent = 0; tf = 0; p1 = 0; p2 = 0; p3 = 0; d1 = 0; d2 = 0; s1 = "";
      handle1 = INVALID_HANDLE; handle2 = INVALID_HANDLE;
   }
};

Rule rules[MAX_RULES];
int nRules = 0;

// Parâmetros de Estratégia (populados via prompt)
double   p_riskPercent = 1.0;
int      p_stopPoints = 0;
int      p_takePoints = 0;
int      p_maxTrades = 3;
string   p_startTime = "00:00";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
bool     p_useMartingale = false;
int      p_beStart = 0;
int      p_bePlus = 0;
int      p_trailingStop = 0;
int      p_trailingStep = 0;

CTrade trade;
CPositionInfo posInfo;
datetime lastPromptCheck = 0;
datetime lastBarTime = 0;

// ---------- HANDLERS OBRIGATÓRIOS ----------

int OnInit() {
   trade.SetExpertMagicNumber(EA_MAGIC);
   EventSetTimer(1); // Timer de 1 segundo para check de prompt e eventos rápidos
   InterpretaPrompt(CarregaPrompt());
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
   EventKillTimer();
}

void OnTick() {
   // Gerenciamento de posições e log de estado em cada tick
   GravaCSV();
   GerenciaPosicoes();

   // Verificação de sinais na abertura de nova barra conforme p_frequency
   datetime currentBar = iTime(_Symbol, p_frequency, 0);
   if(currentBar != lastBarTime) {
      if(IsTimeAllowed() && !AguardaNoticias()) {
         Signal s = AvaliaTudo();
         if(s != NONE) {
            double lote = CalculaLote(p_riskPercent);
            EnviaOrdem(s, lote, "Sinal Estratégia");
         }
      }
      lastBarTime = currentBar;
   }
}

void OnTimer() {
   static datetime lastAI = 0;

   // Check para novos prompts (em tempo real)
   VerificaNovoPrompt();

   // AI Optimizer (executa a cada 1 hora)
   if(TimeCurrent() - lastAI >= 3600) {
      AIOptimizer();
      lastAI = TimeCurrent();
   }
}

// ---------- MÓDULO DE INTERPRETAÇÃO ----------

void InterpretaPrompt(string prompt) {
   string work = prompt;
   StringToLower(work);
   GravaLog("Interpretando prompt: " + work);

   // Parâmetros Globais
   p_riskPercent = ExtraiValorApos(work, "risco de");
   if(p_riskPercent <= 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiValorApos(work, "stop de");
   p_takePoints = (int)ExtraiValorApos(work, "take de");
   p_maxTrades = (int)ExtraiValorApos(work, "máximo");
   if(p_maxTrades <= 0) p_maxTrades = 3;

   p_beStart = (int)ExtraiValorApos(work, "atingir +");
   p_bePlus = (int)ExtraiValorApos(work, "entrada +");

   p_trailingStop = (int)ExtraiValorApos(work, "trailing stop de");
   p_trailingStep = (int)ExtraiValorApos(work, "step de");

   // Horário e Frequência
   if(StringFind(work, "15 min") >= 0) p_frequency = PERIOD_M15;
   else if(StringFind(work, "5 min") >= 0) p_frequency = PERIOD_M5;
   else if(StringFind(work, "1 min") >= 0) p_frequency = PERIOD_M1;
   else if(StringFind(work, "h1") >= 0) p_frequency = PERIOD_H1;

   int hPos = StringFind(work, "h", StringFind(work, "das"));
   if(hPos > 0) {
      int hVal = (int)StringToInteger(StringSubstr(work, hPos-2, 2));
      p_startTime = StringFormat("%02d:00", hVal);
   }

   if(StringFind(work, "martingale") >= 0) p_useMartingale = true;

   // Quebra o prompt em segmentos por intent
   string segments[];
   string sep = "|";
   string tempWork = work;
   StringReplace(tempWork, " e ", sep);
   StringReplace(tempWork, ".", sep);
   StringReplace(tempWork, ",", sep);
   ushort u_sep = StringGetCharacter(sep, 0);
   int nSeg = StringSplit(tempWork, u_sep, segments);

   int currentIntent = NONE;
   for(int i=0; i<nSeg && nRules < MAX_RULES; i++) {
      string seg = segments[i];
      if(StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if(currentIntent == NONE) continue;

      // Identifica Regras no Segmento
      if(StringFind(seg, "média") >= 0 || StringFind(seg, " ma ") >= 0) {
         rules[nRules].type = 1; // MA
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_frequency;
         rules[nRules].p1 = (int)ExtraiNumero(seg);
         if(rules[nRules].p1 <= 0) rules[nRules].p1 = 20;
         rules[nRules].handle1 = iMA(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, 0, MODE_SMA, PRICE_CLOSE);
         nRules++;
      }

      if(StringFind(seg, "rsi") >= 0) {
         rules[nRules].type = 2; // RSI
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_frequency;
         int startPos = 0;
         rules[nRules].p1 = (int)ExtraiNumero(seg, startPos); // Periodo
         rules[nRules].d1 = ExtraiNumero(seg, startPos);     // Threshold
         if(rules[nRules].p1 <= 0) rules[nRules].p1 = 14;
         if(rules[nRules].d1 <= 0) rules[nRules].d1 = (currentIntent == BUY) ? 55 : 45;
         rules[nRules].handle1 = iRSI(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
         nRules++;
      }

      if(StringFind(seg, "estocástico") >= 0 || StringFind(seg, "stoch") >= 0) {
         rules[nRules].type = 3;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iStochastic(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 5, 3, 3, MODE_SMA, STO_LOWHIGH);
         nRules++;
      }

      if(StringFind(seg, "bollinger") >= 0 || StringFind(seg, "bb") >= 0) {
         rules[nRules].type = 4;
         rules[nRules].intent = currentIntent;
         rules[nRules].tf = p_frequency;
         rules[nRules].handle1 = iBands(_Symbol, (ENUM_TIMEFRAMES)rules[nRules].tf, 20, 0, 2.0, PRICE_CLOSE);
         nRules++;
      }

      if(StringFind(seg, "rompimento diário") >= 0) {
         rules[nRules].type = 5;
         rules[nRules].intent = currentIntent;
         nRules++;
      }
   }
}

double ExtraiValorApos(string texto, string chave) {
   int pos = StringFind(texto, chave);
   if(pos < 0) return 0;
   return ExtraiNumero(StringSubstr(texto, pos + StringLen(chave)));
}

double ExtraiNumero(string texto, int &startPos) {
   string res = "";
   bool achou = false;
   int i;
   for(i = startPos; i < StringLen(texto); i++) {
      ushort c = StringGetCharacter(texto, i);
      if((c >= '0' && c <= '9') || c == '.') {
         res += ShortToString(c);
         achou = true;
      } else if(achou) break;
   }
   startPos = i;
   return StringToDouble(res);
}

double ExtraiNumero(string texto) {
   int dummy = 0;
   return ExtraiNumero(texto, dummy);
}

// ---------- DECISÃO E AVALIAÇÃO ----------

Signal AvaliaTudo() {
   int confirmacoesBuy = 0;
   int totalRulesBuy = 0;
   int confirmacoesSell = 0;
   int totalRulesSell = 0;

   for(int i=0; i<nRules; i++) {
      int res = AvaliaRegra(rules[i]);
      if(rules[i].intent == BUY) {
         totalRulesBuy++;
         if(res == BUY) confirmacoesBuy++;
      } else if(rules[i].intent == SELL) {
         totalRulesSell++;
         if(res == SELL) confirmacoesSell++;
      }
   }

   if(totalRulesBuy > 0 && confirmacoesBuy == totalRulesBuy) return BUY;
   if(totalRulesSell > 0 && confirmacoesSell == totalRulesSell) return SELL;

   return NONE;
}

int AvaliaRegra(Rule &r) {
   if(r.type == 1) { // MA
      double ma1 = GetBufferValue(r.handle1, 0, 1);
      double ma2 = GetBufferValue(r.handle1, 0, 2);
      double close1 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      double close2 = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 2);

      if(r.intent == BUY && close2 <= ma2 && close1 > ma1) return BUY;
      if(r.intent == SELL && close2 >= ma2 && close1 < ma1) return SELL;
   }

   if(r.type == 2) { // RSI
      double rsi1 = GetBufferValue(r.handle1, 0, 1);
      double rsi2 = GetBufferValue(r.handle1, 0, 2);

      if(r.intent == BUY && rsi1 > r.d1) return BUY; // RSI subiu acima de threshold
      if(r.intent == SELL && rsi1 < r.d1) return SELL; // RSI caiu abaixo de threshold
   }

   if(r.type == 3) { // Stoch
      double k1 = GetBufferValue(r.handle1, 0, 1);
      double d1 = GetBufferValue(r.handle1, 1, 1);
      double k2 = GetBufferValue(r.handle1, 0, 2);
      double d2 = GetBufferValue(r.handle1, 1, 2);
      if(r.intent == BUY && k2 <= d2 && k1 > d1) return BUY;
      if(r.intent == SELL && k2 >= d2 && k1 < d1) return SELL;
   }

   if(r.type == 4) { // BB
      double upper = GetBufferValue(r.handle1, 1, 1);
      double lower = GetBufferValue(r.handle1, 2, 1);
      double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 1);
      if(r.intent == BUY && close < lower) return BUY;
      if(r.intent == SELL && close > upper) return SELL;
   }

   if(r.type == 5) { // Daily Break
      double hi = iHigh(_Symbol, PERIOD_D1, 1);
      double lo = iLow(_Symbol, PERIOD_D1, 1);
      double close = iClose(_Symbol, PERIOD_M1, 0);
      if(r.intent == BUY && close > hi) return BUY;
      if(r.intent == SELL && close < lo) return SELL;
   }

   return NONE;
}

double GetBufferValue(int handle, int buffer, int shift) {
   double buffer_arr[];
   ArraySetAsSeries(buffer_arr, true);
   if(CopyBuffer(handle, buffer, shift, 1, buffer_arr) > 0) return buffer_arr[0];
   return 0;
}

string CarregaPrompt() {
   int h = FileOpen("prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI);
   if(h == INVALID_HANDLE) return "cruzamento ema9/21 no m15";
   string p = FileReadString(h);
   FileClose(h);
   return p;
}

void VerificaNovoPrompt() {
   datetime mod = (datetime)FileGetInteger("prompt.txt", FILE_MODIFY_DATE);
   if(mod > lastPromptCheck) {
      GravaLog("Novo prompt detectado. Atualizando lógica...");
      ResetStrategy();
      InterpretaPrompt(CarregaPrompt());
      lastPromptCheck = mod;
   }
}

void ResetStrategy() {
   for(int i=0; i<MAX_RULES; i++) rules[i].Reset();
   nRules = 0;
   // Reset de globais para defaults antes de re-interpretar
   p_riskPercent = 1.0; p_stopPoints = 0; p_takePoints = 0; p_maxTrades = 3;
   p_startTime = "00:00"; p_frequency = PERIOD_M15; p_useMartingale = false;
   p_beStart = 0; p_bePlus = 0; p_trailingStop = 0; p_trailingStep = 0;
}

// ---------- FUNÇÕES AUXILIARES (STUBS PARA PASSOS POSTERIORES) ----------

bool IsTimeAllowed() {
   string now = TimeToString(TimeCurrent(), TIME_MINUTES);
   return (now >= p_startTime);
}
bool AguardaNoticias() {
   // Veto binário via arquivo
   int h = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_ANSI);
   if(h != INVALID_HANDLE) {
      string veto = FileReadString(h);
      FileClose(h);
      if(veto == "true" || veto == "1") return true;
   }
   return false;
}

double CalculaLote(double riscoPercent) {
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;

   if(p_useMartingale) {
      HistorySelect(0, TimeCurrent());
      int totalDeals = HistoryDealsTotal();
      for(int i = totalDeals - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if(profit < 0) riscoAbs *= 2.0;
            break;
         }
      }
   }

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   int sl = (p_stopPoints > 0) ? p_stopPoints : 300;
   double lot = riscoAbs / (sl * (tickValue / (tickSize / _Point)));

   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = NormalizeDouble(lot / step, 0) * step;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return lot;
}

void EnviaOrdem(Signal s, double lote, string reason) {
   int count = 0;
   for(int i=0; i<PositionsTotal(); i++) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Magic() == EA_MAGIC && posInfo.Symbol() == _Symbol) count++;
      }
   }
   if(count >= p_maxTrades) return;

   double sl_price = 0, tp_price = 0;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(s == BUY) {
      if(p_stopPoints > 0) sl_price = ask - p_stopPoints * _Point;
      if(p_takePoints > 0) tp_price = ask + p_takePoints * _Point;

      for(int i=0; i<3; i++) {
         if(trade.Buy(lote, _Symbol, ask, sl_price, tp_price, reason)) break;
         int ret = trade.ResultRetcode();
         if(ret != TRADE_RETCODE_REQUOTES && ret != TRADE_RETCODE_OFFQUOTES) break;
         ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      }
   } else if(s == SELL) {
      if(p_stopPoints > 0) sl_price = bid + p_stopPoints * _Point;
      if(p_takePoints > 0) tp_price = bid - p_takePoints * _Point;

      for(int i=0; i<3; i++) {
         if(trade.Sell(lote, _Symbol, bid, sl_price, tp_price, reason)) break;
         int ret = trade.ResultRetcode();
         if(ret != TRADE_RETCODE_REQUOTES && ret != TRADE_RETCODE_OFFQUOTES) break;
         bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      }
   }

   if(trade.ResultRetcode() == TRADE_RETCODE_DONE) {
      SendNotification("MT-LiveExecutor: Ordem enviada em " + _Symbol + " Motivo: " + reason);
   } else {
      GravaLog("Erro ao enviar ordem: " + (string)trade.ResultRetcode() + " " + trade.ResultRetcodeDescription());
   }
}

void GerenciaPosicoes() {
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(posInfo.SelectByIndex(i)) {
         if(posInfo.Magic() != EA_MAGIC || posInfo.Symbol() != _Symbol) continue;

         double open = posInfo.PriceOpen();
         double current = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double points = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (current - open) / _Point : (open - current) / _Point;

         // Breakeven
         if(p_beStart > 0 && points >= p_beStart) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? open + p_bePlus * _Point : open - p_bePlus * _Point;
            if(posInfo.StopLoss() == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > posInfo.StopLoss()) || (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < posInfo.StopLoss() || posInfo.StopLoss() == 0))) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }

         // Trailing Stop
         if(p_trailingStop > 0 && points >= p_trailingStop) {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? current - p_trailingStop * _Point : current + p_trailingStop * _Point;
            bool modify = false;
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
               if(newSL > posInfo.StopLoss() + p_trailingStep * _Point) modify = true;
            } else {
               if(posInfo.StopLoss() == 0 || newSL < posInfo.StopLoss() - p_trailingStep * _Point) modify = true;
            }

            if(modify) {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }
      }
   }
}
void GravaCSV() {
   int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileWrite(h, "Ticket", "Symbol", "Type", "Volume", "PriceOpen", "Time", "SL", "TP", "Profit", "Reason");
      for(int i=0; i<PositionsTotal(); i++) {
         if(posInfo.SelectByIndex(i)) {
            if(posInfo.Magic() == EA_MAGIC) {
               FileWrite(h, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.Volume(),
                         posInfo.PriceOpen(), posInfo.Time(), posInfo.StopLoss(), posInfo.TakeProfit(),
                         posInfo.Profit(), posInfo.Comment());
            }
         }
      }
      FileClose(h);
   }
}

void GravaLog(string texto) {
   string time = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS);
   string log = time + " | " + texto;
   Print(log);
   int h = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h != INVALID_HANDLE) {
      FileSeek(h, 0, SEEK_END);
      FileWriteString(h, log + "\r\n");
      FileClose(h);
   }
}

void AIOptimizer() {
   // Analisa win rate das últimas 10 ordens
   HistorySelect(TimeCurrent() - 86400*7, TimeCurrent());
   int total = 0, wins = 0;
   int deals = HistoryDealsTotal();
   double lastProfit = 0;
   bool hasLastTrade = false;

   for(int i = deals - 1; i >= 0; i--) {
      ulong t = HistoryDealGetTicket(i);
      if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
         if(HistoryDealGetInteger(t, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            if(!hasLastTrade) {
               lastProfit = HistoryDealGetDouble(t, DEAL_PROFIT);
               hasLastTrade = true;
            }
            if(total < 10) {
               total++;
               if(HistoryDealGetDouble(t, DEAL_PROFIT) > 0) wins++;
            }
         }
      }
   }

   if(total >= 5 && hasLastTrade) {
      double wr = (double)wins / total;
      // Ajusta apenas se houve mudança recente no resultado para evitar drift sem trades
      if(wr < 0.4 && lastProfit < 0) {
         p_riskPercent *= 0.9;
         GravaLog(StringFormat("AI Optimizer: Win Rate baixo (%.2f). Reduzindo risco para %.2f%%", wr, p_riskPercent));
      } else if(wr > 0.6 && lastProfit > 0) {
         p_riskPercent *= 1.1;
         if(p_riskPercent > 2.0) p_riskPercent = 2.0;
         GravaLog(StringFormat("AI Optimizer: Win Rate alto (%.2f). Aumentando risco para %.2f%%", wr, p_riskPercent));
      }
   }
}
