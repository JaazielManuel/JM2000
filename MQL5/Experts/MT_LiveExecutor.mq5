//=========================  MT5-LIVE-EXECUTOR  =========================
// Módulo residente para execução de estratégias via NLP (Português)
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// --- Constantes Globais ---
#define EA_MAGIC 20260101

// --- Enums ---
enum Signal {BUY=1, SELL=-1, NONE=0};

enum RuleType {
   RULE_MA_CROSS,
   RULE_RSI_THRESHOLD,
   RULE_STOCH_CROSS,
   RULE_BB_BOUNCE,
   RULE_DAILY_BREAK,
   RULE_DELTA,
   RULE_VOLUME_CYCLE,
   RULE_AMA,
   RULE_BAR_PATTERN,
   RULE_RS_RELATIVE
};

// --- Structs ---
struct Rule {
   bool      active;
   RuleType  type;
   int       tf;
   int       p1, p2, p3;
   double    d1, d2;
   string    s1;
   Signal    intent; // BUY, SELL ou NONE (filtro)
   int       p1_handle, p2_handle; // Handles de indicadores
};

// --- Variáveis Globais de Operação ---
Rule rules[30];
int nRules = 0;

double p_riskPercent = 1.0;
int    p_stopPoints = 0;
int    p_takePoints = 0;
int    p_trailingStart = 0;
int    p_breakEvenStart = 0;
int    p_breakEvenProfit = 0;
int    p_maxTrades = 3;
bool   p_useMartingale = false;
bool   p_hedge = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_CURRENT;

datetime p_startTimeSeconds = 0;
datetime p_endTimeSeconds = 0;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

datetime lastBarTime = 0;

// Forward declarations de funções que serão implementadas nos próximos passos
void ResetStrategy();
void InterpretaPrompt(string prompt);
Signal AvaliaTudo();
void GerenciaPosicoes();
double CalculaLote(double risco);
bool AguardaNoticias();
void GravaCSV();
void GravaLog(string texto);
void CalculaEstatisticas();

// --- utilitários NLP ---

double ExtraiNumero(string txt)
{
   string res = "";
   bool found = false;
   for(int i=0; i<StringLen(txt); i++)
   {
      ushort c = StringGetCharacter(txt, i);
      if((c >= '0' && c <= '9') || c == '.' || c == ',')
      {
         if(c == ',') res += ".";
         else res += CharToString((uchar)c);
         found = true;
      }
      else if(found) break;
   }
   return StringToDouble(res);
}

string ExtractTime(string txt)
{
   string res = txt;
   StringReplace(res, "h", ":00");
   // Garante formato HH:MM
   if(StringLen(res) == 2) res += ":00";
   return res;
}

int PeriodoTexto(string nome)
{
   string n = nome;
   StringToLower(n);
   if(StringFind(n, "mensal") >= 0) return PERIOD_MN1;
   if(StringFind(n, "semanal") >= 0) return PERIOD_W1;
   if(StringFind(n, "diário") >= 0 || StringFind(n, "diario") >= 0) return PERIOD_D1;
   if(StringFind(n, "h4") >= 0) return PERIOD_H4;
   if(StringFind(n, "h1") >= 0) return PERIOD_H1;
   if(StringFind(n, "m30") >= 0 || StringFind(n, "30 minutos") >= 0) return PERIOD_M30;
   if(StringFind(n, "m15") >= 0 || StringFind(n, "15 minutos") >= 0) return PERIOD_M15;
   if(StringFind(n, "m5") >= 0 || StringFind(n, "5 minutos") >= 0) return PERIOD_M5;
   if(StringFind(n, "m1") >= 0 || StringFind(n, "1 minuto") >= 0 || StringFind(n, "minuto") >= 0) return PERIOD_M1;
   return PERIOD_CURRENT;
}

void ResetStrategy()
{
   for(int i=0; i<nRules; i++)
   {
      if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
      if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
      rules[i].active = false;
   }
   nRules = 0;
   p_riskPercent = 1.0;
   p_stopPoints = 0;
   p_takePoints = 0;
   p_trailingStart = 0;
   p_breakEvenStart = 0;
   p_breakEvenProfit = 0;
   p_useMartingale = false;
   p_hedge = false;
   p_startTimeSeconds = 0;
   p_endTimeSeconds = 0;
}

void AddRule(Rule &r)
{
   // Tenta encontrar regra existente do mesmo tipo para atualizar
   for(int i=0; i<nRules; i++)
   {
      if(rules[i].type == r.type && rules[i].intent == r.intent)
      {
         rules[i] = r;
         return;
      }
   }
   if(nRules < 30)
   {
      rules[nRules] = r;
      nRules++;
   }
}

void InterpretaPrompt(string prompt)
{
   ResetStrategy();
   string p = prompt;
   StringToLower(p);

   // Parâmetros Globais
   p_riskPercent = ExtraiValorApos(p, "risco de");
   if(p_riskPercent == 0) p_riskPercent = 1.0;

   p_stopPoints = (int)ExtraiValorApos(p, "stop de");
   p_takePoints = (int)ExtraiValorApos(p, "take de");
   p_maxTrades = (int)ExtraiValorApos(p, "máximo");
   if(p_maxTrades == 0) p_maxTrades = 3;

   if(StringFind(p, "martingale") >= 0) p_useMartingale = true;
   if(StringFind(p, "hedge") >= 0) p_hedge = true;

   p_breakEvenStart = (int)ExtraiValorApos(p, "atingir +");
   p_breakEvenProfit = (int)ExtraiValorApos(p, "move stop para entrada +");

   if(StringFind(p, "depois das") >= 0) {
       int pos = StringFind(p, "depois das") + 11;
       string t = StringSubstr(p, pos, 5);
       p_startTimeSeconds = StringToTime(ExtractTime(t)) % 86400;
   }

   p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(p);

   // Divisão por intenção e indicadores
   string segments[];
   ushort sep = ',';
   if(StringFind(p, ".") >= 0) sep = '.';
   StringSplit(p, sep, segments);

   Signal currentIntent = NONE;

   for(int i=0; i<ArraySize(segments); i++)
   {
      string s = segments[i];
      if(StringFind(s, "compra") >= 0) currentIntent = BUY;
      else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

      Rule r;
      r.active = true;
      r.intent = currentIntent;
      r.tf = p_frequency;
      r.p1_handle = INVALID_HANDLE;
      r.p2_handle = INVALID_HANDLE;

      if(StringFind(s, "média") >= 0 || StringFind(s, "media") >= 0)
      {
         r.type = RULE_MA_CROSS;
         r.p1 = (int)ExtraiValorApos(s, "média");
         if(r.p1 == 0) r.p1 = (int)ExtraiValorApos(s, "media");
         if(r.p1 == 0) r.p1 = 20; // default
         r.p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_SMA, PRICE_CLOSE);
         AddRule(r);
      }

      if(StringFind(s, "rsi") >= 0)
      {
         r.type = RULE_RSI_THRESHOLD;
         r.p1 = (int)ExtraiValorApos(s, "rsi");
         if(r.p1 == 0 || r.p1 > 50) r.p1 = 14;

         r.d1 = ExtraiValorApos(s, "acima de");
         if(r.d1 == 0) r.d1 = ExtraiValorApos(s, "abaixo de");
         if(r.d1 == 0) r.d1 = (currentIntent == BUY) ? 55 : 45;

         r.p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);
         AddRule(r);
      }

      if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stochastic") >= 0)
      {
         r.type = RULE_STOCH_CROSS;
         r.p1 = 5; r.p2 = 3; r.p3 = 3; // Default
         r.p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);
         AddRule(r);
      }

      if(StringFind(s, "bollinger") >= 0)
      {
         r.type = RULE_BB_BOUNCE;
         r.p1 = 20; r.d1 = 2.0; // Default
         r.p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);
         AddRule(r);
      }
   }
}

// --- Lógica de Indicadores ---

Signal AvaliaRegra(Rule &r)
{
   if(!r.active) return NONE;

   double val[3], val2[3];
   ArraySetAsSeries(val, true);
   ArraySetAsSeries(val2, true);

   switch(r.type)
   {
      case RULE_MA_CROSS:
      {
         if(CopyBuffer(r.p1_handle, 0, 0, 2, val) < 2) return NONE;
         double close[2];
         ArraySetAsSeries(close, true);
         CopyClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, 2, close);

         if(close[1] < val[1] && close[0] > val[0]) return BUY;
         if(close[1] > val[1] && close[0] < val[0]) return SELL;
         break;
      }
      case RULE_RSI_THRESHOLD:
      {
         if(CopyBuffer(r.p1_handle, 0, 0, 2, val) < 2) return NONE;
         if(r.intent == BUY && val[1] < r.d1 && val[0] > r.d1) return BUY;
         if(r.intent == SELL && val[1] > r.d1 && val[0] < r.d1) return SELL;
         break;
      }
      case RULE_STOCH_CROSS:
      {
         if(CopyBuffer(r.p1_handle, 0, 0, 2, val) < 2) return NONE;  // %K
         if(CopyBuffer(r.p1_handle, 1, 0, 2, val2) < 2) return NONE; // %D
         if(val[1] < val2[1] && val[0] > val2[0]) return BUY;
         if(val[1] > val2[1] && val[0] < val2[0]) return SELL;
         break;
      }
      case RULE_BB_BOUNCE:
      {
         double close[1];
         CopyClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, 0, 1, close);
         if(CopyBuffer(r.p1_handle, 1, 0, 1, val) < 1) return NONE; // Upper
         if(CopyBuffer(r.p1_handle, 2, 0, 1, val2) < 1) return NONE; // Lower
         if(close[0] < val2[0]) return BUY;
         if(close[0] > val[0]) return SELL;
         break;
      }
   }
   return NONE;
}

Signal AvaliaTudo()
{
   if(nRules == 0) return NONE;

   int buyLeg = 0, buyRules = 0;
   int sellLeg = 0, sellRules = 0;

   for(int i=0; i<nRules; i++)
   {
      Signal s = AvaliaRegra(rules[i]);
      if(rules[i].intent == BUY || rules[i].intent == NONE)
      {
         buyRules++;
         if(s == BUY) buyLeg++;
      }
      if(rules[i].intent == SELL || rules[i].intent == NONE)
      {
         sellRules++;
         if(s == SELL) sellLeg++;
      }
   }

   if(buyRules > 0 && buyLeg == buyRules) return BUY;
   if(sellRules > 0 && sellLeg == sellRules) return SELL;

   return NONE;
}

// --- Execução e Gestão ---

double CalculaLote(double riscoPercent)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * (riscoPercent / 100.0);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   if(p_stopPoints <= 0) return 0.1; // Default mínimo se não especificado

   double lotSize = NormalizeDouble(riskAmount / (p_stopPoints * (tickValue / (tickSize / _Point))), 2);

   // Martingale
   if(p_useMartingale)
   {
      HistorySelect(TimeCurrent()-86400, TimeCurrent());
      int total = HistoryDealsTotal();
      for(int i=total-1; i>=0; i--)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC)
         {
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lotSize *= 2;
            break;
         }
      }
   }

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   return MathMax(minLot, MathMin(maxLot, lotSize));
}

void EnviaOrdem(Signal s)
{
   if(s == NONE) return;

   // Filtro de horário
   datetime nowSeconds = TimeCurrent() % 86400;
   if(p_startTimeSeconds > 0 && nowSeconds < p_startTimeSeconds) return;

   // Filtro de notícias
   if(AguardaNoticias()) return;

   // Máximo de trades
   int openTrades = 0;
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionGetSymbol(i) == _Symbol && PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         openTrades++;

   if(openTrades >= p_maxTrades) return;

   double lote = CalculaLote(p_riskPercent);
   double price = (s == BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) : SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double sl = 0, tp = 0;
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int safety = stopsLevel + 5;

   if(s == BUY)
   {
      if(p_stopPoints > 0) sl = price - MathMax(p_stopPoints, safety) * _Point;
      if(p_takePoints > 0) tp = price + p_takePoints * _Point;
      if(!p_hedge) trade.PositionClose(_Symbol);
      trade.SetExpertMagicNumber(EA_MAGIC);
      trade.Buy(lote, _Symbol, price, sl, tp, "MT-Live NLP");
   }
   else
   {
      if(p_stopPoints > 0) sl = price + MathMax(p_stopPoints, safety) * _Point;
      if(p_takePoints > 0) tp = price - p_takePoints * _Point;
      if(!p_hedge) trade.PositionClose(_Symbol);
      trade.SetExpertMagicNumber(EA_MAGIC);
      trade.Sell(lote, _Symbol, price, sl, tp, "MT-Live NLP");
   }
}

void GerenciaPosicoes()
{
   for(int i=PositionsTotal()-1; i>=0; i--)
   {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol && posInfo.Magic() == EA_MAGIC)
      {
         double priceCurrent = (posInfo.PositionType() == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double openPrice = posInfo.PriceOpen();
         double currentSL = posInfo.StopLoss();

         int points = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                      (int)((priceCurrent - openPrice) / _Point) :
                      (int)((openPrice - priceCurrent) / _Point);

         // Break-even
         if(p_breakEvenStart > 0 && points >= p_breakEvenStart)
         {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                           openPrice + p_breakEvenProfit * _Point :
                           openPrice - p_breakEvenProfit * _Point;

            if(currentSL == 0 || (posInfo.PositionType() == POSITION_TYPE_BUY && newSL > currentSL) || (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < currentSL || currentSL == 0)))
            {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
               continue; // Evita conflito com Trailing no mesmo tick
            }
         }

         // Trailing Stop
         if(p_trailingStart > 0 && points >= p_trailingStart)
         {
            double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ?
                           priceCurrent - p_trailingStart * _Point :
                           priceCurrent + p_trailingStart * _Point;

            if((posInfo.PositionType() == POSITION_TYPE_BUY && newSL > currentSL) ||
               (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < currentSL || currentSL == 0)))
            {
               trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
            }
         }
      }
   }
}

bool AguardaNoticias()
{
   // Simulação de leitura de arquivo news_veto.txt
   int handle = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      string content = FileReadString(handle);
      FileClose(handle);
      if(content == "1") return true;
   }
   return false;
}

void GravaCSV()
{
   static datetime lastWrite = 0;
   if(TimeCurrent() - lastWrite < 5) return;
   lastWrite = TimeCurrent();

   int handle = FileOpen("MT_Live_State.csv", FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      FileWrite(handle, "Ticket", "Symbol", "Type", "PriceOpen", "SL", "TP");
      for(int i=0; i<PositionsTotal(); i++)
      {
         if(posInfo.SelectByIndex(i) && posInfo.Magic() == EA_MAGIC)
            FileWrite(handle, posInfo.Ticket(), posInfo.Symbol(), posInfo.PositionType(), posInfo.PriceOpen(), posInfo.StopLoss(), posInfo.TakeProfit());
      }
      FileClose(handle);
   }
}

void GravaLog(string texto)
{
   int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ | FILE_WRITE | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      FileSeek(handle, 0, SEEK_END);
      FileWriteString(handle, TimeToString(TimeCurrent()) + ": " + texto + "\r\n");
      FileClose(handle);
   }
}

// --- Estatísticas e Otimização IA ---

struct Stats {
   double winRate;
   double profitFactor;
   double drawdown;
   int totalTrades;
};

Stats CalculaEstatisticas()
{
   Stats s;
   ZeroMemory(s);
   HistorySelect(0, TimeCurrent());
   int total = HistoryDealsTotal();
   double grossProfit = 0, grossLoss = 0;
   int wins = 0;

   for(int i=0; i<total; i++)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) == EA_MAGIC && HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
      {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + HistoryDealGetDouble(ticket, DEAL_COMMISSION) + HistoryDealGetDouble(ticket, DEAL_SWAP);
         s.totalTrades++;
         if(profit > 0) { wins++; grossProfit += profit; }
         else grossLoss -= profit;
      }
   }

   if(s.totalTrades > 0) s.winRate = (double)wins / s.totalTrades * 100.0;
   if(grossLoss > 0) s.profitFactor = grossProfit / grossLoss;
   else s.profitFactor = grossProfit;

   return s;
}

void AIOptimizer()
{
   Stats s = CalculaEstatisticas();
   if(s.totalTrades < 10) return;

   // Heurística de ajuste de risco
   if(s.winRate < 40.0 && p_riskPercent > 0.5) p_riskPercent -= 0.1;
   if(s.winRate > 60.0 && s.profitFactor > 1.5 && p_riskPercent < 2.0) p_riskPercent += 0.1;

   if(s.winRate < 30.0) SendNotification("ALERTA: Win rate crítico no MT-LiveExecutor (" + DoubleToString(s.winRate, 2) + "%)");
}

// --- Lifecycle Event Handlers ---

int OnInit()
{
   EventSetTimer(1);
   symInfo.Name(_Symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   // Tenta ler novo prompt de arquivo para atualização "ao vivo"
   int handle = FileOpen("prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
   if(handle != INVALID_HANDLE)
   {
      string prompt = FileReadString(handle);
      FileClose(handle);
      if(prompt != "")
      {
         InterpretaPrompt(prompt);
         int clearHandle = FileOpen("prompt.txt", FILE_WRITE | FILE_TXT | FILE_COMMON); // Limpa arquivo
         if(clearHandle != INVALID_HANDLE) FileClose(clearHandle);
         GravaLog("Estratégia atualizada via prompt.txt");
      }
   }

   AIOptimizer();
}

void OnTick()
{
   GerenciaPosicoes();
   GravaCSV();

   if(lastBarTime != iTime(_Symbol, p_frequency, 0))
   {
      lastBarTime = iTime(_Symbol, p_frequency, 0);
      Signal s = AvaliaTudo();
      if(s != NONE) EnviaOrdem(s);
   }
}

// --- Utilitários de busca robusta ---
double ExtraiValorApos(string txt, string chave)
{
   int pos = StringFind(txt, chave);
   if(pos < 0) return 0;
   return ExtraiNumero(StringSubstr(txt, pos + StringLen(chave)));
}
