//=========================  MT-LiveExecutor  =========================
// Real-time strategy interpreter for MetaTrader 5
// Translated from Portuguese natural language prompts
// Optimized for Low Latency and Live Execution
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- INPUTS ----------
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos.";

// ---------- ENUMS & STRUCTS ----------
enum ENUM_SIGNAL { SIGNAL_NONE = 0, SIGNAL_BUY = 1, SIGNAL_SELL = -1 };

struct Rule {
    bool active;
    int type; // 1: MA, 2: RSI, 3: STOCH, 4: BB
    ENUM_TIMEFRAMES timeframe;
    int p1, p2, p3;
    double d1, d2;
    string s1;
    int handle;
};

struct StrategyRules {
    Rule rules[20];
    int nRules;
    ENUM_TIMEFRAMES interval;
    int startHour;
    double riskPercent;
    int stopLossPoints;
    int takeProfitPoints;
    int maxTrades;
    int newsVetoMinutes;
    int breakevenTriggerPoints;
    int breakevenProfitPoints;
    int trailingStopPoints;
    bool alerts;
    bool martingale;
    bool hedge;
};

struct Stats {
    int wins;
    int losses;
    double totalProfit;
    double maxDrawdown;
};

// ---------- GLOBAL VARIABLES ----------
StrategyRules currentStrategy;
Stats currentStats;
CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;
CAccountInfo accountInfo;
string currentPrompt = "";
datetime lastExecutionTime = 0;
const int MAGIC_NUMBER = 123456;

// ---------- HELPERS ----------

double NS(double price) {
    double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    if (tickSize == 0) return price;
    return MathRound(price / tickSize) * tickSize;
}

double NV(double volume) {
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    if (step == 0) return volume;
    double v = MathRound(volume / step) * step;
    return NormalizeDouble(v, 2);
}

int PositionsTotalByMagic() {
    int count = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (posInfo.SelectByIndex(i)) {
            if (posInfo.Symbol() == _Symbol && posInfo.Magic() == MAGIC_NUMBER) count++;
        }
    }
    return count;
}

// ---------- BASE CORE FUNCTIONS ----------

ENUM_SIGNAL PriceCrossMA(int &handle, int period, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iMA(_Symbol, tf, period, 0, MODE_SMA, PRICE_CLOSE);
    double ma[], close[];
    ArraySetAsSeries(ma, true); ArraySetAsSeries(close, true);
    if (CopyBuffer(handle, 0, shift, 2, ma) < 2 || CopyClose(_Symbol, tf, shift, 2, close) < 2) return SIGNAL_NONE;
    if (close[1] < ma[1] && close[0] > ma[0]) return SIGNAL_BUY;
    if (close[1] > ma[1] && close[0] < ma[0]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

ENUM_SIGNAL RSICheck(int &handle, int period, double buyLevel, double sellLevel, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iRSI(_Symbol, tf, period, PRICE_CLOSE);
    double rsi[];
    ArraySetAsSeries(rsi, true);
    if (CopyBuffer(handle, 0, shift, 1, rsi) < 1) return SIGNAL_NONE;
    if (rsi[0] > buyLevel) return SIGNAL_BUY;
    if (rsi[0] < sellLevel) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

ENUM_SIGNAL StochCheck(int &handle, int k, int d, int slowing, ENUM_TIMEFRAMES tf, int shift) {
    if (handle == INVALID_HANDLE) handle = iStochastic(_Symbol, tf, k, d, slowing, MODE_SMA, STO_LOWHIGH);
    double k_line[], d_line[];
    ArraySetAsSeries(k_line, true); ArraySetAsSeries(d_line, true);
    if (CopyBuffer(handle, 0, shift, 2, k_line) < 2 || CopyBuffer(handle, 1, shift, 2, d_line) < 2) return SIGNAL_NONE;
    if (k_line[1] < d_line[1] && k_line[0] > d_line[0]) return SIGNAL_BUY;
    if (k_line[1] > d_line[1] && k_line[0] < d_line[0]) return SIGNAL_SELL;
    return SIGNAL_NONE;
}

// ---------- INTERPRETER ----------

double GetNextNumber(string text, int startPos) {
    string res = ""; bool started = false;
    for(int i=startPos; i<StringLen(text); i++) {
        ushort c = StringGetCharacter(text, i);
        if((c >= '0' && c <= '9') || c == '.') { res += StringSubstr(text, i, 1); started = true; }
        else if(started) break;
    }
    return StringToDouble(res);
}

ENUM_TIMEFRAMES PeriodoTexto(string nome) {
    StringToLower(nome);
    if(StringFind(nome,"m1")>=0 || StringFind(nome,"1 minuto")>=0)  return PERIOD_M1;
    if(StringFind(nome,"m5")>=0 || StringFind(nome,"5 minuto")>=0)  return PERIOD_M5;
    if(StringFind(nome,"m15")>=0 || StringFind(nome,"15 minuto")>=0) return PERIOD_M15;
    if(StringFind(nome,"h1")>=0 || StringFind(nome,"1 hora")>=0)    return PERIOD_H1;
    if(StringFind(nome,"d1")>=0 || StringFind(nome,"1 dia")>=0)     return PERIOD_D1;
    return PERIOD_CURRENT;
}

void InterpretaPrompt(string prompt) {
    StringToLower(prompt);
    GravaLog("Interpretando novo prompt...");

    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (currentStrategy.rules[i].handle != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle);
    }
    ZeroMemory(currentStrategy);
    currentStrategy.interval = PERIOD_CURRENT;
    currentStrategy.riskPercent = 1.0;
    currentStrategy.maxTrades = 100; // Sensible default

    int pos = StringFind(prompt, "cada ");
    if (pos >= 0) currentStrategy.interval = PeriodoTexto(StringSubstr(prompt, pos, 20));

    pos = StringFind(prompt, "depois das ");
    if (pos >= 0) currentStrategy.startHour = (int)GetNextNumber(prompt, pos + 11);

    pos = StringFind(prompt, "média de ");
    if (pos >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.active = true; r.type = 1;
        r.p1 = (int)GetNextNumber(prompt, pos + 9);
        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
    }

    pos = StringFind(prompt, "rsi");
    if (pos >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.active = true; r.type = 2;
        r.p1 = (int)GetNextNumber(prompt, pos + 3);
        if (r.p1 <= 0) r.p1 = 14;
        r.d1 = 55; r.d2 = 45;
        int pAbove = StringFind(prompt, "acima de ", pos);
        if (pAbove >= 0) r.d1 = GetNextNumber(prompt, pAbove + 9);
        int pBelow = StringFind(prompt, "abaixo de ", pos);
        if (pBelow >= 0) r.d2 = GetNextNumber(prompt, pBelow + 10);
        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
    }

    pos = StringFind(prompt, "estocástico");
    if (pos >= 0) {
        Rule r; r.handle = INVALID_HANDLE; r.active = true; r.type = 3;
        r.p1 = 5; r.p2 = 3; r.p3 = 3;
        r.timeframe = currentStrategy.interval;
        currentStrategy.rules[currentStrategy.nRules++] = r;
    }

    pos = StringFind(prompt, "stop de ");
    if (pos >= 0) currentStrategy.stopLossPoints = (int)GetNextNumber(prompt, pos + 8);
    pos = StringFind(prompt, "take de ");
    if (pos >= 0) currentStrategy.takeProfitPoints = (int)GetNextNumber(prompt, pos + 8);
    pos = StringFind(prompt, "risco de ");
    if (pos >= 0) currentStrategy.riskPercent = GetNextNumber(prompt, pos + 9);
    pos = StringFind(prompt, "máximo ");
    if (pos >= 0) currentStrategy.maxTrades = (int)GetNextNumber(prompt, pos + 7);

    pos = StringFind(prompt, "notícias");
    if (pos >= 0) currentStrategy.newsVetoMinutes = 20;

    pos = StringFind(prompt, "atingir +");
    if (pos >= 0) currentStrategy.breakevenTriggerPoints = (int)GetNextNumber(prompt, pos + 9);
    pos = StringFind(prompt, "entrada +");
    if (pos >= 0) currentStrategy.breakevenProfitPoints = (int)GetNextNumber(prompt, pos + 9);

    if (StringFind(prompt, "trailing") >= 0) currentStrategy.trailingStopPoints = 30; // Default

    if (StringFind(prompt, "alerta") >= 0 || StringFind(prompt, "notificar") >= 0) currentStrategy.alerts = true;

    if (StringFind(prompt, "martingale") >= 0) currentStrategy.martingale = true;
    if (StringFind(prompt, "hedge") >= 0) currentStrategy.hedge = true;

    GravaLog("Estratégia configurada com sucesso.");
}

// ---------- LOGGING & STATS ----------

void GravaLog(string text) {
    string timeStr = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
    PrintFormat("[%s] MT-LiveExecutor: %s", timeStr, text);
    int handle = FileOpen("MT_LiveExecutor_Log.csv", FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ);
    if (handle != INVALID_HANDLE) {
        FileSeek(handle, 0, SEEK_END);
        FileWrite(handle, timeStr, text);
        FileClose(handle);
    }
}

void AtualizaStats() {
    HistorySelect(0, TimeCurrent());
    int total = HistoryDealsTotal();
    currentStats.wins = 0; currentStats.losses = 0; currentStats.totalProfit = 0;
    for (int i = 0; i < total; i++) {
        ulong ticket = HistoryDealGetTicket(i);
        if (HistoryDealGetInteger(ticket, DEAL_MAGIC) == MAGIC_NUMBER) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            if (profit > 0) currentStats.wins++;
            else if (profit < 0) currentStats.losses++;
            currentStats.totalProfit += profit;
        }
    }
}

// ---------- NEWS FILTER ----------

bool AguardaNoticias() {
    if (currentStrategy.newsVetoMinutes <= 0) return false;
    MqlCalendarValue values[];
    datetime from = TimeCurrent() - currentStrategy.newsVetoMinutes * 60;
    datetime to = TimeCurrent() + currentStrategy.newsVetoMinutes * 60;
    if (CalendarValueHistory(values, from, to)) {
        for (int i = 0; i < ArraySize(values); i++) {
            MqlCalendarEvent event;
            if (CalendarEventById(values[i].event_id, event)) {
                if (event.importance == CALENDAR_IMPORTANCE_HIGH) return true;
            }
        }
    }
    return false;
}

// ---------- EXECUTION ----------

void EnviaOrdem(string tipo, double preco, double sl, double tp, double lote) {
    double nLote = NV(lote);
    double nSL = (sl != 0) ? NS(sl) : 0;
    double nTP = (tp != 0) ? NS(tp) : 0;
    double nPrice = NS(preco);

    bool res = false;
    if (tipo == "BUY") res = trade.Buy(nLote, _Symbol, nPrice, nSL, nTP, "MT-LiveExecutor BUY");
    else res = trade.Sell(nLote, _Symbol, nPrice, nSL, nTP, "MT-LiveExecutor SELL");

    if (res) {
        string msg = StringFormat("%s executada: Lote %.2f, Preço %.5f", tipo, nLote, nPrice);
        GravaLog(msg);
        if (currentStrategy.alerts) {
            SendNotification(msg);
            SendMail("MT-LiveExecutor Alert", msg);
        }
    }
}

ENUM_SIGNAL AvaliaCondicoes() {
    MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
    if (dt.hour < currentStrategy.startHour) return SIGNAL_NONE;
    if (AguardaNoticias()) return SIGNAL_NONE;
    if (PositionsTotalByMagic() >= currentStrategy.maxTrades) return SIGNAL_NONE;

    int buyVotes = 0, sellVotes = 0, activeRules = 0;
    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (!currentStrategy.rules[i].active) continue;
        activeRules++;
        ENUM_SIGNAL s = SIGNAL_NONE;
        if (currentStrategy.rules[i].type == 1) s = PriceCrossMA(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].timeframe, 1);
        else if (currentStrategy.rules[i].type == 2) s = RSICheck(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].d1, currentStrategy.rules[i].d2, currentStrategy.rules[i].timeframe, 1);
        else if (currentStrategy.rules[i].type == 3) s = StochCheck(currentStrategy.rules[i].handle, currentStrategy.rules[i].p1, currentStrategy.rules[i].p2, currentStrategy.rules[i].p3, currentStrategy.rules[i].timeframe, 1);
        if (s == SIGNAL_BUY) buyVotes++;
        if (s == SIGNAL_SELL) sellVotes++;
    }
    if (activeRules > 0) {
        if (buyVotes == activeRules) return SIGNAL_BUY;
        if (sellVotes == activeRules) return SIGNAL_SELL;
    }
    return SIGNAL_NONE;
}

double CalculaLote(double riskPercent) {
    double lot = 0;
    if (currentStrategy.martingale) {
        HistorySelect(0, TimeCurrent());
        int total = HistoryDealsTotal();
        double lastProfit = 0;
        double lastLot = 0;
        for (int i = total - 1; i >= 0; i--) {
            ulong ticket = HistoryDealGetTicket(i);
            if (HistoryDealGetInteger(ticket, DEAL_MAGIC) == MAGIC_NUMBER) {
                lastProfit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
                lastLot = HistoryDealGetDouble(ticket, DEAL_VOLUME);
                break;
            }
        }
        if (lastProfit < 0) lot = lastLot * 2;
    }

    if (lot == 0) {
        double equity = AccountInfoDouble(ACCOUNT_EQUITY);
        double riskMoney = equity * (riskPercent / 100.0);
        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
        double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
        if (currentStrategy.stopLossPoints <= 0) lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        else lot = riskMoney / ((currentStrategy.stopLossPoints * _Point) * (tickValue / tickSize));
    }

    return NV(lot);
}

void GerenciaPosicoes() {
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
        if (posInfo.SelectByIndex(i)) {
            if (posInfo.Symbol() != _Symbol || posInfo.Magic() != MAGIC_NUMBER) continue;
            double openPrice = posInfo.PriceOpen();
            double currentPrice = posInfo.PriceCurrent();
            double stopLoss = posInfo.StopLoss();
            double stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;

            // Breakeven
            if (currentStrategy.breakevenTriggerPoints > 0) {
                if (posInfo.PositionType() == POSITION_TYPE_BUY) {
                    if (currentPrice >= openPrice + currentStrategy.breakevenTriggerPoints * _Point) {
                        double newSL = NS(openPrice + currentStrategy.breakevenProfitPoints * _Point);
                        if (stopLoss < newSL && currentPrice > newSL + stopsLevel) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                    }
                } else {
                    if (currentPrice <= openPrice - currentStrategy.breakevenTriggerPoints * _Point) {
                        double newSL = NS(openPrice - currentStrategy.breakevenProfitPoints * _Point);
                        if ((stopLoss > newSL || stopLoss == 0) && currentPrice < newSL - stopsLevel) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                    }
                }
            }
            // Trailing Stop (Simplified)
            if (currentStrategy.trailingStopPoints > 0) {
                if (posInfo.PositionType() == POSITION_TYPE_BUY) {
                    double newSL = NS(currentPrice - currentStrategy.trailingStopPoints * _Point);
                    if (newSL > stopLoss + 5 * _Point && currentPrice > newSL + stopsLevel) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                } else {
                    double newSL = NS(currentPrice + currentStrategy.trailingStopPoints * _Point);
                    if ((newSL < stopLoss - 5 * _Point || stopLoss == 0) && currentPrice < newSL - stopsLevel) trade.PositionModify(posInfo.Ticket(), newSL, posInfo.TakeProfit());
                }
            }
        }
    }
}

// ---------- SCRIPT LIFECYCLE ----------

int OnInit() {
    trade.SetExpertMagicNumber(MAGIC_NUMBER);
    symbolInfo.Name(_Symbol);
    InterpretaPrompt(InpPrompt);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    for (int i = 0; i < currentStrategy.nRules; i++) {
        if (currentStrategy.rules[i].handle != INVALID_HANDLE) IndicatorRelease(currentStrategy.rules[i].handle);
    }
}

void OnTick() {
    static string lastPrompt = "";
    if (InpPrompt != lastPrompt) { InterpretaPrompt(InpPrompt); lastPrompt = InpPrompt; }
    bool isNewBar = false;
    datetime currentBarTime = iTime(_Symbol, currentStrategy.interval, 0);
    if (currentBarTime != lastExecutionTime) { isNewBar = true; lastExecutionTime = currentBarTime; }
    if (isNewBar) {
        ENUM_SIGNAL sig = AvaliaCondicoes();
        if (sig != SIGNAL_NONE) {
            MqlTick tick; if (!SymbolInfoTick(_Symbol, tick)) return;
            double lot = CalculaLote(currentStrategy.riskPercent);
            double sl = 0, tp = 0;
            double price = (sig == SIGNAL_BUY) ? tick.ask : tick.bid;
            if (sig == SIGNAL_BUY) {
                sl = price - currentStrategy.stopLossPoints * _Point;
                tp = price + currentStrategy.takeProfitPoints * _Point;
                EnviaOrdem("BUY", price, sl, tp, lot);
            } else {
                sl = price + currentStrategy.stopLossPoints * _Point;
                tp = price - currentStrategy.takeProfitPoints * _Point;
                EnviaOrdem("SELL", price, sl, tp, lot);
            }
        }
        AtualizaStats();
    }
    GerenciaPosicoes();
}
