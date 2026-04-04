//========================================================================
// MT-LiveExecutor - Professional MetaTrader 5 Strategy Execution Module
//========================================================================
#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- 1. DEFINIÇÕES GLOBAIS E ESTRUTURAS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI,
   RULE_STOCH,
   RULE_BBANDS,
   RULE_DAILY_BREAKOUT,
   RULE_DELTA,
   RULE_VOLUME,
   RULE_AMA,
   RULE_PATTERN,
   RULE_RELATIVE
};

struct Rule {
   bool      active;
   RuleType  type;
   int       tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   Signal    intent; // BUY or SELL
   int       p1_handle, p2_handle, p3_handle;
};

// Parâmetros de Execução (Populados pelo parser)
double   p_riskPercent = 1.0;
int      p_stopPoints = 300;
int      p_takePoints = 500;
int      p_trailingStopPoints = 0;
int      p_breakEvenPoints = 0;
int      p_breakEvenExtra = 5;
int      p_maxTrades = 3;
bool     p_hedge = false;
bool     p_useMartingale = false;
int      p_startTimeSeconds = 0; // Segundos desde meia-noite
int      p_endTimeSeconds = 86399;

// Variáveis de Estado
Rule     rules[30];
int      nRules = 0;
int      dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
datetime lastBarTime = 0;
long     EA_MAGIC = 20260101;

CTrade          trade;
CPositionInfo   m_position;
CSymbolInfo     m_symbol;
CAccountInfo    m_account;

// ---------- 2. UTILITÁRIOS DE NLP ----------

double ExtractNumber(string txt, string search)
{
   int pos = StringFind(txt, search);
   if (pos < 0) return 0;

   string sub = StringSubstr(txt, pos + StringLen(search));
   string res = "";
   bool start = false;

   for (int i=0; i<StringLen(sub); i++)
   {
      ushort c = StringGetCharacter(sub, i);
      if ((c >= '0' && c <= '9') || c == '.' || c == ',')
      {
         start = true;
         if (c == ',') res += ".";
         else res += StringSubstr(sub, i, 1);
      }
      else if (start) break;
   }
   return StringToDouble(res);
}

string ExtractTime(string txt)
{
   int pos = StringFind(txt, "h");
   if (pos < 0) return "00:00";

   string res = "";
   int start = pos - 1;
   while (start >= 0 && StringGetCharacter(txt, start) >= '0' && StringGetCharacter(txt, start) <= '9')
      start--;

   res = StringSubstr(txt, start + 1, pos - start - 1);
   res += ":";

   string sub = StringSubstr(txt, pos + 1);
   if (StringLen(sub) >= 2 && StringGetCharacter(sub, 0) >= '0' && StringGetCharacter(sub, 0) <= '9')
      res += StringSubstr(sub, 0, 2);
   else
      res += "00";

   return res;
}

int PeriodoTexto(string nome)
{
   StringToLower(nome);
   if (StringFind(nome, "m15") >= 0) return PERIOD_M15;
   if (StringFind(nome, "m30") >= 0) return PERIOD_M30;
   if (StringFind(nome, "m5") >= 0)  return PERIOD_M5;
   if (StringFind(nome, "m1") >= 0)  return PERIOD_M1;
   if (StringFind(nome, "h1") >= 0)  return PERIOD_H1;
   if (StringFind(nome, "h4") >= 0)  return PERIOD_H4;
   if (StringFind(nome, "d1") >= 0)  return PERIOD_D1;

   if (StringFind(nome, "minutos") >= 0 || StringFind(nome, "min") >= 0)
   {
      double val = ExtractNumber(nome, "");
      if (val == 1) return PERIOD_M1;
      if (val == 5) return PERIOD_M5;
      if (val == 15) return PERIOD_M15;
      if (val == 30) return PERIOD_M30;
   }
   return PERIOD_CURRENT;
}

void ResetStrategy()
{
   for (int i=0; i<30; i++)
   {
      if (rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if (rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      if (rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
      rules[i].active = false;
      rules[i].p1_handle = INVALID_HANDLE;
      rules[i].p2_handle = INVALID_HANDLE;
      rules[i].p3_handle = INVALID_HANDLE;
   }
   nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 300;
   p_takePoints = 500;
   p_trailingStopPoints = 0;
   p_breakEvenPoints = 0;
   p_maxTrades = 3;
   p_hedge = false;
   p_useMartingale = false;
   p_startTimeSeconds = 0;
   p_endTimeSeconds = 86399;
}

void AddRule(RuleType type, int tf, int p1, int p2, double d1, double d2, Signal intent)
{
   if (nRules >= 30) return;

   // Tenta atualizar regra existente do mesmo tipo e intenção
   for (int i=0; i<nRules; i++)
   {
      if (rules[i].type == type && rules[i].intent == intent)
      {
         rules[i].tf = tf;
         rules[i].p1 = p1; rules[i].p2 = p2;
         rules[i].d1 = d1; rules[i].d2 = d2;
         return;
      }
   }

   rules[nRules].active = true;
   rules[nRules].type = type;
   rules[nRules].tf = tf;
   rules[nRules].p1 = p1; rules[nRules].p2 = p2;
   rules[nRules].d1 = d1; rules[nRules].d2 = d2;
   rules[nRules].intent = intent;
   rules[nRules].p1_handle = INVALID_HANDLE;
   rules[nRules].p2_handle = INVALID_HANDLE;
   rules[nRules].p3_handle = INVALID_HANDLE;

   // Inicializa handles conforme o tipo
   if (type == RULE_MA_CROSS) {
      rules[nRules].p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, p1, 0, MODE_EMA, PRICE_CLOSE);
      rules[nRules].p2_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)tf, p2, 0, MODE_EMA, PRICE_CLOSE);
   } else if (type == RULE_RSI) {
      rules[nRules].p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)tf, p1, PRICE_CLOSE);
   } else if (type == RULE_STOCH) {
      rules[nRules].p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)tf, p1, 3, 3, MODE_SMA, STO_LOWHIGH);
   } else if (type == RULE_BBANDS) {
      rules[nRules].p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)tf, p1, 0, d1, PRICE_CLOSE);
   }

   nRules++;
}

void InterpretaPrompt(string prompt)
{
   ResetStrategy();
   StringToLower(prompt);

   // 1. Gestão e Risco
   if (StringFind(prompt, "risco") >= 0) p_riskPercent = ExtractNumber(prompt, "risco de");
   if (StringFind(prompt, "stop de") >= 0) p_stopPoints = (int)ExtractNumber(prompt, "stop de");
   if (StringFind(prompt, "take de") >= 0) p_takePoints = (int)ExtractNumber(prompt, "take de");
   if (StringFind(prompt, "atingir +") >= 0) p_trailingStopPoints = (int)ExtractNumber(prompt, "atingir +");
   if (StringFind(prompt, "move stop") >= 0)
   {
      p_breakEvenPoints = (int)ExtractNumber(prompt, "atingir +");
      p_breakEvenExtra = (int)ExtractNumber(prompt, "entrada +");
   }
   if (StringFind(prompt, "máximo") >= 0) p_maxTrades = (int)ExtractNumber(prompt, "máximo");
   if (StringFind(prompt, "martingale") >= 0) p_useMartingale = true;
   if (StringFind(prompt, "hedge") >= 0) p_hedge = true;

   // 2. Filtros de Horário
   if (StringFind(prompt, "depois das") >= 0)
   {
      string t = ExtractTime(prompt);
      p_startTimeSeconds = (int)StringToTime(t) % 86400;
   }

   // 3. Timeframe Global
   int globalTf = PeriodoTexto(prompt);

   // 4. Regras de Indicadores (Simplificado para o exemplo, expandir conforme necessário)
   string segments[];
   ushort sep = '.';
   if (StringFind(prompt, ",") >= 0) sep = ',';
   StringSplit(prompt, sep, segments);

   Signal currentIntent = NONE;
   for (int i=0; i<ArraySize(segments); i++)
   {
      string seg = segments[i];
      if (StringFind(seg, "compra") >= 0) currentIntent = BUY;
      else if (StringFind(seg, "vende") >= 0) currentIntent = SELL;

      if (currentIntent == NONE) continue;

      if (StringFind(seg, "média") >= 0)
      {
         int p1 = (int)ExtractNumber(seg, "média de");
         if (p1 == 0) p1 = 20;
         AddRule(RULE_MA_CROSS, globalTf, p1, 1, 0, 0, currentIntent);
      }
      if (StringFind(seg, "rsi") >= 0)
      {
         int per = (int)ExtractNumber(seg, "rsi (");
         if (per == 0) per = 14;
         double thresh = ExtractNumber(seg, "acima de");
         if (thresh == 0) thresh = ExtractNumber(seg, "abaixo de");
         AddRule(RULE_RSI, globalTf, per, 0, thresh, 0, currentIntent);
      }
   }
}

// ---------- 3. LOGICA DE INDICADORES E SINAIS ----------

Signal AvaliaRegra(Rule &r)
{
   if (!r.active) return NONE;

   double buffer1[], buffer2[];
   ArraySetAsSeries(buffer1, true);
   ArraySetAsSeries(buffer2, true);

   if (r.type == RULE_MA_CROSS)
   {
      if (CopyBuffer(r.p1_handle, 0, 0, 2, buffer1) <= 0) return NONE;
      if (CopyBuffer(r.p2_handle, 0, 0, 2, buffer2) <= 0) return NONE;

      // r.p2 == 1 significa cruzamento com o preço (p1_handle é MA, buffer2 será Close)
      if (r.p2 == 1)
      {
         double close[2]; ArraySetAsSeries(close, true);
         CopyClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, 2, close);
         if (close[1] < buffer1[1] && close[0] > buffer1[0]) return BUY;
         if (close[1] > buffer1[1] && close[0] < buffer1[0]) return SELL;
      }
      else
      {
         if (buffer1[1] < buffer2[1] && buffer1[0] > buffer2[0]) return BUY;
         if (buffer1[1] > buffer2[1] && buffer1[0] < buffer2[0]) return SELL;
      }
   }
   else if (r.type == RULE_RSI)
   {
      if (CopyBuffer(r.p1_handle, 0, 0, 2, buffer1) <= 0) return NONE;
      if (r.intent == BUY) {
         if (buffer1[0] > r.d1) return BUY;
      } else if (r.intent == SELL) {
         if (buffer1[0] < r.d1) return SELL;
      }
   }
   else if (r.type == RULE_STOCH)
   {
      if (CopyBuffer(r.p1_handle, 0, 0, 2, buffer1) <= 0) return NONE; // Main
      if (CopyBuffer(r.p1_handle, 1, 0, 2, buffer2) <= 0) return NONE; // Signal
      if (buffer2[1] < buffer1[1] && buffer2[0] > buffer1[0]) return BUY;
      if (buffer2[1] > buffer1[1] && buffer2[0] < buffer1[0]) return SELL;
   }
   else if (r.type == RULE_BBANDS)
   {
      if (CopyBuffer(r.p1_handle, 1, 0, 1, buffer1) <= 0) return NONE; // Upper
      if (CopyBuffer(r.p1_handle, 2, 0, 1, buffer2) <= 0) return NONE; // Lower
      double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0);
      if (close < buffer2[0]) return BUY;
      if (close > buffer1[0]) return SELL;
   }

   return NONE;
}

Signal AvaliaTudo()
{
   int buyLeg = 0, sellLeg = 0;
   int buyRules = 0, sellRules = 0;

   for (int i=0; i<nRules; i++)
   {
      Signal s = AvaliaRegra(rules[i]);
      if (rules[i].intent == BUY) {
         buyRules++;
         if (s == BUY) buyLeg++;
      } else if (rules[i].intent == SELL) {
         sellRules++;
         if (s == SELL) sellLeg++;
      }
   }

   // Confluência: Todas as regras da perna devem concordar
   if (buyRules > 0 && buyLeg == buyRules) return BUY;
   if (sellRules > 0 && sellLeg == sellRules) return SELL;

   return NONE;
}

// ---------- 4. EXECUÇÃO, GESTÃO E AUXILIARES ----------

bool AguardaNoticias()
{
   int file = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
   if (file != INVALID_HANDLE)
   {
      string s = FileReadString(file);
      FileClose(file);
      if (s == "1") return true;

      datetime newsTime = StringToTime(s);
      if (newsTime > 0)
      {
         datetime now = TimeCurrent();
         if (now >= newsTime - 1200 && now <= newsTime + 1200) return true;
      }
   }
   return false;
}

double CalculaLote(double riscoPercent)
{
   double capital = AccountInfoDouble(ACCOUNT_EQUITY);
   double riscoAbs = capital * riscoPercent / 100.0;
   double tickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double p = _Point;

   double stopDist = p_stopPoints * p;
   if (stopDist <= 0) stopDist = 100 * p;

   double vol = riscoAbs / (stopDist * (tickVal / (tickSize / p)));

   // Martingale (simplificado: dobra se o último trade no símbolo foi perda)
   if (p_useMartingale)
   {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for (int i=total-1; i>=0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if (HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol &&
             HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC &&
             HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            if (HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) vol *= 2;
            break;
         }
      }
   }

   return m_symbol.CheckVolumeValue(vol);
}

void EnviaOrdem(Signal s, double lote)
{
   if (s == NONE || lote <= 0) return;

   if (!p_hedge)
   {
      // Fecha posições opostas
      for (int i=PositionsTotal()-1; i>=0; i--)
      {
         if (m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == EA_MAGIC)
         {
            if ((s == BUY && m_position.PositionType() == POSITION_TYPE_SELL) ||
                (s == SELL && m_position.PositionType() == POSITION_TYPE_BUY))
            {
               trade.PositionClose(m_position.Ticket());
            }
         }
      }
   }

   if (PositionsTotal() >= p_maxTrades) return;

   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;

   double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double safetyFloor = (stopsLevel + dynamicSafetyPoints + 1) * _Point;
   double stopPoints = MathMax(p_stopPoints * _Point, safetyFloor);

   if (s == BUY)
   {
      sl = price - stopPoints;
      tp = price + p_takePoints * _Point;
      if (trade.Buy(lote, _Symbol, price, sl, tp))
         Print("Compra enviada com sucesso.");
      else
         dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
   }
   else
   {
      sl = price + stopPoints;
      tp = price - p_takePoints * _Point;
      if (trade.Sell(lote, _Symbol, price, sl, tp))
         Print("Venda enviada com sucesso.");
      else
         dynamicSafetyPoints = MathMin(dynamicSafetyPoints + 5, 100);
   }
}

void GerenciaPosicoes()
{
   for (int i=PositionsTotal()-1; i>=0; i--)
   {
      if (m_position.SelectByIndex(i) && m_position.Symbol() == _Symbol && m_position.Magic() == EA_MAGIC)
      {
         double price = m_position.PriceOpen();
         double current = m_position.PriceCurrent();
         double sl = m_position.StopLoss();
         double profitPoints = (m_position.PositionType() == POSITION_TYPE_BUY) ?
                              (current - price) / _Point : (price - current) / _Point;

         // 1. Break-even
         if (p_breakEvenPoints > 0 && profitPoints >= p_breakEvenPoints)
         {
            double newSL = (m_position.PositionType() == POSITION_TYPE_BUY) ?
                           price + p_breakEvenExtra * _Point : price - p_breakEvenExtra * _Point;

            if (sl == 0 || (m_position.PositionType() == POSITION_TYPE_BUY && newSL > sl) ||
                          (m_position.PositionType() == POSITION_TYPE_SELL && newSL < sl))
            {
               trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
            }
         }

         // 2. Trailing Stop
         if (p_trailingStopPoints > 0 && profitPoints >= p_trailingStopPoints)
         {
            double newSL = (m_position.PositionType() == POSITION_TYPE_BUY) ?
                           current - p_trailingStopPoints * _Point : current + p_trailingStopPoints * _Point;

            if (sl == 0 || (m_position.PositionType() == POSITION_TYPE_BUY && newSL > sl) ||
                          (m_position.PositionType() == POSITION_TYPE_SELL && newSL < sl))
            {
               trade.PositionModify(m_position.Ticket(), newSL, m_position.TakeProfit());
            }
         }
      }
   }
}

void GravaCSV()
{
   static datetime lastWrite = 0;
   if (TimeCurrent() - lastWrite < 5) return;
   lastWrite = TimeCurrent();

   int file = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON);
   if (file != INVALID_HANDLE)
   {
      FileWrite(file, "Ticket", "Symbol", "Type", "Price", "SL", "TP", "Profit");
      for (int i=0; i<PositionsTotal(); i++)
      {
         if (m_position.SelectByIndex(i) && m_position.Magic() == EA_MAGIC)
            FileWrite(file, m_position.Ticket(), m_position.Symbol(), m_position.PositionType(),
                      m_position.PriceOpen(), m_position.StopLoss(), m_position.TakeProfit(), m_position.Profit());
      }
      FileClose(file);
   }
}

void CalculaEstatisticas()
{
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   double profit = 0, loss = 0;
   int wins = 0, losses = 0;

   for (int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if (HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
      {
         double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if (p > 0) { profit += p; wins++; }
         else if (p < 0) { loss += MathAbs(p); losses++; }
      }
   }

   double winRate = (wins + losses > 0) ? (double)wins / (wins + losses) * 100 : 0;
   double pf = (loss > 0) ? profit / loss : profit;

   PrintFormat("Estatísticas: WinRate: %.2f%%, Profit Factor: %.2f, Wins: %d, Losses: %d", winRate, pf, wins, losses);
}

// ---------- 5. HANDLERS DO SISTEMA ----------

int OnInit()
{
   trade.SetExpertMagicNumber(EA_MAGIC);
   m_symbol.Name(_Symbol);

   // Leitura inicial do prompt
   int file = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if (file != INVALID_HANDLE)
   {
      string prompt = FileReadString(file);
      FileClose(file);
      InterpretaPrompt(prompt);
   }

   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   ResetStrategy();
   EventKillTimer();
}

void OnTimer()
{
   // Mecanismo de atualização sem reinicializar
   double updateRequested = GlobalVariableGet("MT_Executor_Prompt_Update");
   if (updateRequested > 0)
   {
      int file = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
      if (file != INVALID_HANDLE)
      {
         string prompt = FileReadString(file);
         FileClose(file);
         InterpretaPrompt(prompt);
         GlobalVariableSet("MT_Executor_Prompt_Update", 0);
         Print("Estratégia atualizada com sucesso.");
      }
   }

   // Decaimento de pontos de segurança
   if (TimeCurrent() - lastSafetyDecay >= 60)
   {
      if (dynamicSafetyPoints > 0) dynamicSafetyPoints--;
      lastSafetyDecay = TimeCurrent();
   }

   GravaCSV();
   CalculaEstatisticas();
}

void OnTick()
{
   GerenciaPosicoes();

   if (AguardaNoticias()) return;

   int nowSec = (int)TimeCurrent() % 86400;
   if (nowSec < p_startTimeSeconds || nowSec > p_endTimeSeconds) return;

   // Só avalia na abertura de barra conforme timeframe da estratégia
   datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)rules[0].tf, 0);
   if (currentBar == lastBarTime) return;
   lastBarTime = currentBar;

   Signal s = AvaliaTudo();
   if (s != NONE)
   {
      double lote = CalculaLote(p_riskPercent);
      EnviaOrdem(s, lote);
   }
}
