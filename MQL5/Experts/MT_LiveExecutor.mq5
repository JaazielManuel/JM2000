//+------------------------------------------------------------------+
//|                                              MT_LiveExecutor.mq5 |
//|                                  Copyright 2026, Profit Master v8.0|
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Profit Master v8.0"
#property link      "https://www.mql5.com"
#property version   "9.50"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>

// --- Input Parameters ---
input string InpPrompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 300 pontos, take de 500 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +300 pontos, move stop para entrada +50 pontos. Trailing stop de 100 pontos.";
input bool   InpPushAlerts = true;

// --- Enums and Structs ---
enum Signal { BUY = 1, SELL = -1, NONE = 0 };
enum RuleType { RT_MA_CROSS, RT_RSI, RT_STOCH, RT_BB, RT_DAILY_BREAK, RT_DELTA, RT_VOLUME, RT_AMA };

struct Rule {
    bool        active;
    RuleType    type;
    ENUM_TIMEFRAMES tf;
    int         p1, p2;
    int         p3_handle;
    int         p4_handle;
    double      d1, d2;
    bool        is_cross;
};

// --- Global Variables ---
Rule rules[30];
int nRules = 0;

string p_lastPrompt = "";
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;
double p_riskPercent = 1.0;
int p_stopPoints = 300;
int p_takePoints = 500;
int p_beTrigger = 300;
int p_beOffset = 50;
int p_trailingStop = 0;
double p_martingale = 1.0;
bool p_hedge = false;
int p_maxTrades = 100;
int p_newsVetoMin = 20;
int p_startHour = 10;

int dynamicSafetyPoints = 0;
datetime lastSafetyDecay = 0;
datetime lastBarTime = 0;
int atrHandle = INVALID_HANDLE;

CTrade trade;
CPositionInfo posInfo;
CSymbolInfo symbolInfo;

// --- Internal Structure Functions (as requested) ---

void InterpretaPrompt(string prompt)
{
    if(prompt == p_lastPrompt) return;
    GravaLog("Interpretando Prompt: " + prompt);
    p_lastPrompt = prompt;

    // Reset Rules and Handles
    for(int i=0; i<30; i++) {
        if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
        if(rules[i].p4_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p4_handle);
        ZeroMemory(rules[i]);
        rules[i].p3_handle = INVALID_HANDLE;
        rules[i].p4_handle = INVALID_HANDLE;
    }
    nRules = 0;
    lastBarTime = 0;

    // Global Strategy Parameters
    p_frequency = MinutesToTimeframe(ExtraiNumero(prompt, "cada "));
    p_startHour = ExtraiNumero(prompt, "depois das ");
    p_riskPercent = ExtraiDouble(prompt, "risco de ");
    if(p_riskPercent == 0) p_riskPercent = 1.0;
    p_stopPoints = ExtraiNumero(prompt, "stop de ");
    p_takePoints = ExtraiNumero(prompt, "take de ");
    p_newsVetoMin = ExtraiNumero(prompt, "operar ");
    p_maxTrades = ExtraiNumero(prompt, "Máximo ");
    if(p_maxTrades == 0) p_maxTrades = 100;
    p_beTrigger = ExtraiNumero(prompt, "atingir +");
    p_beOffset = ExtraiNumero(prompt, "entrada +");
    p_trailingStop = ExtraiNumero(prompt, "Trailing stop de ");

    if(StringFind(prompt, "Martingale") >= 0) p_martingale = 2.0; else p_martingale = 1.0;
    p_hedge = (StringFind(prompt, "Hedge") >= 0);

    // Segment-based Rule Parsing
    string segments[];
    string tempPrompt = prompt;
    StringReplace(tempPrompt, " e ", "|");
    StringReplace(tempPrompt, " + ", "|");
    StringSplit(tempPrompt, '|', segments);

    for(int i=0; i<ArraySize(segments); i++)
    {
        string s = segments[i];
        if(StringFind(s, "média") >= 0) {
            rules[nRules].active = true;
            rules[nRules].type = RT_MA_CROSS;
            rules[nRules].p1 = ExtraiNumero(s, "média de ");
            rules[nRules].tf = p_frequency;
            rules[nRules].is_cross = (StringFind(s, "cruzar") >= 0);
            rules[nRules].p3_handle = iMA(_Symbol, rules[nRules].tf, rules[nRules].p1, 0, MODE_EMA, PRICE_CLOSE);
            nRules++;
        }
        else if(StringFind(s, "RSI") >= 0) {
            rules[nRules].active = true;
            rules[nRules].type = RT_RSI;
            rules[nRules].p1 = ExtraiNumero(s, "RSI (");
            rules[nRules].d1 = ExtraiDouble(s, "acima de ");
            if(rules[nRules].d1 == 0) rules[nRules].d1 = ExtraiDouble(s, "subir acima de ");
            rules[nRules].d2 = ExtraiDouble(s, "abaixo de ");
            if(rules[nRules].d2 == 0) rules[nRules].d2 = ExtraiDouble(s, "cair abaixo de ");
            rules[nRules].tf = p_frequency;
            rules[nRules].is_cross = (StringFind(s, "subir") >= 0 || StringFind(s, "cair") >= 0);
            rules[nRules].p3_handle = iRSI(_Symbol, rules[nRules].tf, rules[nRules].p1, PRICE_CLOSE);
            nRules++;
        }
    }
}

Signal AvaliaCondicoes()
{
    if(nRules == 0) return NONE;
    Signal vote = NONE;
    for(int i=0; i<nRules; i++) {
        Signal s = NONE;
        switch(rules[i].type) {
            case RT_MA_CROSS: s = CruzamentoMA(rules[i], 1); break;
            case RT_RSI:      s = RSIThreshold(rules[i], 1); break;
        }
        if(s == NONE) return NONE;
        if(i == 0) vote = s;
        else if(vote != s) return NONE;
    }
    return vote;
}

double CalculaLote(double risco)
{
    double lot = (AccountInfoDouble(ACCOUNT_BALANCE) * (risco/100.0)) / (MathMax(p_stopPoints, 100) * SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE));

    // Martingale Logic: Multiplier if last trade was a loss
    if(p_martingale > 1.0) {
        HistorySelect(TimeCurrent()-86400, TimeCurrent());
        int total = HistoryDealsTotal();
        if(total > 0) {
            ulong ticket = HistoryDealGetTicket(total-1);
            if(HistoryDealSelect(ticket)) {
                if(HistoryDealGetDouble(ticket, DEAL_PROFIT) < 0) lot *= p_martingale;
            }
        }
    }
    return NV(lot);
}

void EnviaOrdem(Signal s)
{
    if(s == NONE || AguardaNoticias()) return;
    if(PositionsTotal() >= p_maxTrades) return;

    double lote = CalculaLote(p_riskPercent);
    UpdatePriceCache();
    double sl = 0, tp = 0;
    int safety = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 2;
    int slPts = MathMax(p_stopPoints, safety);

    if(s == BUY) {
        sl = NS(symbolInfo.Bid() - slPts * _Point);
        tp = NS(symbolInfo.Ask() + p_takePoints * _Point);
        if(trade.Buy(lote, _Symbol, symbolInfo.Ask(), sl, tp)) GravaLog("Compra Executada");
    } else if(s == SELL) {
        sl = NS(symbolInfo.Ask() + slPts * _Point);
        tp = NS(symbolInfo.Bid() - p_takePoints * _Point);
        if(trade.Sell(lote, _Symbol, symbolInfo.Bid(), sl, tp)) GravaLog("Venda Executada");
    }
}

void GerenciaPosicoes()
{
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(posInfo.SelectByTicket(PositionGetTicket(i)) && posInfo.Symbol() == _Symbol) {
            double open = posInfo.PriceOpen(), cur = posInfo.PriceCurrent(), sl = posInfo.StopLoss();

            // Breakeven
            if(posInfo.PositionType() == POSITION_TYPE_BUY) {
                if(p_beTrigger > 0 && cur >= open + p_beTrigger * _Point) {
                    double nSL = NS(open + p_beOffset * _Point);
                    if(sl < nSL) trade.PositionModify(posInfo.Ticket(), nSL, posInfo.TakeProfit());
                }
                // Trailing Stop
                if(p_trailingStop > 0 && cur > open + p_trailingStop * _Point) {
                    double nSL = NS(cur - p_trailingStop * _Point);
                    if(sl < nSL) trade.PositionModify(posInfo.Ticket(), nSL, posInfo.TakeProfit());
                }
            } else {
                if(p_beTrigger > 0 && cur <= open - p_beTrigger * _Point) {
                    double nSL = NS(open - p_beOffset * _Point);
                    if(sl == 0 || sl > nSL) trade.PositionModify(posInfo.Ticket(), nSL, posInfo.TakeProfit());
                }
                // Trailing Stop
                if(p_trailingStop > 0 && cur < open - p_trailingStop * _Point) {
                    double nSL = NS(cur + p_trailingStop * _Point);
                    if(sl == 0 || sl > nSL) trade.PositionModify(posInfo.Ticket(), nSL, posInfo.TakeProfit());
                }
            }
        }
    }
}

bool AguardaNoticias()
{
    MqlCalendarValue v[];
    datetime from = TimeCurrent() - p_newsVetoMin * 60;
    datetime to = TimeCurrent() + p_newsVetoMin * 60;
    if(CalendarValueHistory(v, from, to, _Symbol) > 0) {
        for(int i=0; i<ArraySize(v); i++) if(v[i].importance >= CALENDAR_IMPORTANCE_HIGH) return true;
    }
    return false;
}

void GravaLog(string texto)
{
    Print(texto);
    if(InpPushAlerts) SendNotification(texto);
    int h = FileOpen("MT_LiveExecutor_Log.csv", FILE_WRITE|FILE_READ|FILE_CSV|FILE_ANSI|FILE_COMMON);
    if(h != INVALID_HANDLE) { FileSeek(h, 0, SEEK_END); FileWrite(h, TimeToString(TimeCurrent()), texto); FileClose(h); }
}

// --- Helper Functions ---

Signal CruzamentoMA(Rule &r, int shift)
{
    double val1[2]; if(CopyBuffer(r.p3_handle, 0, shift, 2, val1) < 2) return NONE;
    double c0 = iClose(_Symbol, r.tf, shift), c1 = iClose(_Symbol, r.tf, shift+1);
    if(r.is_cross) {
        if(c1 < val1[1] && c0 > val1[0]) return BUY;
        if(c1 > val1[1] && c0 < val1[0]) return SELL;
    } else {
        if(c0 > val1[0]) return BUY;
        if(c0 < val1[0]) return SELL;
    }
    return NONE;
}

Signal RSIThreshold(Rule &r, int shift)
{
    double val[2]; if(CopyBuffer(r.p3_handle, 0, shift, 2, val) < 2) return NONE;
    if(r.is_cross) {
        if(val[1] <= r.d1 && val[0] > r.d1) return BUY;
        if(val[1] >= r.d2 && val[0] < r.d2) return SELL;
    } else {
        if(val[0] > r.d1) return BUY;
        if(val[0] < r.d2) return SELL;
    }
    return NONE;
}

int ExtraiNumero(string txt, string chave)
{
    int pos = StringFind(txt, chave); if(pos == -1) return 0;
    string sub = StringSubstr(txt, pos + StringLen(chave)), res = "";
    for(int i=0; i<StringLen(sub); i++) {
        ushort c = StringGetCharacter(sub, i);
        if(c >= '0' && c <= '9') res += ShortToString(c); else if(res != "") break;
    }
    return (int)StringToInteger(res);
}

double ExtraiDouble(string txt, string chave)
{
    int pos = StringFind(txt, chave); if(pos == -1) return 0.0;
    string sub = StringSubstr(txt, pos + StringLen(chave)), res = ""; bool dot = false;
    for(int i=0; i<StringLen(sub); i++) {
        ushort c = StringGetCharacter(sub, i);
        if(c >= '0' && c <= '9') res += ShortToString(c);
        else if(c == '.' || c == ',') { if(!dot) { res += "."; dot = true; } else break; }
        else if(res != "") break;
    }
    return StringToDouble(res);
}

ENUM_TIMEFRAMES MinutesToTimeframe(int m) { return (m<=1)?PERIOD_M1:(m<=5)?PERIOD_M5:(m<=15)?PERIOD_M15:(m<=30)?PERIOD_M30:(m<=60)?PERIOD_H1:(m<=240)?PERIOD_H4:PERIOD_D1; }
void UpdatePriceCache() { symbolInfo.RefreshTicks(); }
double NS(double p) { return NormalizeDouble(p, _Digits); }
double NV(double v) { double s = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP); return NormalizeDouble(MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), MathRound(v/s)*s), 2); }

void SynchronizeClusterSL(double sl, ENUM_POSITION_TYPE type)
{
    for(int i=0; i<PositionsTotal(); i++) {
        if(posInfo.SelectByTicket(PositionGetTicket(i)) && posInfo.Symbol() == _Symbol && posInfo.PositionType() == type)
            trade.PositionModify(posInfo.Ticket(), sl, posInfo.TakeProfit());
    }
}

void AIOptimizer()
{
    if(atrHandle == INVALID_HANDLE) return;
    double atr[1]; if(CopyBuffer(atrHandle, 0, 0, 1, atr) > 0) {
        GravaLog("AI Optimizer: Analisando volatilidade (ATR=" + DoubleToString(atr[0], _Digits) + ")");
    }
}

// --- Lifecycle Handlers ---

void OnTick()
{
    InterpretaPrompt(InpPrompt);
    MqlDateTime dt; TimeCurrent(dt);
    if(dt.hour < p_startHour) return;

    datetime bar = iTime(_Symbol, p_frequency, 0);
    if(bar != lastBarTime) {
        Signal s = AvaliaCondicoes();
        if(s != NONE) EnviaOrdem(s);
        lastBarTime = bar;
    }
    GerenciaPosicoes();

    if(TimeCurrent() - lastSafetyDecay > 60) {
        if(dynamicSafetyPoints > 0) dynamicSafetyPoints--;
        lastSafetyDecay = TimeCurrent();
    }
}

void OnTradeTransaction(const MqlTradeTransaction& trans, const MqlTradeRequest& req, const MqlTradeResult& res)
{
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD && HistoryDealSelect(trans.deal) && HistoryDealGetInteger(trans.deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
        SynchronizeClusterSL(HistoryDealGetDouble(trans.deal, DEAL_SL), (ENUM_POSITION_TYPE)HistoryDealGetInteger(trans.deal, DEAL_TYPE));
}

int OnInit() {
    symbolInfo.Name(_Symbol);
    atrHandle = iATR(_Symbol, PERIOD_H1, 14);
    InterpretaPrompt(InpPrompt);
    EventSetTimer(3600);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
    for(int i=0; i<30; i++) {
        if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
        if(rules[i].p4_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p4_handle);
    }
    EventKillTimer();
}

// --- MQL4 Compatibility ---
double iClose(string s, ENUM_TIMEFRAMES tf, int sh) { double r[1]; return (CopyClose(s, tf, sh, 1, r) > 0) ? r[0] : 0; }
datetime iTime(string s, ENUM_TIMEFRAMES tf, int sh) { datetime r[1]; return (CopyTime(s, tf, sh, 1, r) > 0) ? r[0] : 0; }
