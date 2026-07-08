import re

class MockMT:
    def __init__(self):
        self.g_rulesBuy = []
        self.g_rulesSell = []
        self.g_risk = 1.0
        self.g_slPoints = 0
        self.g_tpPoints = 0
        self.g_maxTrades = 3
        self.g_startHour = 10
        self.g_frequency = "PERIOD_M15"
        self.g_breakevenTrigger = 0
        self.g_breakevenOffset = 0
        self.g_trailingStop = 0

    def extrai_numero(self, txt, start_pos):
        if start_pos < 0: return 0.0
        res = ""
        found = False
        for i in range(start_pos, len(txt)):
            c = txt[i]
            if c.isdigit() or c in '.-+':
                res += c
                found = True
            elif found:
                break
        try:
            return float(res)
        except:
            return 0.0

    def interpreta_prompt(self, prompt):
        work = prompt.lower()
        work = work.replace(" e o ", ".").replace(" e a ", ".").replace(" e ", ".")

        if "risco de " in work: self.g_risk = self.extrai_numero(work, work.find("risco de "))
        if "stop de " in work: self.g_slPoints = int(self.extrai_numero(work, work.find("stop de ")))
        if "take de " in work: self.g_tpPoints = int(self.extrai_numero(work, work.find("take de ")))
        if "máximo " in work and " trades" in work: self.g_maxTrades = int(self.extrai_numero(work, work.find("máximo ")))
        if "depois das " in work: self.g_startHour = int(self.extrai_numero(work, work.find("depois das ")))

        be_pos = work.find("ao atingir ")
        if be_pos >= 0:
            self.g_breakevenTrigger = int(self.extrai_numero(work, be_pos))
            ent_pos = work.find("entrada", be_pos)
            if ent_pos >= 0: self.g_breakevenOffset = int(self.extrai_numero(work, ent_pos))

        t_pos = work.find("trailing")
        if t_pos < 0: t_pos = work.find("rastreio")
        if t_pos >= 0: self.g_trailingStop = int(self.extrai_numero(work, t_pos))

        segments = work.split('.')
        current_intent = None
        for seg in segments:
            if "compra" in seg: current_intent = "BUY"
            elif "vende" in seg: current_intent = "SELL"

            if current_intent:
                self.add_rule(seg, current_intent)

    def add_rule(self, seg, intent):
        rule = {"intent": intent, "type": None}
        if "média" in seg:
            rule["type"] = "MA"
            rule["p1"] = int(self.extrai_numero(seg, seg.find("média")))
            if "cruzar acima" in seg: rule["op"] = "cross_above"
            elif "cruzar abaixo" in seg: rule["op"] = "cross_below"
        if "rsi" in seg:
            rule["type"] = "RSI"
            rule["p1"] = int(self.extrai_numero(seg, seg.find("rsi")))
            if "acima" in seg:
                rule["op"] = ">"
                rule["d1"] = self.extrai_numero(seg, seg.find("acima"))
            elif "abaixo" in seg:
                rule["op"] = "<"
                rule["d1"] = self.extrai_numero(seg, seg.find("abaixo"))

        if rule["type"]:
            if intent == "BUY": self.g_rulesBuy.append(rule)
            else: self.g_rulesSell.append(rule)

if __name__ == "__main__":
    prompt = "A cada 15 minutos, depois das 10h, compra se o preço cruzar acima da média de 20 períodos e o RSI (14) subir acima de 55. Vende se cruzar abaixo da média e RSI cair abaixo de 45. Stop de 30 pontos, take de 50 pontos. Risco de 1 % do capital por trade. Não operar 20 min antes ou depois de notícias de alto impacto. Máximo 3 trades simultâneos. Ao atingir +30 pontos, move stop para entrada +5 pontos."
    mock = MockMT()
    mock.interpreta_prompt(prompt)

    print(f"Risk: {mock.g_risk}")
    print(f"SL: {mock.g_slPoints}, TP: {mock.g_tpPoints}")
    print(f"Max Trades: {mock.g_maxTrades}")
    print(f"Start Hour: {mock.g_startHour}")
    print(f"BE Trigger: {mock.g_breakevenTrigger}, Offset: {mock.g_breakevenOffset}")
    print(f"BUY Rules: {mock.g_rulesBuy}")
    print(f"SELL Rules: {mock.g_rulesSell}")

    assert mock.g_risk == 1.0
    assert mock.g_slPoints == 30
    assert mock.g_tpPoints == 50
    assert mock.g_maxTrades == 3
    assert mock.g_startHour == 10
    assert mock.g_breakevenTrigger == 30
    assert mock.g_breakevenOffset == 5
    assert len(mock.g_rulesBuy) >= 2
    assert len(mock.g_rulesSell) >= 2
    print("Parsing Logic Test Passed!")
