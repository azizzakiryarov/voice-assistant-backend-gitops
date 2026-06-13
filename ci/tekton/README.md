# Voice Assistant CI on MicroK8s

## Recommendation

Tekton is the better fit for this project.

| Area | Tekton | Jenkins |
| --- | --- | --- |
| MicroK8s fit | Runs natively as Kubernetes CRDs and pods | Requires a controller plus agents inside Kubernetes |
| Raspberry Pi ARM64 | Smaller always-on footprint; each step runs only when needed | Higher idle memory and CPU usage for controller/plugins |
| Pipeline as code | Kubernetes manifests in GitOps | Jenkinsfile is good, but controller config/plugins are extra state |
| Secrets | Uses Kubernetes Secrets and ServiceAccounts | Works, but Jenkins credentials become another system to operate |
| Maven/npm cache | PVC workspaces | Agent volumes or custom cache setup |
| Docker builds | Buildah/Kaniko in pods | Docker-in-Docker or pod agents |
| Parallelism | Native DAG tasks | Good, but depends on executor capacity |
| Logs/debugging | `tkn` and `kubectl logs` per TaskRun pod | Jenkins UI is strong, but heavier to maintain |
| JFrog/Xray | CLI can run in a step | Strong plugin ecosystem |

Jenkins is still a good choice for large teams that need a mature UI and many legacy plugins. For one MicroK8s node on Raspberry Pi, Tekton has less operational weight and keeps the CI definition in this GitOps repo.

## What the pipeline does

The pipeline gates image publishing behind these steps:

1. Clone the changed repository.
2. Run frontend lint/build and frontend tests when a `test` script exists.
3. Run backend unit tests.
4. Run backend integration tests with a PostgreSQL sidecar.
5. Run source/dependency scan with Trivy.
6. Build an OCI image with Buildah into a local image archive.
7. Scan the built image archive with Trivy.
8. Push Docker images only after all previous checks pass.

The pipeline pushes both:

- `<image>:<git-sha>`
- `<image>:latest`

## Required MicroK8s add-ons

```bash
microk8s enable dns storage
```

Install Tekton Pipelines and Triggers before applying these manifests. Use the ARM64-compatible upstream release manifests for your Tekton version.

## Required secrets

Docker Hub credentials:

```bash
microk8s kubectl -n voice-assistant-ci create secret docker-registry dockerhub-credentials \
  --docker-server=https://index.docker.io/v1/ \
  --docker-username='<dockerhub-user>' \
  --docker-password='<dockerhub-token>' \
  --docker-email='<email>'
```

GitHub webhook secret:

```bash
microk8s kubectl -n voice-assistant-ci create secret generic github-webhook-secret \
  --from-literal=secretToken='<random-long-secret>'
```

Optional JFrog credentials for Artifactory/Xray:

```bash
microk8s kubectl -n voice-assistant-ci create secret generic jfrog-credentials \
  --from-literal=JF_URL='https://<company>.jfrog.io' \
  --from-literal=JF_ACCESS_TOKEN='<token>'
```

## Apply

```bash
microk8s kubectl apply -f ci/tekton/00-namespace-rbac.yaml
microk8s kubectl apply -f ci/tekton/10-workspaces.yaml
microk8s kubectl apply -f ci/tekton/20-tasks.yaml
microk8s kubectl apply -f ci/tekton/30-pipeline.yaml
microk8s kubectl apply -f ci/tekton/40-triggers.yaml
```

## Manual test runs

```bash
microk8s kubectl create -f ci/tekton/examples/backend-pipelinerun.yaml
microk8s kubectl create -f ci/tekton/examples/frontend-pipelinerun.yaml
```

## Notes from repository analysis

- Backend uses Spring Boot and now compiles with Java 21 to match the runtime image.
- Backend has unit tests and a real-audio integration test class. The real-audio test is still guarded by system properties, so it is skipped unless audio and Whisper URL are provided.
- Frontend is React/Vite JavaScript today, not TypeScript. The CI runs lint and build; unit tests run automatically when a `test` script is added.
- The deployment now has Kubernetes health probes for backend and frontend.
