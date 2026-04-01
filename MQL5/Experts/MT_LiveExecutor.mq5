//=========================  MT5-LIVE-EXECUTOR  =========================
// Agent-controlled execution script for MetaTrader 5.
// Integrates technical analysis, NLP parsing, and risk management.
//========================================================================

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Indicators\Indicators.mqh>

// ---------- GLOBAL CONSTANTS ----------
#define EA_MAGIC 20260101
#define MAX_RULES 50

// ---------- ENUMS ----------
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
    RULE_RELATIVE
};

// ---------- STRUCTS ----------
struct Rule {
    bool        active;
    RuleType    type;
    int         tf;
    int         p1, p2;
    double      d1, d2;
    string      s1;
    Signal      intent;
    bool        is_cross;
    int         p1_handle;
    int         p2_handle;
    int         p3_handle;
};

// ---------- GLOBAL OPERATIONAL VARIABLES ----------
Rule        rules[MAX_RULES];
int         nRules = 0;

double      p_riskPercent = 1.0;
int         p_stopPoints = 0;
int         p_takePoints = 0;
int         p_trailingStopPoints = 0;
int         p_breakEvenPoints = 0;
int         p_breakEvenOffset = 5;
int         p_maxTrades = 1;
bool        p_hedge = false;
bool        p_martingale = false;
string      p_startTimeStr = "00:00";
int         p_startTimeSeconds = 0;
int         p_newsVetoMinutes = 0;
ENUM_TIMEFRAMES p_frequency = PERIOD_M15;

datetime    lastBarTime = 0;
int         dynamicSafetyPoints = 0;
datetime    lastSafetyDecay = 0;
datetime    lastCSVWrite = 0;

CTrade          trade;
CPositionInfo   m_pos;
CSymbolInfo     m_symbol;
CAccountInfo    m_account;

// Forward declarations
void ResetStrategy();
void InterpretaPrompt(string prompt);
void AddRule(RuleType type, int tf, int p1, int p2, double d1, double d2, Signal intent, bool is_cross);
Signal AvaliaTudo();
double CalculaLote(double riscoPercent);
void EnviaOrdem(Signal s, double volume);
void GerenciaPosicoes();
bool AguardaNoticias();
void GravaCSV();
void AIOptimizer();
double ExtractNumber(string txt, string keyword);
string ExtractTime(string txt);
int PeriodoTexto(string nome);

// ---------- 2. UTILITIES & NLP PARSING ----------

void ResetStrategy() {
    for(int i=0; i<nRules; i++) {
        if(rules[i].p1_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p1_handle);
        if(rules[i].p2_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p2_handle);
        if(rules[i].p3_handle != INVALID_HANDLE) IndicatorRelease(rules[i].p3_handle);
        rules[i].active = false;
    }
    nRules = 0;
    p_riskPercent = 1.0; p_stopPoints = 0; p_takePoints = 0; p_trailingStopPoints = 0; p_breakEvenPoints = 0; p_maxTrades = 1; p_hedge = false; p_martingale = false; p_newsVetoMinutes = 0; p_startTimeSeconds = 0;
}

void InterpretaPrompt(string prompt) {
    ResetStrategy();
    string p = prompt; StringToLower(p);
    StringReplace(p, " e ", "|"); StringReplace(p, " + ", "|"); StringReplace(p, ",", "|"); StringReplace(p, ".", "|");
    string segments[]; int n = StringSplit(p, '|', segments);

    p_riskPercent = ExtractNumber(p, "risco de "); if(p_riskPercent == 0) p_riskPercent = 1.0;
    p_stopPoints = (int)ExtractNumber(p, "stop de ");
    p_takePoints = (int)ExtractNumber(p, "take de ");
    p_maxTrades = (int)ExtractNumber(p, "máximo "); if(p_maxTrades == 0) p_maxTrades = 1;
    p_martingale = (StringFind(p, "martingale") >= 0);
    p_hedge = (StringFind(p, "hedge") >= 0);
    p_newsVetoMinutes = (int)ExtractNumber(p, "não operar "); if(p_newsVetoMinutes == 0) p_newsVetoMinutes = (int)ExtractNumber(p, "notícias de ");
    p_startTimeStr = ExtractTime(p);
    if(p_startTimeStr != "") {
        string parts[]; if(StringSplit(p_startTimeStr, ':', parts) >= 2) p_startTimeSeconds = (int)StringToInteger(parts[0]) * 3600 + (int)StringToInteger(parts[1]) * 60;
    }
    p_frequency = (ENUM_TIMEFRAMES)PeriodoTexto(p);

    Signal currentIntent = NONE;
    for(int i=0; i<n; i++) {
        string s = segments[i]; StringTrimLeft(s); StringTrimRight(s); if(s == "") continue;
        if(StringFind(s, "compra") >= 0) currentIntent = BUY;
        else if(StringFind(s, "vende") >= 0) currentIntent = SELL;

        if(StringFind(s, "atingir +") >= 0) {
            double val = ExtractNumber(s, "atingir +");
            if(StringFind(s, "move stop") >= 0) { p_breakEvenPoints = (int)val; p_breakEvenOffset = (int)ExtractNumber(s, "entrada +"); }
            else p_trailingStopPoints = (int)val;
        }

        if(StringFind(s, "média") >= 0) {
            int p1 = (int)ExtractNumber(s, "média de "); if(p1 == 0) p1 = (int)ExtractNumber(s, "média "); if(p1 == 0) p1 = 20;
            AddRule(RULE_MA_CROSS, PERIOD_CURRENT, p1, 0, 0, 0, currentIntent, (StringFind(s, "cruzar") >= 0));
        }
        if(StringFind(s, "rsi") >= 0) {
            int per = (int)ExtractNumber(s, "rsi ("); if(per == 0) per = (int)ExtractNumber(s, "rsi "); if(per == 0) per = 14;
            double thr = ExtractNumber(s, "acima de "); if(thr == 0) thr = ExtractNumber(s, "abaixo de ");
            AddRule(RULE_RSI, PERIOD_CURRENT, per, 0, thr, 0, currentIntent, (StringFind(s, "subir") >= 0 || StringFind(s, "cair") >= 0 || StringFind(s, "cruzar") >= 0));
        }
        if(StringFind(s, "estocástico") >= 0 || StringFind(s, "stoch") >= 0) {
            AddRule(RULE_STOCH, PERIOD_CURRENT, 5, 3, 80, 20, currentIntent, (StringFind(s, "cruzar") >= 0));
        }
        if(StringFind(s, "bollinger") >= 0 || StringFind(s, "bb") >= 0) {
            AddRule(RULE_BB, PERIOD_CURRENT, 20, 2, 0, 0, currentIntent, false);
        }
    }
}

void AddRule(RuleType type, int tf, int p1, int p2, double d1, double d2, Signal intent, bool is_cross) {
    if(nRules >= MAX_RULES || intent == NONE) return;
    for(int i=0; i<nRules; i++) if(rules[i].type == type && rules[i].intent == intent) { rules[i].p1 = p1; rules[i].d1 = d1; return; }
    rules[nRules].active = true; rules[nRules].type = type; rules[nRules].tf = tf; rules[nRules].p1 = p1; rules[nRules].p2 = p2; rules[nRules].d1 = d1; rules[nRules].d2 = d2; rules[nRules].intent = intent; rules[nRules].is_cross = is_cross;
    rules[nRules].p1_handle = (type == RULE_MA_CROSS) ? iMA(_Symbol, (ENUM_TIMEFRAMES)tf, p1, 0, MODE_SMA, PRICE_CLOSE) :
                              (type == RULE_RSI) ? iRSI(_Symbol, (ENUM_TIMEFRAMES)tf, p1, PRICE_CLOSE) :
                              (type == RULE_STOCH) ? iStochastic(_Symbol, (ENUM_TIMEFRAMES)tf, p1, p2, 3, MODE_SMA, STO_LOWHIGH) :
                              (type == RULE_BB) ? iBands(_Symbol, (ENUM_TIMEFRAMES)tf, p1, 0, (double)p2, PRICE_CLOSE) : INVALID_HANDLE;
    nRules++;
}

double ExtractNumber(string txt, string keyword) {
    int pos = StringFind(txt, keyword); if(pos < 0) return 0;
    string sub = StringSubstr(txt, pos + StringLen(keyword)), res = ""; bool found = false;
    for(int i=0; i<StringLen(sub); i++) { ushort c = StringGetCharacter(sub, i); if((c >= '0' && c <= '9') || c == '.') { res += CharToString((char)c); found = true; } else if(found) break; }
    return StringToDouble(res);
}

string ExtractTime(string txt) {
    int pos = StringFind(txt, "depois das "); if(pos < 0) return "";
    string sub = StringSubstr(txt, pos + 11), res = "";
    for(int i=0; i<StringLen(sub); i++) { ushort c = StringGetCharacter(sub, i); if((c >= '0' && c <= '9') || c == ':' || c == 'h') { if(c == 'h') res += ":00"; else res += CharToString((char)c); } else if(res != "") break; }
    if(StringFind(res, ":") < 0 && res != "") res += ":00"; return res;
}

int PeriodoTexto(string nome) {
    if(StringFind(nome, "m30") >= 0 || StringFind(nome, "30 min") >= 0) return PERIOD_M30;
    if(StringFind(nome, "m15") >= 0 || StringFind(nome, "15 min") >= 0) return PERIOD_M15;
    if(StringFind(nome, "m5") >= 0 || StringFind(nome, "5 min") >= 0) return PERIOD_M5;
    if(StringFind(nome, "h1") >= 0 || StringFind(nome, "1 hora") >= 0) return PERIOD_H1;
    return PERIOD_CURRENT;
}

// ---------- 3. INDICATOR CORE & SIGNAL EVALUATION ----------

Signal CheckMA(Rule &rule) {
    if(rule.p1_handle == INVALID_HANDLE) return NONE;
    double ma[2], pr[2]; if(CopyBuffer(rule.p1_handle, 0, 0, 2, ma) < 2 || CopyClose(_Symbol, (ENUM_TIMEFRAMES)rule.tf, 0, 2, pr) < 2) return NONE;
    if(rule.is_cross) { if(pr[0] < ma[0] && pr[1] > ma[1]) return (rule.intent == BUY ? BUY : NONE); if(pr[0] > ma[0] && pr[1] < ma[1]) return (rule.intent == SELL ? SELL : NONE); }
    else { if(pr[1] > ma[1]) return (rule.intent == BUY ? BUY : NONE); if(pr[1] < ma[1]) return (rule.intent == SELL ? SELL : NONE); }
    return NONE;
}

Signal CheckRSI(Rule &rule) {
    if(rule.p1_handle == INVALID_HANDLE) return NONE;
    double rsi[2]; if(CopyBuffer(rule.p1_handle, 0, 0, 2, rsi) < 2) return NONE;
    if(rule.is_cross) { if(rsi[0] < rule.d1 && rsi[1] > rule.d1) return (rule.intent == BUY ? BUY : NONE); if(rsi[0] > rule.d1 && rsi[1] < rule.d1) return (rule.intent == SELL ? SELL : NONE); }
    else { if(rule.intent == BUY && rsi[1] > rule.d1) return BUY; if(rule.intent == SELL && rsi[1] < rule.d1) return SELL; }
    return NONE;
}

Signal CheckStoch(Rule &rule) {
    if(rule.p1_handle == INVALID_HANDLE) return NONE;
    double k[2], d[2]; if(CopyBuffer(rule.p1_handle, 0, 0, 2, k) < 2 || CopyBuffer(rule.p1_handle, 1, 0, 2, d) < 2) return NONE;
    if(k[0] < d[0] && k[1] > d[1]) return BUY; if(k[0] > d[0] && k[1] < d[1]) return SELL;
    return NONE;
}

Signal CheckBB(Rule &rule) {
    if(rule.p1_handle == INVALID_HANDLE) return NONE;
    double up[1], lo[1], pr[1]; if(CopyBuffer(rule.p1_handle, 1, 1, 1, up) < 1 || CopyBuffer(rule.p1_handle, 2, 1, 1, lo) < 1 || CopyClose(_Symbol, (ENUM_TIMEFRAMES)rule.tf, 1, 1, pr) < 1) return NONE;
    if(pr[0] < lo[0]) return BUY; if(pr[0] > up[0]) return SELL;
    return NONE;
}

Signal AvaliaTudo() {
    int buyL = 0, buyR = 0, sellL = 0, sellR = 0;
    for(int i=0; i<nRules; i++) {
        Signal res = NONE;
        if(rules[i].type == RULE_MA_CROSS) res = CheckMA(rules[i]);
        else if(rules[i].type == RULE_RSI) res = CheckRSI(rules[i]);
        else if(rules[i].type == RULE_STOCH) res = CheckStoch(rules[i]);
        else if(rules[i].type == RULE_BB) res = CheckBB(rules[i]);
        if(rules[i].intent == BUY) { buyR++; if(res == BUY) buyL++; }
        else if(rules[i].intent == SELL) { sellR++; if(res == SELL) sellL++; }
    }
    if(buyR > 0 && buyL == buyR) return BUY; if(sellR > 0 && sellL == sellR) return SELL; return NONE;
}

// ---------- 4. TRADE EXECUTION & RISK ----------

double CalculaLote(double riscoPercent) {
    double equity = AccountInfoDouble(ACCOUNT_EQUITY);
    double riskAbs = equity * riscoPercent / 100.0;
    double tickV = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), tickS = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    int slP = (p_stopPoints > 0) ? p_stopPoints : 300;
    double volume = riskAbs / (slP * (tickV / (tickS / _Point)));
    if(p_martingale && HistorySelect(TimeCurrent() - 86400, TimeCurrent())) {
        for(int i=HistoryDealsTotal()-1; i>=0; i--) {
            ulong t = HistoryDealGetTicket(i);
            if(HistoryDealGetString(t, DEAL_SYMBOL) == _Symbol && HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
                if(HistoryDealGetDouble(t, DEAL_PROFIT) < 0) volume *= 2.0; break;
            }
        }
    }
    double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), maxL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    return MathMax(minL, MathMin(maxL, NormalizeDouble(volume / step, 0) * step));
}

void EnviaOrdem(Signal s, double volume) {
    if(s == NONE || volume <= 0) return;
    int safetyB = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + dynamicSafetyPoints + 1;
    double sl = 0, tp = 0, bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    if(!p_hedge) {
        for(int i=PositionsTotal()-1; i>=0; i--) {
            if(m_pos.SelectByIndex(i) && m_pos.Symbol() == _Symbol && m_pos.Magic() == EA_MAGIC) {
                if((s == BUY && m_pos.PositionType() == POSITION_TYPE_SELL) || (s == SELL && m_pos.PositionType() == POSITION_TYPE_BUY)) trade.PositionClose(m_pos.Ticket());
            }
        }
    }
    trade.SetExpertMagicNumber(EA_MAGIC);
    bool res = (s == BUY) ? trade.Buy(volume, _Symbol, ask, (p_stopPoints > 0 ? bid - MathMax(p_stopPoints, safetyB) * _Point : 0), (p_takePoints > 0 ? ask + p_takePoints * _Point : 0)) :
               trade.Sell(volume, _Symbol, bid, (p_stopPoints > 0 ? ask + MathMax(p_stopPoints, safetyB) * _Point : 0), (p_takePoints > 0 ? bid - p_takePoints * _Point : 0));
    if(!res) { if(trade.ResultRetcode() == TRADE_RETCODE_REJECT) dynamicSafetyPoints = MathMin(100, dynamicSafetyPoints + 5); }
    else { SendNotification("Trade Executed: " + (s == BUY ? "BUY " : "SELL ") + DoubleToString(volume, 2) + " " + _Symbol); AIOptimizer(); }
}

// ---------- 5. POSITION MANAGEMENT ----------

void GerenciaPosicoes() {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(m_pos.SelectByIndex(i) && m_pos.Symbol() == _Symbol && m_pos.Magic() == EA_MAGIC) {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID), ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK), openP = m_pos.PriceOpen(), currSL = m_pos.StopLoss();
            double profitP = (m_pos.PositionType() == POSITION_TYPE_BUY) ? (bid - openP) / _Point : (openP - ask) / _Point;
            if(p_breakEvenPoints > 0 && profitP >= p_breakEvenPoints) {
                double targetSL = (m_pos.PositionType() == POSITION_TYPE_BUY) ? openP + p_breakEvenOffset * _Point : openP - p_breakEvenOffset * _Point;
                if((m_pos.PositionType() == POSITION_TYPE_BUY && (currSL < targetSL || currSL == 0)) || (m_pos.PositionType() == POSITION_TYPE_SELL && (currSL > targetSL || currSL == 0))) { trade.PositionModify(m_pos.Ticket(), targetSL, m_pos.TakeProfit()); continue; }
            }
            if(p_trailingStopPoints > 0 && profitP >= p_trailingStopPoints) {
                double targetSL = (m_pos.PositionType() == POSITION_TYPE_BUY) ? bid - p_trailingStopPoints * _Point : ask + p_trailingStopPoints * _Point;
                if((m_pos.PositionType() == POSITION_TYPE_BUY && targetSL > currSL) || (m_pos.PositionType() == POSITION_TYPE_SELL && (targetSL < currSL || currSL == 0))) trade.PositionModify(m_pos.Ticket(), targetSL, m_pos.TakeProfit());
            }
        }
    }
}

// ---------- 6. INFRASTRUCTURE & LIFECYCLE ----------

int OnInit() { EventSetTimer(1); InterpretaPrompt("A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."); return INIT_SUCCEEDED; }
void OnDeinit(const int reason) { EventKillTimer(); ResetStrategy(); }
void OnTick() {
    GerenciaPosicoes(); if(TimeCurrent() - lastCSVWrite > 5) { GravaCSV(); lastCSVWrite = TimeCurrent(); }
    if(TimeCurrent() - lastSafetyDecay > 60) { if(dynamicSafetyPoints > 0) dynamicSafetyPoints--; lastSafetyDecay = TimeCurrent(); }
    if(AguardaNoticias()) return;
    datetime curB = iTime(_Symbol, p_frequency, 0);
    if(curB != lastBarTime) {
        lastBarTime = curB; MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
        if(dt.hour * 3600 + dt.min * 60 < p_startTimeSeconds) return;
        int activeT = 0; for(int i=PositionsTotal()-1; i>=0; i--) if(m_pos.SelectByIndex(i) && m_pos.Symbol() == _Symbol && m_pos.Magic() == EA_MAGIC) activeT++;
        if(activeT < p_maxTrades) { Signal s = AvaliaTudo(); if(s != NONE) EnviaOrdem(s, CalculaLote(p_riskPercent)); }
    }
}
void OnTimer() {
    if(GlobalVariableCheck("MT_Executor_Prompt_Update")) {
        int h = FileOpen("MT_LiveExecutor_Prompt.txt", FILE_READ | FILE_TXT | FILE_COMMON);
        if(h != INVALID_HANDLE) { string p = FileReadString(h); FileClose(h); InterpretaPrompt(p); GlobalVariableDel("MT_Executor_Prompt_Update"); }
    }
}
bool AguardaNoticias() {
    int h = FileOpen("news_veto.txt", FILE_READ | FILE_TXT | FILE_COMMON);
    if(h != INVALID_HANDLE) { string val = FileReadString(h); FileClose(h); if(val == "1") return true; }
    return false;
}
void GravaCSV() {
    int h = FileOpen("MT_LiveExecutor_State.csv", FILE_WRITE | FILE_CSV | FILE_COMMON);
    if(h != INVALID_HANDLE) {
        FileWrite(h, "Ticket", "Symbol", "Type", "Price", "SL", "TP", "Time");
        for(int i=0; i<PositionsTotal(); i++) if(m_pos.SelectByIndex(i) && m_pos.Magic() == EA_MAGIC) FileWrite(h, m_pos.Ticket(), m_pos.Symbol(), m_pos.PositionType(), m_pos.PriceOpen(), m_pos.StopLoss(), m_pos.TakeProfit(), m_pos.Time());
        FileClose(h);
    }
}
void AIOptimizer() {
    if(!HistorySelect(0, TimeCurrent())) return;
    int trades = 0, wins = 0; double profit = 0, loss = 0;
    for(int i=0; i<HistoryDealsTotal(); i++) {
        ulong t = HistoryDealGetTicket(i); if(HistoryDealGetInteger(t, DEAL_MAGIC) == EA_MAGIC) {
            double p = HistoryDealGetDouble(t, DEAL_PROFIT); if(p > 0) { profit += p; wins++; } else if(p < 0) loss += MathAbs(p); trades++;
        }
    }
    double winRate = (trades > 0) ? (double)wins / trades : 0;
    double pf = (loss > 0) ? profit / loss : profit;
    PrintFormat("AI Optimizer: Trades=%d WinRate=%.2f PF=%.2f", trades, winRate, pf);
    if(trades > 10 && winRate < 0.4) SendNotification("Alert: Low WinRate detected (" + DoubleToString(winRate, 2) + ")");
}
