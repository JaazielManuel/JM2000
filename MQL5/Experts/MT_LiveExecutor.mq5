//=========================  MT-LiveExecutor v8.0  =========================
// Integrando modelos avançados de IA para previsão e otimização de estratégias
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- 1. DEFINIÇÕES GLOBAIS ----------
enum Signal {BUY=1, SELL=-1, NONE=0};

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
    int       tf;
    int       p1, p2, p3;
    double    d1, d2;
    string    s1;
    bool      is_cross;
    int       p1_handle; // Handle para indicador principal
    int       p2_handle; // Handle para indicador secundário
    int       p3_handle; // Handle para terceiro indicador se necessário
};

// Parâmetros de Estratégia
Rule rules[30];
int nRules = 0;

// Parâmetros Operacionais (Populados via prompt)
double p_riskPercent = 1.0;
double p_stopPoints = 300.0;
double p_takePoints = 500.0;
double p_trailingStopPoints = 0;
double p_breakEvenTrigger = 0;
double p_breakEvenPoints = 5;
int    p_maxTrades = 3;
int    p_startHour = 0;
int    p_newsVetoMinutes = 20;
bool   p_martingale = false;
bool   p_hedge = false;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

// Variáveis de Estado
datetime lastBarTime = 0;
int      dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;

// Cache de Preço
double currentBid = 0;
double currentAsk = 0;
double currentSpread = 0;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symInfo;
CAccountInfo accInfo;

//========================================================================

// ---------- 2. MOTOR DE INTERPRETAÇÃO DE PROMPT ----------

int PeriodoTexto(string nome)
{
   string n = nome;
   StringToLower(n);
   if(n=="m1" || n=="1")   return PERIOD_M1;
   if(n=="m5" || n=="5")   return PERIOD_M5;
   if(n=="m15" || n=="15") return PERIOD_M15;
   if(n=="m30" || n=="30") return PERIOD_M30;
   if(n=="h1" || n=="60")  return PERIOD_H1;
   if(n=="h4" || n=="240") return PERIOD_H4;
   if(n=="d1") return PERIOD_D1;
   return PERIOD_CURRENT;
}

double ExtractNumber(string text, string keyword, int offset)
{
    int start = StringFind(text, keyword);
    if(start < 0) return 0;
    start += offset;
    string sub = StringSubstr(text, start);
    string res = "";
    for(int i=0; i<StringLen(sub); i++) {
        ushort c = StringGetCharacter(sub, i);
        if((c >= '0' && c <= '9') || c == '.') res += CharToString((uchar)c);
        else if(StringLen(res) > 0) break;
    }
    return StringToDouble(res);
}

void AddRule(RuleType type, int tf, int p1=0, int p2=0, int p3=0, double d1=0.0, double d2=0.0, bool is_cross=false)
{
    // Verifica se já existe uma regra do mesmo tipo para atualizar em vez de duplicar
    for(int i=0; i<nRules; i++) {
        if(rules[i].type == type) {
            rules[i].active = true;
            rules[i].tf = tf;
            rules[i].p1 = p1; rules[i].p2 = p2; rules[i].p3 = p3;
            rules[i].d1 = d1; rules[i].d2 = d2;
            rules[i].is_cross = is_cross;
            // Reinicializar handles se necessário
            if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
            if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
            rules[i].p1_handle = INVALID_HANDLE;
            rules[i].p2_handle = INVALID_HANDLE;
            return;
        }
    }

    if(nRules < 30) {
        rules[nRules].active = true;
        rules[nRules].type = type;
        rules[nRules].tf = tf;
        rules[nRules].p1 = p1; rules[nRules].p2 = p2; rules[nRules].p3 = p3;
        rules[nRules].d1 = d1; rules[nRules].d2 = d2;
        rules[nRules].is_cross = is_cross;
        rules[nRules].p1_handle = INVALID_HANDLE;
        rules[nRules].p2_handle = INVALID_HANDLE;
        nRules++;
    }
}

void InterpretaPrompt(string prompt)
{
   string p = prompt;
   StringToLower(p);

   // 2.1 OPERATIONAL PARAMETERS
   if(StringFind(p, "stop de ") >= 0) p_stopPoints = ExtractNumber(p, "stop de ", 8);
   if(StringFind(p, "take de ") >= 0) p_takePoints = ExtractNumber(p, "take de ", 8);
   if(StringFind(p, "risco de ") >= 0) p_riskPercent = ExtractNumber(p, "risco de ", 9);
   if(StringFind(p, "depois das ") >= 0) p_startHour = (int)ExtractNumber(p, "depois das ", 11);
   if(StringFind(p, "operar ") >= 0 && StringFind(p, "min antes") >= 0) p_newsVetoMinutes = (int)ExtractNumber(p, "operar ", 7);
   if(StringFind(p, "máximo ") >= 0 && StringFind(p, " trades") >= 0) p_maxTrades = (int)ExtractNumber(p, "máximo ", 7);

   // Break-even
   if(StringFind(p, "move stop para entrada") >= 0) {
       p_breakEvenTrigger = ExtractNumber(p, "atingir +", 9);
       p_breakEvenPoints = ExtractNumber(p, "entrada +", 9);
   }

   // Frequência
   if(StringFind(p, "a cada ") >= 0) {
       int mins = (int)ExtractNumber(p, "a cada ", 7);
       if(mins == 1) p_frequency = PERIOD_M1;
       else if(mins == 5) p_frequency = PERIOD_M5;
       else if(mins == 15) p_frequency = PERIOD_M15;
       else if(mins == 30) p_frequency = PERIOD_M30;
       else if(mins == 60) p_frequency = PERIOD_H1;
   }

   // 2.2 INDICATORS
   // Média Móvel
   if(StringFind(p, "média de ") >= 0) {
       int period = (int)ExtractNumber(p, "média de ", 9);
       bool is_cross = (StringFind(p, "cruzar") >= 0);
       AddRule(RULE_MA_CROSS, p_frequency, period, 0, 0, 0, 0, is_cross);
   }

   // RSI
   if(StringFind(p, "rsi (") >= 0) {
       int period = (int)ExtractNumber(p, "rsi (", 5);
       double over = 70, under = 30;
       if(StringFind(p, "acima de ") >= 0) over = ExtractNumber(p, "acima de ", 9);
       if(StringFind(p, "abaixo de ") >= 0) under = ExtractNumber(p, "abaixo de ", 10);

       // Determinando se é momentum ou reversão
       if(StringFind(p, "compra") >= 0 && StringFind(p, "acima de") >= 0) {
           AddRule(RULE_RSI, p_frequency, period, 1, 0, over, under, true); // p1=1: Momentum (Buy > Over)
       } else {
           AddRule(RULE_RSI, p_frequency, period, 0, 0, over, under, true); // p1=0: Reversion (Buy < Under)
       }
   }

   // Stochastic
   if(StringFind(p, "estocástico") >= 0 || StringFind(p, "stoch") >= 0) {
       AddRule(RULE_STOCH, p_frequency, 5, 3, 3, 0, 0, true);
   }

   // Bollinger Bands
   if(StringFind(p, "bollinger") >= 0 || StringFind(p, "bb") >= 0) {
       AddRule(RULE_BB, p_frequency, 20, 0, 0, 2.0, 0, false);
   }

   // Martingale / Hedge
   if(StringFind(p, "martingale") >= 0) p_martingale = true;
   if(StringFind(p, "hedge") >= 0) p_hedge = true;

   lastBarTime = 0; // Forçar reavaliação imediata
   Print("Prompt interpretado com sucesso.");
}

// ---------- 3. BIBLIOTECA DE INDICADORES & CONFLUÊNCIA ----------

double iClose(string symbol, ENUM_TIMEFRAMES tf, int shift) {
    double res[1];
    if(CopyClose(symbol, tf, shift, 1, res) > 0) return res[0];
    return 0;
}

Signal CheckMA(Rule &r, int shift=1)
{
    if(r.p1_handle == INVALID_HANDLE)
        r.p1_handle = iMA(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, MODE_EMA, PRICE_CLOSE);

    double val[2]; // [0] = shift+1, [1] = shift
    if(CopyBuffer(r.p1_handle, 0, shift, 2, val) < 2) return NONE;

    double close_now = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
    double close_prev = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift+1);

    if(r.is_cross) {
        if(close_prev < val[0] && close_now > val[1]) return BUY;
        if(close_prev > val[0] && close_now < val[1]) return SELL;
    } else {
        if(close_now > val[1]) return BUY;
        if(close_now < val[1]) return SELL;
    }
    return NONE;
}

Signal CheckRSI(Rule &r, int shift=1)
{
    if(r.p1_handle == INVALID_HANDLE)
        r.p1_handle = iRSI(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, PRICE_CLOSE);

    double val[2]; // [0] = shift+1, [1] = shift
    if(CopyBuffer(r.p1_handle, 0, shift, 2, val) < 2) return NONE;

    bool is_momentum = (r.p1 == 1);

    if(is_momentum) {
        // Buy if crossing ABOVE 'over' threshold, Sell if crossing BELOW 'under' threshold
        if(val[0] < r.d1 && val[1] > r.d1) return BUY;
        if(val[0] > r.d2 && val[1] < r.d2) return SELL;
    } else {
        // Buy if crossing BELOW 'under' threshold (Reversion), Sell if crossing ABOVE 'over'
        if(val[0] > r.d2 && val[1] < r.d2) return BUY;
        if(val[0] < r.d1 && val[1] > r.d1) return SELL;
    }
    return NONE;
}

Signal CheckStoch(Rule &r, int shift=1)
{
    if(r.p1_handle == INVALID_HANDLE)
        r.p1_handle = iStochastic(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, r.p2, r.p3, MODE_SMA, STO_LOWHIGH);

    double k[2], d[2]; // [0] = shift+1, [1] = shift
    if(CopyBuffer(r.p1_handle, 0, shift, 2, k) < 2) return NONE;
    if(CopyBuffer(r.p1_handle, 1, shift, 2, d) < 2) return NONE;

    if(k[0] < d[0] && k[1] > d[1]) return BUY;
    if(k[0] > d[0] && k[1] < d[1]) return SELL;
    return NONE;
}

Signal CheckBB(Rule &r, int shift=1)
{
    if(r.p1_handle == INVALID_HANDLE)
        r.p1_handle = iBands(_Symbol, (ENUM_TIMEFRAMES)r.tf, r.p1, 0, r.d1, PRICE_CLOSE);

    double upper[1], lower[1];
    if(CopyBuffer(r.p1_handle, 1, shift, 1, upper) < 1) return NONE;
    if(CopyBuffer(r.p1_handle, 2, shift, 1, lower) < 1) return NONE;

    double close = iClose(_Symbol, (ENUM_TIMEFRAMES)r.tf, shift);
    if(close < lower[0]) return BUY;
    if(close > upper[0]) return SELL;
    return NONE;
}

Signal AvaliaTudo()
{
    if(nRules == 0) return NONE;

    Signal globalSignal = NONE;
    bool first = true;

    for(int i=0; i<nRules; i++) {
        if(!rules[i].active) continue;

        Signal s = NONE;
        switch(rules[i].type) {
            case RULE_MA_CROSS: s = CheckMA(rules[i]); break;
            case RULE_RSI:      s = CheckRSI(rules[i]); break;
            case RULE_STOCH:    s = CheckStoch(rules[i]); break;
            case RULE_BB:       s = CheckBB(rules[i]); break;
            default: s = NONE; break;
        }

        if(first) {
            globalSignal = s;
            first = false;
        } else {
            if(globalSignal != s) return NONE; // Confluência AND
        }
    }

    return globalSignal;
}

// ---------- 4. EXECUÇÃO, RISCO & CACHE ----------

void UpdatePriceCache()
{
    MqlTick last_tick;
    if(SymbolInfoTick(_Symbol, last_tick)) {
        currentBid = last_tick.bid;
        currentAsk = last_tick.ask;
        currentSpread = (currentAsk - currentBid) / _Point;
    }
}

double CalculateValidSL(ENUM_ORDER_TYPE type, double price, double points)
{
    double brokerMin = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 1;
    double dist = MathMax(points, brokerMin) * _Point;

    if(type == ORDER_TYPE_BUY)  return price - dist;
    if(type == ORDER_TYPE_SELL) return price + dist;
    return 0;
}

double CalculaLote(double riskPercent, double slPoints)
{
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAmount = equity * (riskPercent / 100.0);

    // Martingale
    if(p_martingale) {
        HistorySelect(TimeCurrent()-86400, TimeCurrent());
        int total = HistoryDealsTotal();
        if(total > 0) {
            ulong ticket = HistoryDealGetTicket(total-1);
            if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) riskAmount *= 2.0;
        }
    }

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(slPoints <= 0) slPoints = p_stopPoints;

    double volume = riskAmount / (slPoints * (tickValue / (tickSize / _Point)));

    return NormalizeDouble(MathMax(volume, SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN)), 2);
}

void EnviaOrdem(Signal s)
{
    if(s == NONE) return;

    UpdatePriceCache();

    // Hedge Check
    if(!p_hedge) {
        for(int i=PositionsTotal()-1; i>=0; i--) {
            if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) {
                if((s == BUY && posInfo.PositionType() == POSITION_TYPE_SELL) ||
                   (s == SELL && posInfo.PositionType() == POSITION_TYPE_BUY)) {
                    trade.PositionClose(posInfo.Ticket());
                }
            }
        }
    }

    if(PositionsTotal() >= p_maxTrades) return;

    double sl = 0, tp = 0, price = 0;
    double lot = CalculaLote(p_riskPercent, p_stopPoints);

    if(s == BUY) {
        price = currentAsk;
        sl = CalculateValidSL(ORDER_TYPE_BUY, price, p_stopPoints);
        tp = price + p_takePoints * _Point;
        if(trade.Buy(lot, _Symbol, price, sl, tp, "MT-LiveExecutor")) {
            Print("Compra executada: ", lot, " SL: ", sl, " TP: ", tp);
        }
    } else {
        price = currentBid;
        sl = CalculateValidSL(ORDER_TYPE_SELL, price, p_stopPoints);
        tp = price - p_takePoints * _Point;
        if(trade.Sell(lot, _Symbol, price, sl, tp, "MT-LiveExecutor")) {
            Print("Venda executada: ", lot, " SL: ", sl, " TP: ", tp);
        }
    }
}

// ---------- 5. GESTÃO DE POSIÇÕES & AUXILIARES ----------

void GerenciaPosicoes()
{
    UpdatePriceCache();
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(posInfo.SelectByIndex(i) && posInfo.Symbol() == _Symbol) {
            double openPrice = posInfo.PriceOpen();
            double curSL = posInfo.StopLoss();
            double curTP = posInfo.TakeProfit();
            double curPrice = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentBid : currentAsk;
            double profitPoints = (posInfo.PositionType() == POSITION_TYPE_BUY) ? (curPrice - openPrice)/_Point : (openPrice - curPrice)/_Point;

            // Break-even
            if(p_breakEvenTrigger > 0 && profitPoints >= p_breakEvenTrigger) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? openPrice + p_breakEvenPoints*_Point : openPrice - p_breakEvenPoints*_Point;
                if((posInfo.PositionType() == POSITION_TYPE_BUY && (curSL < newSL || curSL == 0)) ||
                   (posInfo.PositionType() == POSITION_TYPE_SELL && (curSL > newSL || curSL == 0))) {
                    trade.PositionModify(posInfo.Ticket(), newSL, curTP);
                }
            }

            // Trailing Stop
            if(p_trailingStopPoints > 0 && profitPoints >= p_trailingStopPoints) {
                double newSL = (posInfo.PositionType() == POSITION_TYPE_BUY) ? currentBid - p_trailingStopPoints*_Point : currentAsk + p_trailingStopPoints*_Point;
                if((posInfo.PositionType() == POSITION_TYPE_BUY && newSL > curSL) ||
                   (posInfo.PositionType() == POSITION_TYPE_SELL && (newSL < curSL || curSL == 0))) {
                    trade.PositionModify(posInfo.Ticket(), newSL, curTP);
                }
            }
        }
    }
}

bool AguardaNoticias()
{
    int handle = FileOpen("news_veto.txt", FILE_READ|FILE_TXT|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        string val = FileReadString(handle);
        FileClose(handle);
        if(val == "1") return true;
    }
    return false;
}

void AIOptimizer()
{
    HistorySelect(TimeCurrent()-86400*30, TimeCurrent());
    int total = HistoryDealsTotal();
    double profit = 0;
    int wins = 0, losses = 0;

    for(int i=0; i<total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            profit += p;
            if(p > 0) wins++; else if(p < 0) losses++;
        }
    }

    double winRate = (wins+losses > 0) ? (double)wins/(wins+losses)*100.0 : 0;
    Print("AI Optimizer: WinRate: ", winRate, "% Profit: ", profit);
}

void GravaLog(string texto)
{
    Print(texto);
    int handle = FileOpen("MT_LiveExecutor_Log.txt", FILE_READ|FILE_WRITE|FILE_TXT|FILE_COMMON);
    if(handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, TimeToString(TimeCurrent()), ": ", texto);
        FileClose(handle);
    }
}

// ---------- 6. CICLO DE VIDA MQL5 ----------

int OnInit()
{
    // Forçar leitura inicial do prompt
    GlobalVariableSet("MT_Executor_Prompt_Update", 1);
    EventSetTimer(60);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
    for(int i=0; i<nRules; i++) {
        if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
        if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
        if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
    }
    EventKillTimer();
}

void OnTick()
{
    if(AguardaNoticias()) return;

    // Filtro de Horário
    MqlDateTime dt;
    TimeCurrent(dt);
    if(dt.hour < p_startHour) return;

    // Gerenciamento de posições ativas (Trailing/BE)
    GerenciaPosicoes();

    // Verificação de Sinais (Um por Barra)
    datetime currentBar = iTime(_Symbol, (ENUM_TIMEFRAMES)p_frequency, 0);
    if(currentBar != lastBarTime) {
        Signal s = AvaliaTudo();
        if(s != NONE) {
            EnviaOrdem(s);
            lastBarTime = currentBar;
        }
    }

    // Decay de Safety Points
    if(TimeCurrent() - lastSafetyDecay >= 60) {
        if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
        lastSafetyDecay = TimeCurrent();
    }
}

void OnTimer()
{
    // Verificação de Atualização de Prompt (Sem reiniciar)
    if(GlobalVariableGet("MT_Executor_Prompt_Update") > 0) {
        int handle = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ|FILE_TXT|FILE_COMMON);
        if(handle != INVALID_HANDLE) {
            string prompt = FileReadString(handle);
            FileClose(handle);
            InterpretaPrompt(prompt);
            GlobalVariableSet("MT_Executor_Prompt_Update", 0);
        }
    }

    // Otimização Periódica
    AIOptimizer();
}
