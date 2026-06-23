# Voice Assistant architecture

This document describes the current production architecture on the Raspberry Pi.
It covers the deployed runtime, the three user flows, persistent data, external
integrations, and the delivery path.

```mermaid
flowchart LR
    User["User<br/>mobile or browser"]

    subgraph Internet["Internet"]
        Domain["voice-assistant.duckdns.org<br/>HTTPS / TLS"]
        Google["Google<br/>OAuth 2.0<br/>Calendar API<br/>Tasks API"]
        DockerHub["Docker Hub<br/>backend and frontend images"]
        GitHub["GitHub<br/>backend · frontend · GitOps"]
    end

    subgraph Pi["Raspberry Pi · MicroK8s"]
        Ingress["NGINX Ingress<br/>/api · /oauth2 · /login/oauth2 · /logout"]
        Cert["cert-manager<br/>Let's Encrypt certificate"]

        subgraph Namespace["namespace: voice-assistant"]
            Frontend["Frontend pod<br/>React + NGINX<br/>port 80"]
            Backend["Backend pod<br/>Spring Boot<br/>port 8081"]

            Tesseract["Tesseract OCR<br/>Swedish + English<br/>runs in backend container"]
            Whisper["Whisper pod<br/>FastAPI + faster-whisper<br/>port 9000"]
            Ollama["Ollama pod<br/>text model, currently llama3.2:1b<br/>port 11434"]
            Postgres["PostgreSQL 14 pod<br/>port 5432"]

            DbVolume[("PostgreSQL PVC<br/>app_user · todo_item<br/>meeting · form_scan")]
            TokenVolume[("Google token PVC")]
            ModelVolume[("Ollama hostPath<br/>model files")]
        end

        Argo["Argo CD<br/>syncs Helm/GitOps manifests"]
    end

    User -->|"HTTPS"| Domain --> Ingress
    Cert --> Ingress
    Ingress -->|"/"| Frontend
    Ingress -->|"/api, OAuth"| Backend
    Frontend -->|"internal /api proxy"| Backend

    Backend <--> Postgres
    Postgres --- DbVolume
    Backend --- TokenVolume
    Ollama --- ModelVolume

    Backend -->|"audio file"| Whisper
    Whisper -->|"transcribed text"| Backend
    Backend -->|"text analysis"| Ollama

    Backend -->|"temporary image file"| Tesseract
    Tesseract -->|"OCR text"| Backend
    Backend -->|"interpret OCR text"| Ollama

    Backend <-->|"OAuth, events and tasks"| Google

    GitHub -->|"source code"| DockerHub
    DockerHub -->|"latest image on rollout"| Frontend
    DockerHub -->|"latest image on rollout"| Backend
    GitHub -->|"Helm chart and environment values"| Argo
    Argo -->|"Kubernetes manifests"| Namespace
```

## User flows

### Voice command

```text
Browser recording → frontend → backend → Whisper → Ollama → review
→ user approval → PostgreSQL and, when connected, Google Tasks or Calendar
```

### Pasted text

```text
Frontend → backend → Ollama → review
→ user approval → PostgreSQL and, when connected, Google Tasks or Calendar
```

### Paper form scan

```text
Mobile camera → frontend → backend → temporary image → Tesseract
→ OCR text → Ollama → review
→ user approval → PostgreSQL and, when connected, Google Tasks or Calendar
```

The original form image is deleted after OCR. Only the OCR text, draft metadata,
and approval status are persisted in the `form_scan` table. Nothing is created
in Google or in the local todo/meeting tables until the user approves a draft.

## Security and ownership

- The browser never receives Google client secrets or backend credentials.
- Google OAuth and Google API calls are performed by the backend.
- OCR runs locally in the backend container; the image is not sent to Ollama.
- Every todo, meeting, OAuth token, and form scan is associated with the signed-in
  application user.
- Kubernetes Secrets hold database credentials and Google OAuth client values.
