# Voice Assistant CI med Tekton

Det här beskriver hur CI används för frontend och backend, hur man startar manuella körningar, hur webhook-flödet fungerar och hur man felsöker status och loggar.

CI:n körs i Kubernetes-namespacet `voice-assistant-ci` på MicroK8s och definieras som Tekton-resurser i den här katalogen.

## Översikt

Det finns två pipelines:

| Pipeline | Repo | Image |
| --- | --- | --- |
| `voice-assistant-frontend-ci` | `https://github.com/azizzakiryarov/voice-assistent-frontend.git` | `docker.io/azizzakiryarov/voice-assistant-frontend` |
| `voice-assistant-backend-ci` | `https://github.com/azizzakiryarov/voice-assistant-backend.git` | `docker.io/azizzakiryarov/voice-assistant-backend` |

Pipeline körs automatiskt vid push till `main` via GitHub webhook:

```text
https://voice-assistant.duckdns.org/tekton-github
```

Webhooken filtrerar på repository och branch:

- frontend: `azizzakiryarov/voice-assistent-frontend`, `refs/heads/main`
- backend: `azizzakiryarov/voice-assistant-backend`, `refs/heads/main`

Varje lyckad pipeline pushar två taggar:

- `<image>:<git-sha>`
- `<image>:latest`

## Vad frontend-CI gör

Frontend-pipelinen heter `voice-assistant-frontend-ci`.

Steg:

1. Klonar frontend-repot.
2. Kör `npm ci`.
3. Kör `npm run lint`.
4. Kör `npm test` om `package.json` innehåller ett `test`-script.
5. Kör `npm run build`.
6. Kör Trivy source/dependency scan.
7. Bygger OCI-image med Buildah till ett lokalt image-arkiv.
8. Kör Trivy image scan på image-arkivet.
9. Pushar image till Docker Hub om alla tidigare steg lyckas.

Lokalt motsvarar det ungefär:

```bash
cd /Users/azizzakiryarov/IdeaProjects/voice-assistent-frontend
./build.sh
```

## Vad backend-CI gör

Backend-pipelinen heter `voice-assistant-backend-ci`.

Steg:

1. Klonar backend-repot.
2. Kör Maven unit tests med Java 21: `mvn -B -ntp test`.
3. Kör Maven integration/verify med Java 21: `mvn -B -ntp verify`.
4. Startar en PostgreSQL 16 sidecar för integrationstester.
5. Kör Trivy source/dependency scan.
6. Bygger OCI-image med Buildah till ett lokalt image-arkiv.
7. Kör Trivy image scan på image-arkivet.
8. Pushar image till Docker Hub om alla tidigare steg lyckas.

Lokalt motsvarar det ungefär:

```bash
cd /Users/azizzakiryarov/IdeaProjects/voice-assistant-backend
./build.sh
```

Backend-CI sätter dessa miljövariabler för integrationstesterna:

```text
SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/voiceassistant
SPRING_DATASOURCE_USERNAME=ci
SPRING_DATASOURCE_PASSWORD=ci
GOOGLE_CALENDAR_CLIENT_ID=ci-client-id
GOOGLE_CALENDAR_CLIENT_SECRET=ci-client-secret
```

## Installera eller uppdatera CI-resurser

Kör från gitops-repot:

```bash
cd /Users/azizzakiryarov/IdeaProjects/voice-assistant-backend-gitops
kubectl --context microk8s apply -f ci/tekton/00-namespace-rbac.yaml
kubectl --context microk8s apply -f ci/tekton/10-workspaces.yaml
kubectl --context microk8s apply -f ci/tekton/20-tasks.yaml
kubectl --context microk8s apply -f ci/tekton/30-pipeline.yaml
kubectl --context microk8s apply -f ci/tekton/40-triggers.yaml
kubectl --context microk8s apply -f ci/tekton/50-ingress.yaml
```

Kontrollera att resurserna finns:

```bash
kubectl --context microk8s -n voice-assistant-ci get pipelines,tasks,eventlisteners,triggerbindings,triggertemplates
kubectl --context microk8s -n voice-assistant-ci get pvc,secret,ingress,svc,pod
```

## Nödvändiga secrets

Docker Hub credentials:

```bash
kubectl --context microk8s -n voice-assistant-ci create secret docker-registry dockerhub-credentials \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username='<dockerhub-user>' \
  --docker-password='<dockerhub-token>' \
  --docker-email='<email>'
```

GitHub webhook secret:

```bash
kubectl --context microk8s -n voice-assistant-ci create secret generic github-webhook-secret \
  --from-literal=secretToken='<random-long-secret>'
```

Kontrollera secrets utan att skriva ut värden:

```bash
kubectl --context microk8s -n voice-assistant-ci get secret dockerhub-credentials github-webhook-secret
```

## Starta CI manuellt

Manuella PipelineRuns finns i `ci/tekton/examples`.

Frontend:

```bash
kubectl --context microk8s create -f ci/tekton/examples/frontend-pipelinerun.yaml
```

Backend:

```bash
kubectl --context microk8s create -f ci/tekton/examples/backend-pipelinerun.yaml
```

Om du vill köra mot en annan branch, skapa en kopia av exempel-filen och ändra parametern `revision`.

## Se hur det gick

Lista senaste pipelinekörningar:

```bash
kubectl --context microk8s -n voice-assistant-ci get pipelineruns --sort-by=.metadata.creationTimestamp
```

Visa detaljer för en specifik körning:

```bash
kubectl --context microk8s -n voice-assistant-ci describe pipelinerun <pipelinerun-name>
```

Se TaskRuns för en PipelineRun:

```bash
kubectl --context microk8s -n voice-assistant-ci get taskruns -l tekton.dev/pipelineRun=<pipelinerun-name>
```

Se pods för en PipelineRun:

```bash
kubectl --context microk8s -n voice-assistant-ci get pods -l tekton.dev/pipelineRun=<pipelinerun-name>
```

Se en kompakt statusbild för hela CI-namespacet:

```bash
kubectl --context microk8s -n voice-assistant-ci get pipelineruns,taskruns,pods
```

Statusfält att leta efter:

- `Succeeded=True`: pipeline eller task lyckades.
- `Succeeded=False`: pipeline eller task misslyckades.
- `Succeeded=Unknown`: körningen pågår.

## Se loggar

Hitta podden för en misslyckad task:

```bash
kubectl --context microk8s -n voice-assistant-ci get pods -l tekton.dev/pipelineRun=<pipelinerun-name>
```

Visa alla containers i podden:

```bash
kubectl --context microk8s -n voice-assistant-ci get pod <pod-name> -o jsonpath='{.spec.containers[*].name}'
```

Visa logg för en specifik step-container:

```bash
kubectl --context microk8s -n voice-assistant-ci logs <pod-name> -c step-<step-name>
```

Exempel:

```bash
kubectl --context microk8s -n voice-assistant-ci logs <pod-name> -c step-lint-test-build
kubectl --context microk8s -n voice-assistant-ci logs <pod-name> -c step-maven-test
kubectl --context microk8s -n voice-assistant-ci logs <pod-name> -c step-maven-verify
kubectl --context microk8s -n voice-assistant-ci logs <pod-name> -c step-trivy-fs
kubectl --context microk8s -n voice-assistant-ci logs <pod-name> -c step-build
kubectl --context microk8s -n voice-assistant-ci logs <pod-name> -c step-trivy-image
kubectl --context microk8s -n voice-assistant-ci logs <pod-name> -c step-push
```

Backend integration tests har även en Postgres-sidecar:

```bash
kubectl --context microk8s -n voice-assistant-ci logs <pod-name> -c sidecar-postgres
```

Följ loggar live:

```bash
kubectl --context microk8s -n voice-assistant-ci logs -f <pod-name> -c step-<step-name>
```

Om `tkn` finns installerat är det ofta snabbare:

```bash
tkn pipelinerun list -n voice-assistant-ci
tkn pipelinerun describe <pipelinerun-name> -n voice-assistant-ci
tkn pipelinerun logs <pipelinerun-name> -n voice-assistant-ci -f
```

## Felsök webhook och triggers

Kontrollera EventListener:

```bash
kubectl --context microk8s -n voice-assistant-ci get eventlistener voice-assistant-github
kubectl --context microk8s -n voice-assistant-ci describe eventlistener voice-assistant-github
```

Kontrollera EventListener-service:

```bash
kubectl --context microk8s -n voice-assistant-ci get svc el-voice-assistant-github
```

Kontrollera ingress:

```bash
kubectl --context microk8s -n voice-assistant-ci get ingress voice-assistant-tekton-webhook
kubectl --context microk8s -n voice-assistant-ci describe ingress voice-assistant-tekton-webhook
```

Kontrollera EventListener-poddar och loggar:

```bash
kubectl --context microk8s -n voice-assistant-ci get pods -l eventlistener=voice-assistant-github
kubectl --context microk8s -n voice-assistant-ci logs -l eventlistener=voice-assistant-github
```

I GitHub ska webhooken peka på:

```text
https://voice-assistant.duckdns.org/tekton-github
```

Webhooken måste använda samma secret som Kubernetes-secreten `github-webhook-secret`.

Om en push inte skapar någon PipelineRun, kontrollera:

- Att pushen gick till `main`.
- Att repository-namnet matchar filtret exakt.
- Att GitHub webhook delivery visar `2xx`.
- Att ingressen route:ar till `el-voice-assistant-github:8080`.
- Att `github-webhook-secret` finns och matchar GitHub.

## Vanliga fel

### Frontend lint misslyckas

Titta i `step-lint-test-build`.

Kör lokalt:

```bash
cd /Users/azizzakiryarov/IdeaProjects/voice-assistent-frontend
npm ci
npm run lint
npm run build
```

### Frontend test saknas

Det är inte ett fel. CI skriver:

```text
No frontend test script found; lint and production build remain mandatory.
```

När ett `test`-script läggs till i `package.json` börjar CI köra `npm test` automatiskt.

### Backend unit tests misslyckas

Titta i `step-maven-test`.

Kör lokalt:

```bash
cd /Users/azizzakiryarov/IdeaProjects/voice-assistant-backend
./mvnw test
```

### Backend integration tests misslyckas

Titta i:

- `step-maven-verify`
- `sidecar-postgres`

Kör lokalt:

```bash
cd /Users/azizzakiryarov/IdeaProjects/voice-assistant-backend
./mvnw verify
```

Om felet gäller databasanslutning, kontrollera att integrationstestet använder CI-värdena och att Postgres-sidecaren är redo.

### Trivy source scan misslyckas

Titta i `step-trivy-fs`.

CI stoppar på `HIGH` och `CRITICAL` sårbarheter som inte är markerade som unfixed. Åtgärda beroendet, uppdatera base image eller justera severity-parametern bara om risken är accepterad.

### Image scan misslyckas

Titta i `step-trivy-image`.

Det betyder att den byggda Docker-imagen innehåller sårbarheter. Vanliga åtgärder:

- Uppdatera base image i `Dockerfile`.
- Uppdatera systempaket i imagen.
- Uppdatera npm- eller Maven-beroenden.

### Image push misslyckas

Titta i `step-push`.

Kontrollera:

```bash
kubectl --context microk8s -n voice-assistant-ci get secret dockerhub-credentials
kubectl --context microk8s -n voice-assistant-ci describe taskrun <taskrun-name>
```

Vanliga orsaker:

- Docker Hub token saknas eller är ogiltig.
- Image-namnet är fel.
- Rate limit eller nätverksproblem mot Docker Hub.

### PVC eller cacheproblem

Kontrollera PVC:

```bash
kubectl --context microk8s -n voice-assistant-ci get pvc
kubectl --context microk8s -n voice-assistant-ci describe pvc voice-assistant-ci-cache
```

Om cachen verkar korrupt kan man skapa om PVC:n, men gör det medvetet eftersom Maven/npm/Trivy-cache försvinner.

## Snabb checklista efter en push

1. Kontrollera att GitHub webhook delivery fick `2xx`.
2. Lista PipelineRuns:

```bash
kubectl --context microk8s -n voice-assistant-ci get pipelineruns --sort-by=.metadata.creationTimestamp
```

3. Följ loggar:

```bash
tkn pipelinerun logs <pipelinerun-name> -n voice-assistant-ci -f
```

4. Kontrollera att imagen pushades:

```bash
docker pull docker.io/azizzakiryarov/voice-assistant-frontend:latest
docker pull docker.io/azizzakiryarov/voice-assistant-backend:latest
```

5. Om GitOps/Argo CD ska deploya den nya imagen, kontrollera applikationsstatus i deployment-namespacet efteråt.
