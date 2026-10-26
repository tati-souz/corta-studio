# Corta Studio — Projeto Ethos (versão 0.16.0)

Editor de vídeo para Mac (Apple Silicon). Você marca o que quer, clica em **Editar com IA** e o Claude monta a edição. Depois você refina conversando no **chat**, salva o projeto e exporta. A IA usa a **sua assinatura Claude** (não há cobrança por API).

## Modelos de Reels/Shorts (aba Reels)

Os modelos ficam no alto da aba **Reels**, numa galeria com prévia desenhada de cada um. Clique num modelo, ajuste as opções e use **Aplicar modelo**. O modelo cria uma **versão nova**, que aparece na aba Cortes como "Reels · nome do modelo", e a edição original continua guardada. O formato é vertical 9:16, exportado em 1080 × 1920. Tudo o que o modelo coloca fica na linha do tempo para ajustar à mão, e ⌘Z desfaz.

| Modelo | Como fica | O que o app faz | Sem IA conectada |
|---|---|---|---|
| **1. Fala dinâmica** | Você em tela cheia, cortes ágeis, palavras destacadas | Tira pausas (leve, normal ou forte), põe zooms pontuais alternando aproximação rápida e suave (intensidade e frequência ajustáveis), enquadra o rosto e põe legenda palavra a palavra (Hormozi, Contorno, Caixa…) | Funciona inteiro |
| **2. Fala + imagens de apoio** | Imagens ou vídeos em alguns momentos, com a voz contínua | A IA escolhe os momentos e busca ou escolhe a mídia; cada uma pode ser trocada | Você escolhe os arquivos, que entram na ordem, espalhados pelo vídeo |
| **3. Apresentador recortado** | Você sem o fundo, sobre notícia, imagem, gráfico ou vídeo | Recorta você (no próprio Mac), com tamanho e posição ajustáveis, e cobre o vídeo inteiro com o conteúdo de fundo | Você escolhe o fundo (uma imagem ou vídeo, ou vários em sequência) |
| **4. Vídeo com janelinha** | Demonstração ou gravação de tela no fundo; você numa janela | Janela redonda ou retangular, com posição, tamanho e borda dourada opcional. Os zooms aproximam a demonstração | Você escolhe a gravação de tela ou o vídeo |
| **5. Pergunta na tela + resposta** | Cartão com a pergunta abre o vídeo; depois, a resposta | Cartão editável (texto, animação, posição, duração), com legendas durante a resposta | Você escreve a pergunta (a IA só sugere) |
| **6. Lista com revelação progressiva** | "3 erros", "5 sinais": cada item aparece quando é dito | A IA encontra a lista na fala; os itens anteriores ficam na tela mais apagados e o atual em destaque, com contador opcional ("2 de 5") | Pare o vídeo onde cada item começa e clique em **Adicionar item aqui** |
| **7. Narração + texto animado** | A voz conduz; frases e imagens ocupam a tela, sem rosto | Imagens em sequência cobrindo o vídeo, legenda grande e cartões com frases-chave | Você escolhe as imagens |

**Narração só em áudio:** em **Trocar vídeo**, escolha um arquivo de áudio (m4a, mp3, wav). O app o transforma num vídeo vertical escuro, salvo em `Biblioteca/Narracoes`, pronto para o modelo 7. Ainda não há gravação de voz dentro do app: grave antes no Gravador ou no QuickTime.

**Ajustes de qualquer modelo** (aba Reels):
- **Formato**: fonte, cor e tamanho da legenda, além de estilo, animação e posição;
- **Transições e volumes**: a transição entre trechos (ou uma por junção, no losango dourado da linha do tempo), o volume da voz e o da música;
- **Zonas do Instagram/TikTok na prévia**: mostra onde ficam os botões e o texto do post, para nada importante ficar coberto;
- **Cada peça**: clique na linha do tempo ou na própria prévia para editar o texto, a duração, a animação, a intensidade do zoom e, na janelinha ou no recorte, a posição, o tamanho e a borda;
- **Legendas**: corrija na aba Legendas ou clicando nelas na prévia.

## Pastas

- O aplicativo fica instalado em **Aplicativos** (`/Applications/Corta Studio.app`). Abra pelo Spotlight (⌘ Espaço, digite "Corta"), pelo Launchpad ou pelo Dock. O título da janela mostra **"PROJETO ETHOS · EDIÇÃO COM IA"**; em **Ajuda › Sobre esta versão** aparece **0.13.1**.
- Existe **uma única cópia** do app, em Aplicativos. O `build.sh` compila numa pasta temporária e substitui a cópia de Aplicativos.
- `Biblioteca/`: seus materiais. A pasta é criada no primeiro uso.
  - `Imagens/`: fotos, pinturas e ilustrações que a IA pode usar como imagens de apoio. **Use nomes descritivos** (ex.: `santo-agostinho-pintura.jpg`), porque a IA escolhe pelo nome.
  - `Musicas/`: trilhas com licença de uso (ex.: Biblioteca de Áudio do YouTube).
  - `Marca/logo.png`: logo com fundo transparente, para a marca d'água.
  - `fontes.txt`: anote aqui a origem e a licença de cada arquivo. O registro vai junto em cada exportação que usar esses materiais.
- `codigo-fonte/`: código Swift e `build.sh`.

## Primeira configuração (uma vez só)

1. Abra o app e clique em **IA e conta** › **Entrar com Claude**. O Terminal abre e, em seguida, o login oficial no navegador.
2. Escolha o modelo. **Sonnet** é o padrão recomendado. **Opus** é mais cuidadoso e gasta o limite mais rápido. **Haiku** é o mais econômico.

## Como editar

1. **Escolher vídeo** (horizontal ou vertical). O original nunca é alterado.
2. No painel da esquerda, marque o que quer:
   - **Destino e objetivo**: YouTube, Shorts, Reels ou TikTok. Ao trocar a plataforma, o app aplica ajustes recomendados (formato, estilo de legenda, enquadramento). Escolha também vídeo completo ou corte curto (com a duração) e o ritmo.
   - **O que a IA decide**: cortes inteligentes, redução de pausas, zooms de ênfase, textos de destaque, imagens da biblioteca e gancho na abertura.
   - **Legendas**: dinâmica (palavra a palavra, com a palavra falada em destaque) ou em blocos. Estilos: Ethos (serifada, creme e dourado), Contorno (estilo Reels/TikTok), Clássica e Destaque. Posição inferior ou central.
   - **Imagem**: zoom progressivo, enquadramento que acompanha o rosto (para converter horizontal em vertical) ou vídeo inteiro com fundo desfocado. Também: cor (Natural, Ethos clássico, Cinema, Preto e branco, Vívido suave), transições em fade nas mudanças de assunto, vinheta, fade de abertura e fim, barra de progresso e marca d'água.
   - **Áudio**: música da biblioteca com abaixamento automático durante a fala, e efeitos sonoros sutis (sons discretos sintetizados em zooms, imagens e textos).
   - **Voz de estúdio** (painel Áudio, à esquerda):
     - **Estilos prontos**:
       - Estúdio (equilíbrio);
       - Natural (tratamento leve);
       - Podcast (voz próxima, encorpada e alta);
       - Sala com eco;
       - Gravação baixa (sobe volume e clareza sem estourar).
     - **Volume final**: deixa mais alto e claro o que ficou baixo na gravação.
     - **Barulho de fundo**: isolamento de voz da Apple contra ventilador, rua, ar-condicionado e pessoas ao fundo.
     - **Ajustes finos**:
       - **Eco da sala**;
       - **Chiado** (ruído agudo);
       - **Zumbido elétrico** (60 Hz);
       - **Clareza** (presença das palavras);
       - **Corpo** (graves);
       - **Igualar volume** (aproxima falas baixas e altas).
       - Qualquer ajuste à mão vira "Personalizado".
     - **O que é tratado:**
       - Normalmente, só os trechos da edição aberta: num corte de 30 s, leva cerca de 1 segundo.
       - **Aplicar no áudio do vídeo todo** trata a gravação inteira de uma vez (num vídeo longo leva alguns minutos). Depois, todos os cortes e exportações usam esse áudio pronto.
     - **Para comparar antes e depois**: desligue e ligue "Voz de estúdio" ouvindo o mesmo trecho.
     - No chat também funciona: "deixe a voz mais alta e tire o eco", "use o estilo podcast".
     - Limite: eco muito forte e barulho alto na mesma hora da fala diminuem bastante, mas não somem por completo.
   - **Remover vícios**: "hum", "hã" e "ééé" saem automaticamente. "Tipo", "né" e "então assim" saem quando a IA julga que são muleta. O que foi removido aparece riscado na aba Legendas, com o botão Restaurar.
   - **Desfocar fundo (modo retrato)**: separa você do fundo e desfoca só o fundo.
   - **Correção de olhar (experimental)**: aproxima levemente a íris do centro do olho, quadro a quadro, sem mexer nas pálpebras e sem agir nas piscadas. É uma correção sutil. Não recria o olho como as ferramentas generativas (NVIDIA Broadcast, Descript, Captions). Para desvios grandes, como ler um roteiro longe da câmera, essas ferramentas externas ainda corrigem mais.
3. Clique em **Editar com IA**. O app transcreve, acompanha o rosto (quando necessário), pede ao Claude as decisões e gera a prévia.
4. **Converse no chat** (aba Chat, à direita). Por exemplo:
   - "Deixe a abertura mais forte."
   - "Faça um corte de 45 s para Reels."
   - "Tire o zoom do minuto 2."
   - "Coloque um título no início: Virtude e hábito."
   - "Legenda no estilo Ethos, mais sóbria."
   - "Use a imagem da biblioteca quando eu falar de Santo Agostinho."

   Cada pedido altera a edição e refaz a prévia. **Desfazer** volta à versão anterior.
5. Na aba **Cortes**, a IA sugere de 1 a 10 cortes curtos que funcionam sozinhos, cada um com título, gancho e justificativa. **Aplicar e ver prévia** carrega um corte. **Exportar todos os cortes** gera uma pasta para cada um.
6. Nas abas **Legendas** e **Efeitos** você confere e corrige tudo à mão: marca ou desmarca trechos, corrige texto e remove efeitos.
7. **Salvar projeto** guarda tudo (vídeo, cortes, efeitos e conversa), para você continuar depois.
8. **Legendas traduzidas** (ao lado de Exportar): marque Inglês, Espanhol, Italiano ou Francês. O Claude traduz e a exportação inclui `legendas-en.srt` etc.
9. **Exportar vídeo** cria uma pasta com `video.mp4` em Full HD, `legendas.srt`, `legendas.vtt`, `edicao.json` (as decisões de edição) e `LEIA-ME.txt` (o resumo do que foi feito).

## Edição manual (linha do tempo)

O player mostra a **edição ao vivo**: cada ajuste aparece na tela na hora, sem renderizar. O botão **Gerar prévia** continua disponível para ver o resultado final renderizado.

A **linha do tempo** fica embaixo. Arraste a alça acima dela para aumentar ou diminuir a altura. As faixas são:
- **Vídeo**: miniaturas quadro a quadro. As linhas douradas marcam as junções de cortes.
- **Legendas**: clique para editar o texto. Arraste as bordas para acertar a sincronia.
- **Efeitos**: zoom, texto e imagem. Arraste para mover, puxe as bordas para encurtar ou alongar, e clique para editar.
- **Áudio**: forma de onda da sua voz.

Como usar:
- Clique num espaço vazio de uma faixa: o cursor vai para lá e abre o menu **adicionar zoom / texto / imagem** naquele ponto. O **+** ao lado de cada faixa adiciona no cursor.
- Arraste sobre a régua ou a faixa de vídeo para **selecionar um trecho**. Depois escolha **Remover trecho**, **Zoom** ou **Texto**. **Restaurar trechos removidos** desfaz as remoções manuais.
- Atalhos: **espaço** reproduz, **← →** anda um quadro, **⇧← ⇧→** anda um segundo, **⌫** apaga o item selecionado. Use a lupa para aproximar ou afastar a linha do tempo.
- A aba **Editar** mostra as propriedades do item selecionado: início e fim com ajuste de 1 quadro (−1q/+1q) ou pelo cursor, intensidade do zoom, texto, **posição** (automática, longe do rosto, ou alto/centro/baixo), **animação** (surgir, subir, aproximar, máquina de escrever, revelar) e a **galeria de 12 estilos** (título clássico, cartão creme, citação, versículo, palavra-chave, capítulo, nome no rodapé, manuscrito, minimalista, caixa escura, impacto e pergunta). As miniaturas são desenhadas sobre o seu próprio quadro. Clicar num estilo aplica e mostra na tela.

## Recursos estilo CapCut (Reels e TikTok)

**Efeitos de vídeo** (faixa de Efeitos, em vermelho). Para usar: clique na faixa › Efeito de vídeo, botão direito › "Adicionar efeito de vídeo aqui", ⋯ de uma legenda, ou "Efeito" com um trecho selecionado. No painel Editar há uma galeria com miniaturas no seu próprio quadro e um ajuste de intensidade.
- **Tremor de câmera:** impacto, ênfase forte.
- **Glitch:** separação de cores e cortes digitais.
- **Flash:** clarão na batida.
- **Pulso:** zoom no ritmo.
- **Zoom 3D:** você se aproxima e o fundo quase não mexe.
- **Cor só em você:** o fundo fica em preto e branco.
- **Filme antigo:** grão, tom quente e cintilação.
- **Brilho de luz:** um feixe quente atravessa a imagem.
- **Desfoque → foco.**

**Layouts para imagens e vídeos de apoio:**
- **Tela cheia.**
- **Dividida: você em cima.**
- **Dividida: apoio em cima** (o formato mais comum em Reels).
- **Você na janelinha:** um círculo com borda dourada sobre o apoio.
- **Fundo virtual:** você recortada na frente da imagem ou do vídeo, sem precisar de tela verde.

**Transições novas:** chicote vertical, girar, glitch, pixelar, tremor e luz (além de corte seco, fade, flash, zoom, desfoque e chicote).

**Legendas virais:**
- **Hormozi:** maiúsculas pesadas, com a palavra falada amarela e maior.
- **Caixa:** a palavra falada sobre uma caixa dourada.
- **Uma palavra por vez:** grande e centralizada.

**Animações de texto:** **Pular** (entra quicando) e **Deslizar de lado**.

A IA também usa esses recursos quando você pede no chat ("coloca um glitch quando eu falo da virada", "tela dividida com o vídeo em cima") ou no ritmo Intenso, com moderação e nunca em momentos solenes (oração, sofrimento, Escritura).

## Modelo Reels Ethos (imagens em degradê + legenda bege)

O visual dos Reels de estudo: a imagem fica no alto e se dissolve num degradê sobre você, a legenda é serifada (Baskerville) em letra escura sobre uma faixa bege, e as frases-chave aparecem num cartão de citação.

1. Abra o vídeo e clique em **Modelo Reels Ethos…**. O botão está no alto da aba Efeitos, na barra da linha do tempo ("Reels Ethos") e abaixo de "Plataforma".
2. Escolha de onde vêm as imagens:
   - **Usar IA para buscar**: o Claude lê a narração e busca, para diferentes momentos, fotos e pinturas de licença livre (Openverse e Wikimedia Commons). Também pode buscar trechos de vídeo do Pexels (pede a chave gratuita) ou fazer ilustrações. Autor e licença ficam anotados em Biblioteca/fontes.txt.
   - **Adicionar**: você escolhe imagens, vídeos ou pastas inteiras. A IA coloca cada um na fala que combina, ou o app as espalha na ordem escolhida. Os arquivos são copiados para a Biblioteca.
3. Clique em **Montar Reels**. O app passa o vídeo para vertical 9:16, liga a legenda "Bege Ethos" (frase inteira), coloca as imagens com o layout **Degradê** e, opcionalmente, deixa uma a cada três em tela cheia. Também acrescenta cartões com frases que você realmente disse.

**Tudo continua editável à mão.** Cada imagem e cada cartão aparece na faixa de Efeitos:
- arraste a peça para mudar o momento e puxe as bordas para mudar a duração;
- clique nela para trocar a imagem (escolher da Biblioteca, buscar outra ou "Usar um arquivo do computador…"), mudar o layout (Degradê, Tela cheia, Dividida…) ou a entrada;
- botão direito ou Delete para apagar, e ⌘Z para desfazer.

A legenda "Bege Ethos" e o layout "Degradê" também podem ser escolhidos sozinhos, em qualquer vídeo: a legenda em Legendas → Estilo, o layout no painel de cada imagem.

## Imagens e vídeos para a narração (b-roll)

Botão **Imagens e vídeos** na barra da linha do tempo, ou **Imagens e vídeos para a narração…** na aba Efeitos. O Claude lê o que você diz e escolhe o apoio visual de cada momento. A sua voz continua, e o apoio aparece por cima (tela cheia ou dividida).

**De onde vêm:**
- **Pasta do computador:** escolha qualquer pasta (subpastas também entram). O Mac reconhece o conteúdo de cada imagem e vídeo, sem internet, e o Claude escolhe pelo conteúdo, então nomes como IMG_0412 funcionam. Os arquivos usados são copiados para a Biblioteca.
- **Biblioteca:** as imagens e vídeos de `Corta Studio/Biblioteca`.
- **Fotos da internet:** fotos e pinturas de licença livre (Openverse e Wikimedia Commons), no estilo Ethos.
- **Google / Pinterest (escolha manual)**: na janela "Imagem para a narração" (botão direito ▸ Imagem para a narração aqui), a primeira aba abre o Google Imagens ou o Pinterest dentro da própria janela, com a busca sugerida pelo Claude. Clique numa imagem para abri-la grande e **arraste-a para "Solte aqui"**, ou clique com o botão direito ▸ Copiar imagem ▸ **Colar (⌘V)**. A imagem vai para a Biblioteca, e o endereço de origem fica em `fontes.txt`.
  - O filtro "Só com licença Creative Commons" do Google vem ligado. Mesmo assim, imagens do Google e do Pinterest costumam ter dono: confira a licença na página antes de publicar.
  - O Pinterest só mostra a busca para quem está logado. Entre na sua conta uma vez dentro da janela, e o login fica guardado.
- **Vídeos da internet:** vídeos curtos do **Pexels** (Full HD, licença livre para uso comercial, sem obrigação de crédito). É preciso uma **chave gratuita**: crie uma conta em pexels.com, abra pexels.com/api, clique em "Your API Key" e cole na janela. A chave fica guardada nas Chaves do macOS. Só os segundos usados são baixados.
- **Ilustrações do Claude:** uma por momento, no estilo Ethos.

**Onde:** onde a IA achar que ajuda (poucos, médio ou muitos apoios), onde você olha para fora da câmera ("Cobrir olhadas") ou no trecho selecionado (botão direito › "Imagem ou vídeo de uma pasta / internet aqui…").

Os vídeos de apoio aparecem em azul na faixa de Efeitos. Ficam mudos e, se forem mais curtos que o trecho, se repetem. No painel Editar dá para trocar, mudar a entrada ou a exibição. **⌘Z desfaz tudo de uma vez.**

Sobre outras fontes de vídeo: o Internet Archive e os vídeos do Wikimedia Commons foram testados e **descartados**. As buscas automáticas devolviam conteúdo sem relação com o tema ou impróprio (por exemplo, documentários de guerra e noticiário político para "biblioteca antiga").

## Gravei lendo um roteiro (modo roteiro)

Para gravações feitas de uma vez, lendo o roteiro, com erros, recomeços e olhadas para baixo. Em **O que a IA decide**, ligue **Gravei lendo um roteiro** e clique em **Editar com IA**. O app:
1. **Analisa o seu olhar** no vídeo inteiro: câmera, roteiro (para baixo) ou lado. Leva cerca de 2 minutos para 43 minutos de vídeo, e só na primeira vez; depois o resultado fica guardado.
2. Entrega ao Claude a transcrição, com a **porcentagem de olhar para a câmera em cada fala**, e o roteiro, se você colar (**Colar o roteiro** aceita texto, .md ou .docx).
3. O Claude **escolhe uma tomada por ideia**: a completa, fluida e olhando para a câmera. Tira recomeços ("esse ano nós iniciamos" → fica só a versão corrigida), tropeços, repetições, checagens ("tá me ouvindo?") e comentários fora do conteúdo, mantendo a ordem do roteiro sem inventar nada.
4. O app tira as **pausas de leitura no meio das frases** e os **silêncios olhando para fora** (opção "Cortar silêncios olhando para fora").
5. No fim, o chat diz quanto do vídeo ainda tem você falando olhando para fora (quando não havia outra tomada boa). Esses trechos ficam **em laranja** na faixa de vídeo. Se passarem de 10%, o app liga a **correção de olhar**. Ela ajuda quando você olha para baixo, mas **não corrige cabeça virada**. Para esses casos, use botão direito › **Imagem para a narração aqui** para cobrir o trecho.

Resultado no teste com a sua gravação: a abertura de 2min30 virou **40 s** de narração contínua.

**Cobrir olhadas com imagens:** o botão **Cobrir olhadas** fica sempre na barra da linha do tempo (ao lado do tempo); também está na aba **Efeitos** e no bloco do modo roteiro. Se o olhar ainda não foi analisado, ele analisa antes. O número entre parênteses é a quantidade de trechos laranja. Ele lista os trechos (a partir de 1 s, ou mais, se preferir) e cobre cada um com uma imagem ligada ao que você está dizendo. A sua voz e as legendas continuam. As opções de imagem são:
- **Fotos livres da internet**: o Claude decide a busca de todos os trechos numa só mensagem e o app pega a melhor foto do Openverse ou do Wikimedia Commons, no estilo do Ethos (pinturas clássicas, livros, bibliotecas, arquitetura, natureza). Filmes, marcas e cultura pop ficam de fora. Autor e licença vão para `Biblioteca/fontes.txt`.
- **Ilustrações do Claude**: uma ilustração por trecho (cerca de 1 minuto e uma mensagem do plano para cada uma).
- **Minha biblioteca**: o Claude escolhe pelo nome do arquivo.

Cada imagem aparece na faixa de Efeitos e pode ser trocada no painel Editar (Buscar ou gerar outra imagem…). **⌘Z desfaz tudo de uma vez.**

## O que está na tela é o que será exportado

- O player mostra sempre a **edição completa**, com tudo o que foi feito pelo chat, pela IA, nas legendas, nos cortes e à mão. Não existe mais "gerar prévia": o que você vê é o resultado. O botão de olho mostra o **original sem edição**, só para comparar.
- Acima do vídeo aparece **o que está aberto**: "Vídeo completo" ou "Corte: título".
- **Cortes**: clique num corte para abri-lo no editor. Tudo o que você mudar nele fica **guardado no próprio corte**. Você pode ir para outro corte ou para o vídeo completo e voltar sem perder nada. Os cartões mostram **NA TELA** (aberto agora) e **editado** (você mudou algo). **Exportar com edições…** exporta o corte com as suas mudanças, mesmo que ele não esteja aberto. **Desfazer edições** volta à sugestão original.
- **Exportar vídeo… / Exportar este corte…** (rodapé, ⌘E) exporta exatamente o que está na tela. Você escolhe **nome e pasta**; as legendas `.srt` e `.vtt` ficam ao lado, com o mesmo nome.
- **Salvar projeto** (⌘S): na primeira vez, você escolhe o nome; depois o projeto **salva sozinho** a cada alteração ("salvo às…" no rodapé). O projeto guarda o vídeo completo e todos os cortes com as edições, e **não copia** o vídeo original (mantenha-o no lugar; se ele mudar de pasta, o app pede para localizá-lo).

## Botão direito na linha do tempo

Clique com o botão direito (ou Control+clique / dois dedos no trackpad) em qualquer ponto da linha do tempo:
- **Dividir aqui** (⌘B): cria um corte naquele ponto, sem tirar nada.
- **Selecionar / Apagar este trecho**: o trecho entre duas divisões. Um clique simples na faixa de vídeo também seleciona o trecho; depois é só apertar **⌫ (Delete)**.
- **Apagar do início até aqui** e **Apagar daqui até o fim**.
- Numa legenda: **Editar**, **Apagar só o texto** (a fala continua; também com ⌫) ou **Remover esta fala do vídeo**.
- Num efeito: **Editar** ou **Apagar** (⌫).
- **Adicionar zoom, texto, imagem para a narração ou legenda** naquele ponto.
- **Remover todas as divisões**.

## Ver antes de escolher

No painel da esquerda, as opções visuais aparecem como **miniaturas desenhadas sobre o quadro atual do seu vídeo**. Elas se atualizam quando você muda de ponto na linha do tempo. Clique numa miniatura para aplicar; a explicação da opção escolhida aparece embaixo e também ao passar o mouse.
- **Ritmo** (Natural, Dinâmico, Intenso): mini-gráfico com a densidade de cortes (traços dourados) e o movimento do zoom (linha).
- **Estilo da legenda**: Ethos, Contorno, Clássica e Destaque, com uma frase de exemplo.
- **Enquadrar**: preencher ou inteiro com fundo desfocado.
- **Cor**: Natural, Ethos clássico (mais quente, com vinheta suave), Cinema, Preto e branco, Vívido suave.
- **Transições**: cada tipo mostrado no meio do efeito.
- **Efeitos de imagem**: vinheta e fundo desfocado (clique para ligar ou desligar).

## Desfazer e refazer

Toda alteração vira um passo no histórico: efeitos, legendas, cortes, opções do painel, transições, título e mudanças feitas pela IA. Digitação e arrastes rápidos são agrupados num só passo. Ficam guardados até 150 passos.

- **Desfazer**: botão ↶ (embaixo do vídeo e na barra da linha do tempo), **⌘Z** ou **Ctrl+Z**.
- **Refazer**: botão ↷, **⇧⌘Z**, **Ctrl+Shift+Z** ou **Ctrl+Y**.
- Dentro de um campo de texto, o atalho desfaz primeiro a digitação; fora dele, desfaz a edição.
- Se você desfizer e depois fizer uma alteração nova, os passos que estavam "à frente" são descartados, como em qualquer editor.

## Zoom, transições e imagens para a narração

**Zoom**: há 5 tipos, escolhidos ao adicionar ou no painel Editar, que mostra a curva de cada um:
- **Aproximar e voltar**
- **Zoom in**: aproxima e fica
- **Zoom out**: começa perto e abre
- **Corte com aproximação**: punch-in instantâneo, típico de Reels
- **Batida**: entra rápido e volta

Para cada zoom você ajusta a intensidade e a **velocidade da transição** (rápida, normal, lenta, muito lenta ou ao longo de todo o trecho). A velocidade do **zoom progressivo** fica em Imagem › Velocidade.

**Transições**: cada junção de cortes aparece como um **losango** na faixa de vídeo. Clique nele para escolher **corte seco, fade preto, flash, zoom, desfoque ou chicote** e a duração. **Ver a transição** mostra o resultado, e **Usar em todos os cortes** aplica em todas as junções. O ajuste global fica em Imagem › Transições, nas mudanças de assunto ou em todos os cortes. Não existe dissolução entre duas cenas sobrepostas: o motor atual monta uma imagem de cada vez.

**Imagens para a narração**: escolha o trecho de um destes jeitos:
- botão ⋯ de uma legenda › **Buscar ou gerar imagem para esta fala…**;
- clique na faixa › **Buscar ou gerar imagem…**;
- selecione um trecho › **Imagem p/ narração**.

A janela tem três opções:
- **Fotos reais (internet)**: o Claude lê a fala e sugere a busca. Os resultados vêm do **Openverse** (Flickr e outros acervos, com licenças que permitem uso comercial) e do **Wikimedia Commons**. Autor e licença ficam em `Biblioteca/fontes.txt`. Licenças **CC BY** exigem citar o autor na descrição do vídeo.
- **Ilustração por IA (Claude)**: o Claude desenha uma ilustração vetorial no estilo do Ethos, em cerca de 1 minuto, usando o seu plano. O arquivo fica marcado como gerado por IA.
- **Apple Image Playground**: só funciona com a Apple Intelligence ativada (Ajustes do Sistema › Apple Intelligence e Siri). Hoje está desativada neste Mac.

Escolha também a **exibição** (tela cheia ou dividida) e a **entrada** (suave, deslizar, aproximar ou corte seco). A imagem aparece na faixa de Efeitos e pode ser movida, encurtada ou trocada.

## Aba Legendas

- **Título de abertura** (no topo): digite o título que aparece no início do vídeo e escolha estilo, animação e duração. Logo abaixo fica a **pergunta/gancho** dos primeiros segundos. A IA preserva o seu título.
- **Botão ⋯ em cada legenda**:
  - **Usar este texto em destaque**: cria o texto na tela no tempo exato daquela fala, nos estilos cartão creme, citação, palavra-chave, impacto, caixa escura, minimalista, versículo, manuscrito ou título. Enquanto o destaque aparece, a legenda daquele trecho some, para não repetir o texto. Abre a aba Editar para você ajustar.
  - **Zoom de ênfase**, **Imagem da biblioteca** ou **Usar como título de abertura**.
  - **Ir para este trecho** e **Tirar do vídeo / Trazer de volta**.
- O ícone **Aa** indica as legendas que já têm destaque.

## Gancho em vídeo (abrir com o ápice e voltar ao começo)

O vídeo abre com o momento mais forte da fala: uma frase intrigante, a tese, a virada ou uma pergunta, com 3 a 8 s. Em seguida entra uma transição (por padrão **Rebobinar**, efeito de fita voltando com ◀◀) e o vídeo segue do começo. Quando chega naquele ponto, a fala aparece de novo, no lugar dela. Funciona no vídeo completo do YouTube, nos Reels e em cada corte.

- **Automático**: em **O que a IA decide**, ligue **Gancho em vídeo no início**. O **Editar com IA** escolhe o ápice.
- **Na aba Reels › Gancho em vídeo**:
  - **Encontrar o melhor gancho**: a IA sugere 3 momentos, aplica o primeiro e mostra os outros para você trocar com um clique.
  - **Usar trecho selecionado**: arraste na linha do tempo e use esse trecho como gancho.
  - Ajuste o início e o fim (0,25 s por clique), troque a transição (Rebobinar, Flash, Mergulho no preto, Chicote, Glitch, Corte seco), use **Ver** para assistir ou **Tirar** para remover.
- **Nos cortes**: na aba Cortes, ligue **Gancho em vídeo** nas opções de busca. Cada corte vem com o próprio ápice (aparece "▶ GANCHO" no cartão) e dá para ligar ou desligar em **Mais**.
- **Pelo botão direito**: selecione um trecho na linha do tempo, clique com o botão direito e escolha **Usar este trecho como gancho no começo (◀◀ rebobinar)**.
- **Na linha do tempo**: o gancho aparece em roxo no começo ("▶ GANCHO"). Selecionar e apagar o começo ou o fim dele encurta o gancho, e apagar o trecho inteiro o remove, sem tirar a fala do lugar original.
- **No chat**: "abra o vídeo com o momento mais forte", "use como gancho a parte em que falo da humildade", "tire o gancho".

## O que a IA faz pelo chat

Além de cortes, legendas, efeitos e ajustes, o chat agora também:
- coloca, troca ou tira o **gancho em vídeo**;
- escolhe a **transição de cada junção** (por exemplo "um glitch na volta da história, fade no fim");
- **busca imagens ou vídeos** para a narração ("busque imagens para a narração, poucas, em degradê");
- **cobre as olhadas** para fora da câmera com imagens;
- **monta o Reels Ethos**;
- põe **cartões de citação** com frases que você disse;
- **gera cortes** ("faça 5 cortes de menos de 30 s sobre humildade").

A IA explica na resposta o que vai fazer, e tudo pode ser desfeito com ⌘Z.

## Editar textos clicando na prévia

Com o vídeo pausado, passe o mouse sobre um texto da prévia: aparece uma moldura pontilhada. Clique para abri-lo na aba **Editar**, onde dá para mudar a frase, o estilo, a animação, a posição e o tempo. Funciona com:
- **Textos de destaque**, que na edição se chamam *callouts* ou *text highlights*. No app são os estilos **Cartão creme** (frase importante numa caixa clara), **Citação**, **Palavra-chave**, **Impacto** e outros;
- **Capítulos**, que na edição se chamam *chapter markers* ou *section titles*. No app é o estilo **Capítulo**, uma caixinha no alto que marca o início de uma parte ("Parte 1 · O hábito", "Primeiro: …");
- **Legendas** (abre a legenda daquele momento);
- **Gancho escrito** (abre a aba Reels).

## Aba Cortes (gerador de cortes com IA)

Transforma um vídeo longo em vários cortes curtos, como os geradores de cortes (OpusClip e parecidos).

**Opções de busca** (botão "Opções de busca"):
- **Procurar por**: um tema ou tipo de momento, por exemplo "momentos sobre paciência", "histórias pessoais" ou "frases de impacto". Se poucos trechos atenderem, a IA devolve menos cortes em vez de fugir do pedido.
- **Duração**: automática, menos de 30 s, 30 a 60 s, 60 a 90 s ou 90 s a 3 min.
- **Conteúdo**: aula ou reflexão, leitura comentada, conversa, pregação, notícia ou dica prática. Ajuda a IA a entender o que é um bom corte.
- **Trecho analisado**: procurar só numa parte do vídeo (de… até…).
- **Visual dos cortes**: Reels Ethos (legenda bege), Viral (Hormozi, palavra a palavra), Ethos clássico, Limpo (sem legenda) ou igual ao vídeo completo.
- **Gancho escrito nos primeiros segundos** e **quantidade** (até 20).

**Cada corte vem com:**
- miniatura, duração e tema;
- **nota de potencial de 0 a 99**, somando gancho, fluxo, valor e atualidade (até 25 cada). A atualidade é uma estimativa da IA, que não consulta a internet;
- título e frase de gancho;
- **texto do post e hashtags**, editáveis, com o botão **Copiar post**. A IA não inventa citações nem referências.

**Em cada corte você pode:**
- clicar para abri-lo no editor. As edições ficam guardadas no próprio corte;
- em **Mais**:
  - ver a nota detalhada e a fala do corte;
  - **mudar o início e o fim** em frases inteiras (◀ ▶);
  - trocar o visual e ligar ou desligar o gancho;
  - montar o **Reels Ethos** nesse corte;
- com o **botão direito**: renomear, favoritar, copiar o post, desfazer edições ou apagar;
- ordenar por **maior nota** ou **ordem do vídeo**, e filtrar os **favoritos** (★).

**Exportar todos** ou **Exportar favoritos**: cada corte sai com as suas edições, as legendas (`.srt` e `.vtt`) e um `.txt` com título, texto do post e hashtags.

## Aba Reels

Reúne tudo o que é de Reels, Shorts e TikTok para o que está aberto (o vídeo completo ou o corte aberto):
- **Formato**: plataforma, estilo e animação da legenda, posição, barra de progresso e gancho escrito.
- **Zonas do Instagram/TikTok na prévia**: mostra, só na prévia, onde o aplicativo põe botões, nome e texto do post, para nada importante ficar escondido. Não aparece na exportação.
- **Modelo Reels Ethos**: imagens em degradê, legenda bege e cartões de citação, com "Usar IA para buscar" ou "Adicionar" (veja a seção acima). Botão **Montar Reels**.

## Limites do plano

Cada **Editar com IA** e cada mensagem do chat contam como uma mensagem no seu plano Claude (janela de 5 horas e limite semanal). Para acompanhar o uso: claude.ai › Configurações › Uso. Se o limite acabar, o app avisa e a edição manual continua funcionando. Sem conexão, o botão faz um **modo básico**: aplica seus ajustes, a redução de pausas e as legendas, mas sem as decisões da IA.

## O que ainda não existe nesta versão

- Busca automática de imagens ou vídeos na internet. As imagens vêm da sua Biblioteca, e você controla as licenças.
- Vídeos de apoio (b-roll em vídeo). Por enquanto são apenas imagens.
- Módulo de tendências.

## Problemas comuns

- **"Claude Code não foi encontrado"**: use **Localizar o Claude Code manualmente…** em IA e conta.
- **App sumiu ou demora a abrir**: se a pasta do projeto estiver no iCloud, clique com o botão direito em `Corta Studio` no Finder e escolha a opção de manter baixado.
- **Recompilar**: no Terminal, `zsh "codigo-fonte/build.sh"`.
