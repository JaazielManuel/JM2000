import re

class MockMTLiveExecutor:
    def __init__(self):
        self.p_risk = 1.0
        self.p_sl = 0
        self.p_tp = 0
        self.p_maxTrades = 3
        self.p_breakeven = 0
        self.p_beStep = 0
        self.p_trailingStop = 0
        self.p_trailingStep = 0
        self.p_newsVeto = 20
        self.p_startHour = -1
        self.p_frequency = "PERIOD_M15"
        self.rules = []

    def extrai_numero(self, txt, start):
        if start < 0 or start >= len(txt): return 0
        res = ""
        found = False
        for i in range(start, len(txt)):
            c = txt[i]
            if c.isdigit() or c == '.' or c == ',':
                if c == ',': res += "."
                else: res += c
                found = True
            elif found: break
        return float(res) if res else 0

    def periodo_texto(self, nome):
        if "m15" in nome or "15 min" in nome: return "PERIOD_M15"
        if "m1" in nome or "1 min" in nome: return "PERIOD_M1"
        if "m5" in nome or "5 min" in nome: return "PERIOD_M5"
        if "h1" in nome or "1 hora" in nome: return "PERIOD_H1"
        return "PERIOD_CURRENT"

    def interpreta_prompt(self, prompt):
        lower_prompt = prompt.lower()
        lower_prompt = lower_prompt.replace("|", ".").replace("\n", ".")
        segments = [s.strip() for s in lower_prompt.split('.') if s.strip()]

        current_intent = 0
        for seg in segments:
            if "risco" in seg: self.p_risk = self.extrai_numero(seg, seg.find("risco") + 5)
            if "stop" in seg and "move" not in seg: self.p_sl = self.extrai_numero(seg, seg.find("stop") + 4)
            if "take" in seg: self.p_tp = self.extrai_numero(seg, seg.find("take") + 4)

            if "breakeven" in seg or "move stop para entrada" in seg:
                pos_atingir = seg.find("atingir")
                if pos_atingir >= 0:
                    self.p_breakeven = self.extrai_numero(seg, pos_atingir + 7)
                pos_plus = seg.find("+", pos_atingir + 10 if pos_atingir >= 0 else 0)
                if pos_plus >= 0:
                    self.p_beStep = self.extrai_numero(seg, pos_plus + 1)

            if "trailing" in seg or "rastreio" in seg:
                self.p_trailingStop = self.extrai_numero(seg, seg.find("stop") + 4)
                self.p_trailingStep = self.extrai_numero(seg, seg.find("passo") + 5)

            if "depois das" in seg or "após as" in seg:
                self.p_startHour = int(self.extrai_numero(seg, seg.find("as") + 2))

            if "cada" in seg and ("minutos" in seg or "min" in seg):
                self.p_frequency = self.periodo_texto(seg)

            if "compra" in seg: current_intent = 1
            elif "venda" in seg: current_intent = -1

            if current_intent != 0:
                self.add_rule(seg, current_intent)

    def add_rule(self, txt, intent):
        tf = self.periodo_texto(txt)
        if "média" in txt or "cruzar" in txt:
            rule = {"intent": intent, "tf": tf, "type": "MA"}
            rule["p1"] = self.extrai_numero(txt, txt.find("média") + 5)
            self.rules.append(rule)
        if "rsi" in txt:
            rule = {"intent": intent, "tf": tf, "type": "RSI"}
            rule["p1"] = self.extrai_numero(txt, txt.find("rsi") + 3)
            pos_threshold = txt.find("acima") + 5 if "acima" in txt else txt.find("abaixo") + 6
            rule["d1"] = self.extrai_numero(txt, pos_threshold)
            self.rules.append(rule)

def test():
    executor = MockMTLiveExecutor()
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Ao atingir +30 pontos, move stop para entrada +5 pontos."
    executor.interpreta_prompt(prompt)

    print(f"Risk: {executor.p_risk}")
    print(f"SL: {executor.p_sl}")
    print(f"TP: {executor.p_tp}")
    print(f"Start Hour: {executor.p_startHour}")
    print(f"Frequency: {executor.p_frequency}")
    print(f"Breakeven: {executor.p_breakeven}")
    print(f"BE Step: {executor.p_beStep}")
    print(f"Rules count: {len(executor.rules)}")
    for r in executor.rules:
        print(f"Rule: {r}")

if __name__ == "__main__":
    test()
