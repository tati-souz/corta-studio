# Corta Studio

Editor de vídeo com IA para Mac, em português. Você escolhe o vídeo e marca o que quer: plataforma (YouTube, Shorts, Reels, TikTok), legendas, zooms, cortes inteligentes, redução de pausas, imagens de apoio e voz de estúdio. Depois clica em **Editar com IA**. O Claude monta a edição, você refina conversando no chat ou à mão na linha do tempo, salva o projeto e exporta.

A IA roda com **a sua assinatura do Claude** (Pro ou Max), através do Claude Code instalado no Mac. Não há cobrança por API e nenhuma chave é guardada no código. A transcrição, o reconhecimento de rosto e o processamento de imagem e áudio acontecem no próprio Mac.

## Requisitos

| | |
|---|---|
| Mac | Apple Silicon (M1 ou posterior) |
| Sistema | macOS 26 (Tahoe) ou posterior, recomendado. O app abre a partir do macOS 14, mas a transcrição automática das falas exige o macOS 26. Em sistemas anteriores, só é possível editar importando um arquivo SRT. |
| Ferramentas | Ferramentas de Linha de Comando do Xcode (gratuitas) |
| IA | Conta Claude com plano pago (Pro ou Max) e o [Claude Code](https://docs.claude.com/en/docs/claude-code) instalado |
| Opcional | Chave gratuita do [Pexels](https://www.pexels.com/api/) para buscar trechos de vídeo de apoio |

## Instalação

Abra o **Terminal** (⌘ Espaço, digite "Terminal") e rode os passos abaixo.

**1. Ferramentas de Linha de Comando do Xcode.** Se já estiverem instaladas, o comando avisa.

```bash
xcode-select --install
```

**2. Claude Code.** Pule este passo se você já usa o app Claude para desktop com o Claude Code, porque o Corta Studio encontra essa cópia sozinho.

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

**3. Baixar o Corta Studio.**

```bash
git clone https://github.com/tati-souz/corta-studio.git ~/corta-studio
```

**4. Compilar e instalar.** Leva cerca de um minuto. O script compila, instala em **Aplicativos**, põe o ícone no Dock e abre o app.

```bash
zsh ~/corta-studio/codigo-fonte/build.sh
```

Se não quiser o ícone no Dock, rode `DOCK=0 zsh ~/corta-studio/codigo-fonte/build.sh`.

**5. Entrar com o Claude.** No app, clique em **IA e conta** › **Entrar com Claude**. O Terminal abre o login oficial no navegador. Basta fazer isso uma vez.

Na primeira transcrição, o macOS pode pedir permissão para o reconhecimento de fala e baixar o modelo de português. Aceite.

### Atualizar

```bash
cd ~/corta-studio && git pull && zsh codigo-fonte/build.sh
```

O script fecha a versão aberta, substitui a de Aplicativos e abre a nova.

### Desinstalar

Apague `/Applications/Corta Studio.app` e a pasta `~/corta-studio`.

## Como usar

O guia completo, com todos os recursos e onde ficam, está em **[LEIA-ME.md](LEIA-ME.md)**. Em resumo:

1. **Escolher vídeo** (horizontal ou vertical). O original nunca é alterado.
2. Marque o que quer no painel da esquerda. Cada opção tem prévia.
3. Clique em **Editar com IA**.
4. Assista à prévia, que já mostra a edição como será exportada.
5. Ajuste:
   - **No chat**, por exemplo: "tira a parte em que repito a frase", "coloca um zoom quando falo da virtude".
   - **Na linha do tempo**: mover, esticar, cortar (⌘B), apagar, trocar imagens. ⌘Z desfaz.
6. **Salvar projeto** (⌘S) e **Exportar** (⌘E).

### Destaques

- **Modelo Reels Ethos:** a imagem fica no alto e se dissolve num degradê sobre você. A legenda é serifada sobre uma faixa bege e há cartões de citação nas frases-chave. As imagens vêm de uma busca da IA (fotos e pinturas de licença livre, vídeos do Pexels) ou de uma pasta sua.
- **Modo roteiro:** para quem grava lendo. Escolhe as melhores tomadas, tira recomeços e erros, e cobre com imagens os trechos em que você olha para fora da câmera.
- **Legendas:**
  - estilos Ethos, Bege, Contorno, Hormozi, Caixa e outros;
  - modo palavra a palavra, uma palavra por vez ou blocos;
  - exportação em SRT/VTT e tradução.
- **Efeitos:**
  - zooms (suave, punch-in, batida) com controle de velocidade;
  - 12 transições;
  - efeitos de vídeo (glitch, tremor, zoom 3D, cor só em você, filme antigo…);
  - tela dividida, janelinha e fundo virtual.
- **Áudio:** voz de estúdio (isolamento de voz, equalização, compressão), música com abaixamento automático durante a fala e efeitos sonoros discretos.
- **Gerador de cortes (aba Cortes):**
  - transforma um vídeo longo em vários cortes;
  - busca por tema ("momentos sobre paciência"), duração (de menos de 30 s a 3 min) e trecho do vídeo;
  - dá a cada corte uma nota de potencial de 0 a 99 (gancho, fluxo, valor, atualidade);
  - gera título, gancho, texto do post e hashtags;
  - permite ajustar início e fim, mudar o visual, favoritar e exportar todos ou só os favoritos.
- **Gancho em vídeo:** o vídeo (ou cada corte) abre com o ápice da fala, faz uma transição de "rebobinar" e segue do começo. A IA escolhe o momento ou você marca na linha do tempo.
- **Chat que edita tudo:** cortes, legendas, efeitos, transições por junção e gancho. Também busca imagens, monta o Reels, cobre olhadas, gera cortes e põe cartões de citação.
- **Aba Reels:** formato, legenda, barra de progresso e gancho num só lugar, com as zonas do Instagram/TikTok marcadas na prévia.

## Onde ficam os arquivos

| Pasta | O que é |
|---|---|
| `/Applications/Corta Studio.app` | O aplicativo instalado. É uma única cópia, substituída a cada atualização. |
| `Biblioteca/` (na pasta do projeto) | Seus materiais: `Imagens/`, `Videos/`, `Musicas/`, `Marca/logo.png`. O arquivo `fontes.txt` registra autor e licença de cada imagem ou vídeo baixado. A pasta é criada no primeiro uso e não vai para o Git. |
| `codigo-fonte/Sources/` | Código Swift (SwiftUI, AVFoundation, Core Image, Vision, Speech). |
| `codigo-fonte/build.sh` | Compila, instala e abre o app. |

Projetos salvos (`.cortaproject`) guardam a edição e o caminho do vídeo original, sem copiá-lo.

## Privacidade e limites

- A IA recebe a **transcrição** e os ajustes da edição, nunca o vídeo nem as imagens. O conteúdo das imagens de uma pasta sua é reconhecido no próprio Mac, e o Claude recebe só o nome do arquivo e uma descrição curta.
- O uso conta nos limites da sua assinatura do Claude (por sessão e semanais). O modelo é escolhido em **IA e conta**: Sonnet é o padrão, Opus é mais cuidadoso e gasta mais, Haiku é o mais econômico.
- Imagens e vídeos buscados na internet vêm de fontes de licença livre (Openverse, Wikimedia Commons, Pexels). Mesmo assim, confira a licença registrada em `Biblioteca/fontes.txt` antes de publicar.
- **Ainda não existe:** câmera lenta, aceleração de trechos e quadro congelado; figurinhas e emojis; sincronia com a batida da música.
- O app não é assinado com um certificado de desenvolvedor da Apple: é compilado no seu próprio Mac pelo `build.sh`. Por isso não há `.dmg` para baixar.

## Licença

[MIT](LICENSE)
