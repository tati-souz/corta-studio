import SwiftUI

/// Painel da voz de estúdio: predefinições, ajustes finos e comparação antes/depois.
struct VoiceStudioPanel: View {
    @ObservedObject var studio: Studio
    @State private var showDetails = false
    private let accent = Color(red: 0.83, green: 0.66, blue: 0.29)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $studio.settings.studioVoice) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Voz de estúdio")
                    Text("Tira barulho de fundo, eco, chiado e zumbido; deixa a voz clara e no volume certo").font(.caption2).foregroundStyle(.secondary)
                }
            }
            if studio.settings.studioVoice {
                Picker("Estilo", selection: Binding(get: { studio.settings.voicePreset }, set: { studio.settings.applyVoicePreset($0) })) {
                    ForEach(VoiceParams.presets, id: \.id) { Text($0.name).tag($0.id) }
                    if !VoiceParams.presets.contains(where: { $0.id == studio.settings.voicePreset }) { Text("Personalizado").tag(studio.settings.voicePreset) }
                }
                Text(VoiceParams.presets.first { $0.id == studio.settings.voicePreset }?.help ?? "Ajustes feitos à mão.").font(.caption2).foregroundStyle(.secondary)
                slider("Volume final", "Mais alto e claro se a gravação ficou baixa (sem estourar)", \.voiceLevel)
                slider("Barulho de fundo", "Ventilador, rua, ar-condicionado, pessoas ao fundo", \.voiceIsolation)
                DisclosureGroup(isExpanded: $showDetails) {
                    VStack(alignment: .leading, spacing: 6) {
                        slider("Eco da sala", "Reverberação de sala vazia ou paredes lisas", \.voiceEcho)
                        slider("Chiado", "Ruído agudo constante (microfone, gravador)", \.voiceHiss)
                        Toggle("Tirar zumbido elétrico (60 Hz)", isOn: custom(\.voiceHum)).font(.caption)
                        slider("Clareza", "Presença e definição das palavras", \.voiceClarity)
                        slider("Corpo", "Graves e calor da voz", \.voiceWarmth)
                        slider("Igualar volume", "Aproxima as falas baixas das altas", \.voiceLeveling)
                    }.padding(.top, 4)
                } label: { Text("Ajustes finos").font(.caption.weight(.semibold)) }
                HStack {
                    Text("Volume na mixagem").font(.caption)
                    Slider(value: $studio.settings.voiceVolume, in: 0...2)
                    Text("\(Int(studio.settings.voiceVolume * 100))%").font(.caption2.monospacedDigit()).frame(width: 38, alignment: .trailing)
                }
                if !studio.liveStatus.isEmpty { Text(studio.liveStatus).font(.caption2).foregroundStyle(accent) }
                Button { studio.applyVoiceToWholeVideo() } label: {
                    Label(studio.wholeVoiceReady ? "Áudio do vídeo todo tratado ✓" : "Aplicar no áudio do vídeo todo", systemImage: "waveform.badge.checkmark").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).disabled(studio.source == nil || studio.busy || studio.wholeVoiceReady)
                .help("Trata a gravação inteira de uma vez com estes ajustes; depois todos os cortes e exportações usam esse áudio, sem esperar")
                Text("Sem isso, o app trata só os trechos da edição aberta (mais rápido). Para comparar, desligue e ligue “Voz de estúdio” ouvindo o mesmo trecho.").font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Qualquer ajuste à mão vira "Personalizado".
    private func custom<T>(_ path: WritableKeyPath<EditSettings, T>) -> Binding<T> {
        Binding(get: { studio.settings[keyPath: path] }, set: { studio.settings[keyPath: path] = $0; studio.settings.voicePreset = "personalizado" })
    }
    private func slider(_ title: String, _ help: String, _ path: WritableKeyPath<EditSettings, Double>) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 104, alignment: .leading)
            Slider(value: custom(path), in: 0...1)
            Text("\(Int(studio.settings[keyPath: path] * 100))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
        }.help(help)
    }
}

extension Studio {
    var wholeVoiceReady: Bool { source.map { VoiceStudio.wholeVideo($0, params: settings.voiceParams, directory: Studio.cacheDirectory) != nil } ?? false }
    /// Trata o áudio da gravação inteira com os ajustes atuais (num vídeo longo leva alguns minutos; pode cancelar).
    func applyVoiceToWholeVideo() {
        guard let source else { return }
        let params = settings.voiceParams
        operation("Voz de estúdio no vídeo todo…") {
            _ = try await VoiceStudio.process(video: source, params: params, ranges: nil, directory: Studio.cacheDirectory) { text in Task { @MainActor in self.message = text + " (vídeo todo)" } }
            self.voiceKey = ""; self.scheduleLive(delay: 0)
            self.message = "Voz de estúdio aplicada ao áudio do vídeo todo. Cortes e exportações já usam esse áudio."
        }
    }
}
