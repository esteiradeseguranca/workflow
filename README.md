# Esteira de Segurança — Reusable Workflow

O scan de segurança da [Esteira de Segurança](https://esteiradeseguranca.com.br)
(SAST, detecção de segredos, SCA/dependências, IaC, SBOM, verificação de EOL
de linguagem/runtime/serviço) roda **inteiramente no ambiente do cliente** —
GitHub Actions ou GitLab CI. Nenhum código-fonte sai do runner do cliente:
só o *resultado* do scan trafega até a nossa API.

Este repositório é a parte PÚBLICA disso — o reusable workflow do GitHub
Actions, o template equivalente do GitLab CI, e as composite actions que os
dois chamam. É o que um cliente referencia a partir do próprio repositório
(ver exemplos abaixo).

## GitHub Actions

### Como um cliente usa

Ver [`examples/client-workflow.yml`](examples/client-workflow.yml) — em
resumo, o cliente adiciona um workflow de ~10 linhas no repositório dele que
chama este reusable workflow, com o token dele (gerado na área
administrativa da Esteira de Segurança) como secret.

### Estrutura deste repositório

```
.github/workflows/security-scan.yml   # o reusable workflow em si (workflow_call)
actions/
  fetch-toolkit/                      # baixa scripts/regras (privados, ver abaixo) na hora — 1º passo do job
  fetch-entitlements/                 # consulta a API pra saber quais ferramentas o plano do cliente libera
  run-semgrep/                        # SAST
  run-gitleaks/                       # detecção de segredos
  run-trivy-fs/                       # SCA / vulnerabilidades em dependências
  run-checkov/                        # IaC (Terraform, CloudFormation, K8s, Dockerfile...)
  run-sbom/                           # gera SBOM (CycloneDX) via Syft
  run-grype/                          # SCA "segunda opinião" — lê o SBOM que o passo acima já gerou
  run-eol-check/                      # linguagem/runtime/serviço fora de suporte (EOL), via endoflife.date
  check-critical/                     # falha o job se achado crítico for encontrado (fail-on-critical)
  submit-results/                     # envia os resultados pra API da Esteira de Segurança
.gitlab/security-scan.yml             # o equivalente do reusable acima pra GitLab CI (`include:`), ver seção própria abaixo
examples/client-workflow.yml          # exemplo de workflow pro repositório do cliente (GitHub Actions)
examples/client-gitlab-ci.yml         # idem, GitLab CI
```

### Scripts e regras de detecção

O conteúdo que roda de verdade (os scripts que invocam cada ferramenta, e as
regras de detecção customizadas) não vive neste repositório público — é
mantido separadamente e baixado pelo próprio job, autenticado pelo token do
cliente, no primeiro passo (`actions/fetch-toolkit`). Se a busca falhar, o
job falha com uma mensagem clara — não há um modo "degradado" possível sem
esse conteúdo.

Cada ferramenta roda no runner do cliente via imagem Docker oficial pinada
por digest (Semgrep, Gitleaks, Trivy, Checkov, Syft) — sem instalar nada
além do que o GitHub Actions já provê (`ubuntu-latest` tem Docker). O EOL
check é exceção: não é um scanner de terceiro, é um módulo próprio em Python
puro, sem dependência externa.

### Cobertura por linguagem/ferramenta

Nenhuma ferramenta roda com filtro de linguagem — cada uma cobre o que a
versão pinada dela cobre nativamente. Resumo, do mais específico (por
linguagem) ao mais amplo (qualquer arquivo texto):

- **Semgrep (SAST)** — ruleset `p/default` (registry oficial), cobrindo as
  linguagens GA do Semgrep em 3 níveis de profundidade de análise:
  - Cross-file: C#, Go, Java, JavaScript, Kotlin, Python, TypeScript, C/C++
  - Cross-function: JSX, Ruby, Scala, Swift, Rust, PHP, Terraform
  - Suporte básico: Generic, JSON

  As regras customizadas próprias da Esteira de Segurança (privadas,
  buscadas via `actions/fetch-toolkit` — ver acima) cobrem hoje **Python**,
  **JavaScript/TypeScript** e **Java**, mais duas regras independentes de
  linguagem (CPF/CNPJ hardcoded, CORS mal configurado).
- **Gitleaks (segredos)** — independente de linguagem: varre todo arquivo
  texto e o histórico completo do git contra um conjunto de regex/entropia.
  Não importa em que linguagem o segredo está hardcoded.
- **Trivy fs (SCA/dependências)** — detecta manifestos/lockfiles de 13
  linguagens: Ruby, Python, PHP, Node.js, .NET, Java (Maven/Gradle), Go,
  Rust, C/C++, Elixir, Dart, Swift, Julia.
- **Grype (SCA — segunda opinião)** — mesma classe de achado do Trivy
  (CVE em dependência), motor de detecção e banco de vulnerabilidades
  independentes (Anchore). Não escaneia o filesystem de novo — lê o SBOM
  que o passo de SBOM (Syft) já gerou. Requer SBOM habilitado no plano.
- **Checkov (IaC)** — Terraform (AWS/GCP/Azure/OCI), CloudFormation
  (incluindo SAM), Azure Resource Manager (ARM), Serverless Framework,
  Helm, Kubernetes, Dockerfile — e, via checks adicionais do próprio
  Checkov, também Ansible, Argo Workflows, Bicep, Bitbucket Pipelines,
  CircleCI, GitHub Actions, GitLab CI, OpenAPI.
- **SBOM (Syft)** — inventário de componentes em dezenas de ecossistemas;
  os mais relevantes pra código-fonte (sem imagem de container): Python,
  Java, JavaScript/Node, Ruby, Rust, PHP, Go, .NET — e mais. Não gera
  achado de vulnerabilidade sozinho (é inventário puro).
- **EOL check** — cobertura bem mais estreita, de propósito (ver seção
  própria abaixo): Python, Node, Go, Ruby e PHP via manifest, mais
  qualquer linguagem/runtime/serviço citado num `FROM` de Dockerfile.

### Camada Básica (padrão, sempre disponível)

Se a API de entitlements ainda não existir ou o token não puder ser
validado, o workflow **não falha** — ele cai de volta para a camada Básica
(as 6 ferramentas open source acima, todas habilitadas). Isso garante que o
scan sempre roda, mesmo antes da API de ingestão existir ou responder.

### Verificação de EOL (fim de suporte)

`actions/run-eol-check/` detecta linguagem/runtime/serviço usado no
repositório do cliente (via `FROM` de Dockerfile e um punhado de manifests
comuns — `.python-version`, `runtime.txt`, `.nvmrc`, `package.json`
`engines.node`, `go.mod`, `.ruby-version`, `composer.json` `require.php`) e
consulta a API pública da [endoflife.date](https://endoflife.date/docs/api/v1/)
pra saber se aquela versão já está fora de suporte. Diferente de um scanner
de vulnerabilidade (que depende de CVE já catalogado pra uma dependência
específica), isto é um risco estrutural: existe mesmo sem nenhum CVE
conhecido hoje, porque a próxima vulnerabilidade descoberta numa versão EOL
não vai ganhar correção oficial.

### Versionamento

O cliente referencia uma tag, não `main` (ex.: `@v1` em
`examples/client-workflow.yml`). Regra:

- Mudanças que **não quebram** compatibilidade (nova ferramenta, campo novo
  no output, correção de bug) → nova tag minor/patch, cliente pode migrar
  quando quiser.
- Mudanças que **quebram** compatibilidade (input removido/renomeado, secret
  obrigatório novo, mudança no formato de output) → nova tag major (`v2`), a
  tag `v1` continua funcionando como estava.

As composite actions (`actions/*`) são referenciadas de dentro do reusable
workflow usando a forma `owner/repo/path@ref` (não `./path` local) — isso é
necessário porque, quando este workflow roda como reusable workflow chamado
por outro repositório, o checkout ativo durante a execução é o do
repositório do **cliente**, não o nosso. Um `uses: ./actions/x` resolveria
(incorretamente) contra o repo do cliente.

### Segredos/inputs esperados

| Nome | Onde | Obrigatório | Descrição |
|---|---|---|---|
| `token` (secret) | chamada do reusable workflow | sim | Token do cliente, gerado na área administrativa |
| `api-url` (input) | chamada do reusable workflow | não | Base da API (default: produção) |
| `fail-on-critical` (input) | chamada do reusable workflow | não | Falha o job se houver achado crítico nos resultados brutos — checagem best-effort |

## GitLab CI

### Como um cliente usa

Ver [`examples/client-gitlab-ci.yml`](examples/client-gitlab-ci.yml) — em
resumo, o cliente cria uma CI/CD variable protegida `ESTEIRA_TOKEN`
(Settings → CI/CD → Variables) com o token recebido e adiciona um
`include:` de ~3 linhas no `.gitlab-ci.yml` dele apontando pra
[`.gitlab/security-scan.yml`](.gitlab/security-scan.yml).

### Por que a estrutura é diferente do lado GitHub Actions

O `include:` do GitLab CI só mescla **configuração YAML** — diferente do
GitHub, que resolve `owner/repo/path@ref` e dá às composite actions acesso
direto ao conteúdo do repositório referenciado, o GitLab não dá a este job
acesso automático a nenhum arquivo. Por isso o `before_script` do template
baixa o mesmo conteúdo (scripts + regras) usado do lado GitHub Actions, na
hora, autenticado pelo mesmo `ESTEIRA_TOKEN`.

### Docker-in-Docker

O job roda com `image: docker:24.0.5-cli` + `services: [docker:24.0.5-dind]`
+ `DOCKER_TLS_CERTDIR: "/certs"` — a configuração oficial recomendada pelo
GitLab para Docker-in-Docker com TLS no executor Docker (inclusive o
runner compartilhado do GitLab.com), necessária pros `docker run` de cada
ferramenta funcionarem dentro do job.

### Fetch-depth / GIT_DEPTH

`GIT_DEPTH: "0"` no template pede histórico completo no checkout nativo do
GitLab CI — equivalente ao `fetch-depth: 0` do checkout do lado GitHub
Actions, necessário pro Gitleaks escanear commits antigos, não só o HEAD.

### Segredos/variáveis esperadas

| Nome | Onde | Obrigatório | Descrição |
|---|---|---|---|
| `ESTEIRA_TOKEN` | CI/CD variable do projeto cliente (protected + masked) | sim | Token do cliente, gerado na área administrativa |
| `ESTEIRA_API_URL` | variável do template, sobrescrevível | não | Base da API (default: produção) |
| `ESTEIRA_FAIL_ON_CRITICAL` | variável do template, sobrescrevível | não | `"true"`/`"false"` — bloqueia o pipeline se houver achado crítico, mesma checagem best-effort do lado GitHub Actions |
| `ESTEIRA_WORKFLOW_REF` | variável do template, sobrescrevível | não | Tag do conteúdo (scripts/regras) a buscar — só faz sentido mudar em teste |

---

Este repositório é a parte pública de um produto maior — ver
[esteiradeseguranca.com.br](https://esteiradeseguranca.com.br).
